-- Download AL symbol packages (.app files) from either:
--   Server/Sandbox/Docker — direct curl calls to the BC dev endpoint
--   Global (NuGet/AppSource) — LSP request al/downloadSymbolsFromGlobalSources
--
-- All server downloads run in parallel via vim.fn.jobstart.

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
  vim.fn.mkdir(root .. "/.vscode", "p")
  vim.fn.writefile({ vim.fn.json_encode(data) }, config_path(root))
end

function M.get_country_region(root)
  return read_alnvim_json(root).symbolsCountryRegion
end

function M.set_country_region(root, cr)
  local data = read_alnvim_json(root)
  data.symbolsCountryRegion = cr
  write_alnvim_json(root, data)
end

-- ── Global source download via LSP ───────────────────────────────────────────

local function get_lsp_client(root)
  local clients = vim.lsp.get_clients({ name = "al_language_server" })
  for _, c in ipairs(clients) do
    if c.config.root_dir == root then return c end
  end
  return nil
end

function M.download_global(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  local client = get_lsp_client(root)
  if not client then
    vim.notify(
      "AL: No active LSP client — open an .al file in this project first",
      vim.log.levels.ERROR)
    return
  end

  local cr = M.get_country_region(root)

  local function do_download(country_region)
    -- Progress float
    local lines = {
      "  Global (NuGet / AppSource)  [" .. country_region .. "]  ",
      "",
      "  …  Downloading symbols…",
    }
    local width = 0
    for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 4) end
    width = math.max(width, 52)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ui  = vim.api.nvim_list_uis()[1]
    local win = vim.api.nvim_open_win(buf, false, {
      relative  = "editor",
      width     = width,
      height    = #lines,
      row       = math.floor((ui.height - #lines) / 2),
      col       = math.floor((ui.width  - width)  / 2),
      style     = "minimal",
      border    = "rounded",
      title     = " AL: Downloading Symbols ",
      title_pos = "center",
      noautocmd = true,
    })
    vim.wo[win].wrap = false
    local ns = vim.api.nvim_create_namespace("al_symbols_global")
    vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 0, 0, -1)

    local function finish(ok, msg)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      local icon = ok and "✓" or "✗"
      local hl   = ok and "DiagnosticOk" or "DiagnosticError"
      vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  " .. icon .. "  " .. msg })
      vim.api.nvim_buf_add_highlight(buf, ns, hl, 2, 0, -1)
      if ok then
        vim.defer_fn(function()
          if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        end, 3000)
      else
        vim.keymap.set("n", "q",     "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
        vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
      end
    end

    local bufnr = vim.tbl_keys(client.attached_buffers or {})[1] or 0

    client:request("al/downloadSymbolsFromGlobalSources", {
      symbolsCountryRegion = country_region,
      force                = true,
      nugetFeeds           = vim.NIL,
      useOnlyCustomFeeds   = false,
      enforceMinorVersion  = false,
      browserInfo          = { browser = vim.NIL, incognito = false },
      environmentInfo      = { env = vim.NIL },
    }, function(err, result)
      if err then
        finish(false, "Failed: " .. (type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)))
      elseif result and result.success == false then
        finish(false, "Download failed — check :messages")
      else
        finish(true, "All symbols downloaded successfully")
      end
    end, bufnr)
  end

  if cr and cr ~= "" then
    do_download(cr)
  else
    -- Prompt for country/region code and optionally save it
    vim.ui.input({
      prompt  = "Country/region code (e.g. w1, us, gb, de): ",
      default = "w1",
    }, function(input)
      if not input or input == "" then return end
      local code = input:lower():match("^%s*(.-)%s*$")
      vim.ui.select(
        { "Yes — save for this project", "No — use once" },
        { prompt = "Save '" .. code .. "' in alnvim.json?" },
        function(choice)
          if not choice then return end
          if choice:sub(1, 1) == "Y" then
            M.set_country_region(root, code)
          end
          do_download(code)
        end)
    end)
  end
end

local function packages_url(base, dep, tenant)
  return string.format(
    "%s/dev/packages?publisher=%s&appName=%s&versionText=%s&tenant=%s",
    base,
    conn.urlencode(dep.publisher or ""),
    conn.urlencode(dep.name or ""),
    conn.urlencode(dep.version or ""),
    conn.urlencode(tenant))
end

-- Sanitise a string for use in a filename (replace path separators).
local function safe_name(s)
  return (s or "Unknown"):gsub("[/\\%?%%*:|\"<>]", "_")
end

-- Open a floating window listing all packages with live status indicators.
-- Returns (buf, win, first_pkg_line) where first_pkg_line is the 0-based line
-- index of the first package entry (used to update individual rows).
local function open_symbols_win(deps, base)
  -- Header + blank line, then one line per package
  local lines = { "  " .. base .. "  ", "" }
  for _, dep in ipairs(deps) do
    table.insert(lines, "  …  " .. (dep.publisher or "") .. " / " .. (dep.name or ""))
  end

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 4) end
  width = math.max(width, 52)
  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ui  = vim.api.nvim_list_uis()[1]
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width  - width)  / 2)

  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " AL: Downloading Symbols ",
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[win].wrap = false

  -- Highlight the header line dimly
  local ns = vim.api.nvim_create_namespace("al_symbols")
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 0, 0, -1)

  return buf, win, ns
end

-- Update a single package row: replace spinner with ✓ or ✗ and apply highlight.
local function set_pkg_status(buf, ns, line_idx, dep, ok)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local icon = ok and "✓" or "✗"
  local text = "  " .. icon .. "  " .. (dep.publisher or "") .. " / " .. (dep.name or "")
  vim.api.nvim_buf_set_lines(buf, line_idx, line_idx + 1, false, { text })
  vim.api.nvim_buf_add_highlight(buf, ns, ok and "DiagnosticOk" or "DiagnosticError",
    line_idx, 0, -1)
end

-- Append a summary line and close the window after a short delay.
local function finish_win(buf, win, ns, failed_count)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local summary, hl
  if failed_count == 0 then
    summary = "  All packages downloaded successfully"
    hl = "DiagnosticOk"
  else
    summary = string.format("  %d package(s) failed — see :messages", failed_count)
    hl = "DiagnosticError"
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", summary })
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_add_highlight(buf, ns, hl, last - 1, 0, -1)
  -- Resize window to fit the new line
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_height(win, last)
  end
  -- Auto-close after 3 s on success, leave open on failure so user can read it
  if failed_count == 0 then
    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, 3000)
  else
    -- Allow manual close with q / <Esc>
    vim.keymap.set("n", "q",     "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end
end

local function download_server(root)
  local app = lsp.read_app_json(root)
  if not app then
    vim.notify("AL: Cannot read app.json", vim.log.levels.ERROR)
    return
  end

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  -- Build the download list from explicit dependencies plus implicit Microsoft
  -- base packages that are always required for full type resolution.
  local deps = {}
  local base_pkgs = {
    { publisher = "Microsoft", name = "System",              version = app.platform    or "0.0.0.0" },
    { publisher = "Microsoft", name = "System Application",  version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "Business Foundation", version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "Base Application",    version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "Application",         version = app.application or "0.0.0.0" },
  }
  for _, bp in ipairs(base_pkgs) do
    local found = false
    for _, d in ipairs(app.dependencies or {}) do
      if d.publisher == bp.publisher and d.name == bp.name then
        found = true; break
      end
    end
    if not found then table.insert(deps, bp) end
  end
  for _, d in ipairs(app.dependencies or {}) do
    table.insert(deps, d)
  end

  local pkgdir = root .. "/.alpackages"
  vim.fn.mkdir(pkgdir, "p")

  local base   = conn.base_url(cfg)
  local tenant = cfg.primaryTenantDomain or cfg.tenant or "default"

  conn.get_auth(cfg, function(auth)
  -- Open the progress float (header + blank + one row per package)
  local buf, win, ns = open_symbols_win(deps, base)
  -- Package rows start at line index 2 (0-based)
  local PKG_LINE_OFFSET = 2

  local pending = #deps
  local failed  = {}

  for idx, dep in ipairs(deps) do
    local url     = packages_url(base, dep, tenant)
    local outfile = string.format("%s/%s_%s_%s.app",
      pkgdir, safe_name(dep.publisher), safe_name(dep.name), dep.version or "0.0.0.0")
    local line_idx = PKG_LINE_OFFSET + idx - 1  -- 0-based row for this package

    -- -sLS: silent progress but show errors; -L: follow redirects; --fail: non-zero on HTTP error
    local cmd = { "curl", "-sLS", "--fail" }
    vim.list_extend(cmd, auth)
    vim.list_extend(cmd, { "-o", outfile, url })

    local err_buf = {}
    vim.fn.jobstart(cmd, {
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(err_buf, line) end
        end
      end,
      on_exit = vim.schedule_wrap(function(_, code)
        pending = pending - 1
        local ok = code == 0
        set_pkg_status(buf, ns, line_idx, dep, ok)
        if not ok then
          local label  = (dep.publisher or "") .. " / " .. (dep.name or "")
          local detail = #err_buf > 0 and ("\n  " .. table.concat(err_buf, " ")) or ""
          table.insert(failed, label .. "\n  URL: " .. url .. detail)
          pcall(vim.uv.fs_unlink, outfile)
        end
        if pending == 0 then
          finish_win(buf, win, ns, #failed)
          if #failed > 0 then
            vim.notify(
              "AL: Failed to download:\n" .. table.concat(failed, "\n"),
              vim.log.levels.WARN)
          end
        end
      end),
    })
  end
  end) -- conn.get_auth
end

-- ── Public entry point ────────────────────────────────────────────────────────

function M.download(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  local cr = M.get_country_region(root)
  local choices = {
    { label = "Server / Sandbox / Docker  (launch.json)", fn = function() download_server(root) end },
    { label = "Global (NuGet / AppSource)" .. (cr and ("  [" .. cr .. "]") or ""), fn = function() M.download_global(root) end },
  }

  vim.ui.select(
    vim.tbl_map(function(c) return c.label end, choices),
    { prompt = "AL: Download symbols from:" },
    function(_, idx)
      if idx then choices[idx].fn() end
    end)
end

return M
