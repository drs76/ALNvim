-- Download AL symbol packages (.app files) into the project's package cache,
-- from a BC server (launch.json) or from the global Microsoft / AppSource
-- NuGet feeds. Everything goes through the AL dotnet tool — see "Transport".

local M   = {}
local conn = require("al.connection")
local lsp  = require("al.lsp")

-- ── Country-region helpers (stored in .vscode/alnvim.json) ───────────────────

local function config_path(root)
  return root .. "/.vscode/alnvim.json"
end

local function read_alnvim_json(root)
  local ok, lines = pcall(vim.fn.readfile, config_path(root))
  if not ok or not lines or #lines == 0 then return {} end
  local ok2, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  return (ok2 and type(data) == "table") and data or {}
end

local function write_alnvim_json(root, data)
  require("al.json").write(config_path(root), data)
end

function M.get_country_region(root)
  return read_alnvim_json(root).symbolsCountryRegion
end

function M.set_country_region(root, cr)
  local data = read_alnvim_json(root)
  data.symbolsCountryRegion = cr
  write_alnvim_json(root, data)
end

-- Collect custom NuGet feed URLs for global symbol download.
-- Priority: alnvim.json nugetFeeds → .vscode/settings.json al.nugetFeeds.
-- Returns a list (possibly empty).
local function read_nuget_feeds(root)
  local feeds, seen = {}, {}
  local function add(f)
    if type(f) == "string" and f ~= "" and not seen[f] then
      seen[f] = true; table.insert(feeds, f)
    end
  end
  local al_feeds = read_alnvim_json(root).nugetFeeds
  if type(al_feeds) == "table" then
    for _, f in ipairs(al_feeds) do add(f) end
  end
  local ok, lines = pcall(vim.fn.readfile, root .. "/.vscode/settings.json")
  if ok and lines then
    local ok2, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
    if ok2 and type(data) == "table" and type(data["al.nugetFeeds"]) == "table" then
      for _, f in ipairs(data["al.nugetFeeds"]) do add(f) end
    end
  end
  return feeds
end

function M.set_nuget_feeds(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found", vim.log.levels.ERROR)
    return
  end
  local current = read_alnvim_json(root).nugetFeeds or {}
  vim.ui.input({
    prompt  = "NuGet feed URLs (comma-separated, blank to clear): ",
    default = table.concat(current, ", "),
  }, function(input)
    if input == nil then return end
    local data = read_alnvim_json(root)
    if input:match("^%s*$") then
      data.nugetFeeds = nil
      vim.notify("AL: NuGet feeds cleared from alnvim.json", vim.log.levels.INFO)
    else
      data.nugetFeeds = vim.tbl_map(
        function(s) return s:match("^%s*(.-)%s*$") end,
        vim.split(input, ","))
      vim.notify("AL: " .. #data.nugetFeeds .. " NuGet feed(s) saved to alnvim.json", vim.log.levels.INFO)
    end
    write_alnvim_json(root, data)
  end)
end

-- ── Transport ────────────────────────────────────────────────────────────────
--
-- Both sources go through the AL dotnet tool, by whichever route the installed
-- version offers:
--
--   cli  `al downloadsymbols` (tool 30+). Streams progress into a float — which
--        matters, because AAD sign-in can stop and print a device code — and
--        takes custom NuGet feeds and a country/region.
--   mcp  `al_downloadsymbols` over a one-shot MCP server (older tools). Same
--        downloads, reported once at the end; no custom feeds.
--
-- Deliberately gone: the EditorServices request al/downloadSymbolsFromGlobal-
-- Sources (it needed the VS Code extension's language server running for this
-- project) and the hand-rolled curl calls against /dev/packages for server
-- downloads (their own auth path, and only the five base packages plus direct
-- dependencies — no transitive ones).

local function transport()
  local altool = require("al.altool")
  if not altool.available() then return nil end
  if altool.has("downloadsymbols") then return "cli" end
  if altool.has("launchmcpserver") then return "mcp" end
  return nil
end

local function cache_dir(root)
  return root .. "/" .. (require("al").config.packagecachepath or ".alpackages")
end

-- CLI arguments. source = "global" | "server"; cfg is the launch configuration
-- for "server" and unused for "global".
local function cli_args(root, source, cfg)
  local a = { "downloadsymbols", "--project", root,
              "--packagecachepath", cache_dir(root), "--force", "--raw" }
  if source == "global" then
    a[#a + 1] = "--globalsourcesonly"
    local cr = M.get_country_region(root)
    if cr and cr ~= "" then vim.list_extend(a, { "--symbolscountryregion", cr }) end
    for _, f in ipairs(read_nuget_feeds(root)) do
      vim.list_extend(a, { "--nugetfeeds", f })
    end
  else
    vim.list_extend(a, require("al.altool").connection_flags(cfg))
  end
  return a
end

-- MCP tool arguments, same meaning as cli_args.
local function mcp_args(root, source, cfg)
  local a = { projectPath = root, force = true }
  if source == "global" then
    a.globalSourcesOnly = true
  else
    for k, v in pairs(require("al.altool").connection(cfg)) do a[k] = v end
    -- The MCP server has no terminal to print a device code into; let it open
    -- the browser sign-in itself instead.
    if a.authentication == "AAD" then a.useInteractiveLogin = true end
  end
  return a
end

-- Turn the tool's JSON envelope { succeeded, message, data = { downloadedCount } }
-- into (ok, message).
local function summarize(ok, text)
  local msg = text
  local okj, resp = pcall(vim.fn.json_decode, text)
  if okj and type(resp) == "table" and resp.message then
    if resp.succeeded == false then ok = false end
    msg = resp.message
    if type(resp.data) == "table" and type(resp.data.downloadedCount) == "number" then
      msg = string.format("%s (%d downloaded)", resp.message, resp.data.downloadedCount)
    end
  end
  if ok then return true, (msg ~= "" and msg or "All symbols downloaded successfully") end
  return false, "Failed: " .. msg
end

-- Progress float for the MCP route: header + one status line.
-- Returns finish(ok, msg) which swaps the spinner for ✓/✗ and auto-closes on ok.
local function progress_float(header)
  local lines = {
    "  " .. header .. "  ",
    "",
    "  …  Downloading symbols…",
  }
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 4) end
  width = math.max(width, 52)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = width,
    height    = #lines,
    row       = math.floor((vim.o.lines - #lines) / 2),
    col       = math.floor((vim.o.columns - width) / 2),
    style     = "minimal",
    border    = "rounded",
    title     = " AL: Downloading Symbols ",
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[win].wrap = false
  local ns = vim.api.nvim_create_namespace("al_symbols")
  vim.hl.range(buf, ns, "Comment", { 0, 0 }, { 0, -1 })

  return function(ok, msg)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local icon = ok and "✓" or "✗"
    local hl   = ok and "DiagnosticOk" or "DiagnosticError"
    -- Message may be multi-line; first line in the status row, the rest below.
    local parts = vim.split(msg, "\n", { plain = true, trimempty = true })
    local rows  = { "  " .. icon .. "  " .. (parts[1] or "") }
    for i = 2, #parts do rows[#rows + 1] = "     " .. parts[i] end
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, rows)
    vim.hl.range(buf, ns, hl, { 2, 0 }, { 2, -1 })
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_height(win, math.min(2 + #rows, 20))
    end
    if ok then
      require("al.altool").close_later(win, 3000)
    else
      for _, k in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", k, "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
      end
    end
  end
end

-- Run one download. source = "global" | "server"; cfg required for "server".
local function run(root, source, cfg)
  local altool = require("al.altool")
  local t = transport()
  if not t then
    vim.notify(altool.available()
      and "AL: this AL dotnet tool cannot download symbols — update it: :ALInstallDotnetTool"
      or  altool.missing_msg("Downloading symbols"), vim.log.levels.ERROR)
    return
  end

  local label = source == "global" and "Global (AppSource / Microsoft)"
    or ("Server — " .. (cfg.name or "launch.json"))
  local env = cfg and altool.cred_env(cfg) or nil

  if t == "cli" then
    altool.run(cli_args(root, source, cfg), {
      title = "AL: Symbols — " .. label, cwd = root, env = env,
    }, function(ok, code, log, win)
      if ok then
        log({ "", "── Done ──" })
        altool.close_later(win, 3000)
      else
        log({ "", "── Failed (exit " .. code .. ") ──" })
        vim.notify("AL: Symbol download failed — see float", vim.log.levels.ERROR)
      end
    end)
    return
  end

  if source == "global" and #read_nuget_feeds(root) > 0 then
    vim.notify("AL: custom NuGet feeds need AL dotnet tool 30+ (this one downloads "
      .. "over MCP, which has no feed option) — they are ignored this time. "
      .. "Update with :ALInstallDotnetTool.", vim.log.levels.WARN)
  end
  local finish = progress_float(label .. " — al tool")
  altool.mcp_call(root, "al_downloadsymbols", mcp_args(root, source, cfg),
    function(ok, text) finish(summarize(ok, text)) end, { env = env })
end

-- ── Public entry points ───────────────────────────────────────────────────────

function M.download_global(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end
  run(root, "global")
end

function M.download(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  local cr = M.get_country_region(root)
  local choices = {
    { label = "Server / Sandbox / Docker  (launch.json)", fn = function()
        conn.pick_launch(root, function(cfg) run(root, "server", cfg) end)
      end },
    { label = "Global (NuGet / AppSource)" .. (cr and ("  [" .. cr .. "]") or ""),
      fn = function() run(root, "global") end },
  }

  vim.ui.select(
    vim.tbl_map(function(c) return c.label end, choices),
    { prompt = "AL: Download symbols from:" },
    function(_, idx)
      if idx then choices[idx].fn() end
    end)
end

-- Internals reached by tests only — never call from plugin code.
M._test = { cli_args = cli_args, mcp_args = mcp_args, summarize = summarize }

return M
