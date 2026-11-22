-- Experimental agentic AL language server (`al launchlspserver`).
--
-- Uses the standard-LSP server shipped by the Microsoft AL Development Tools
-- dotnet tool (BC 2026 release wave 1+) instead of the VSCode extension's
-- EditorServices.Host binary. Because it speaks *standard* LSP over stdio, none
-- of the EditorServices custom-protocol workarounds in plugin/al.lua apply:
-- native textDocument/definition, find-references, rename, and completion all
-- work directly. It is started as a distinct client name (al_agentic_lsp) so the
-- EditorServices-specific LspAttach/handler code (guarded on the
-- "al_language_server" name) is skipped entirely.
--
-- Enable via require("al").setup({ experimental_lsp = true }).
-- Coexists with the AL MCP server — both are the same `al` binary, different
-- subcommands (launchlspserver vs launchmcpserver).

local M = {}

-- PIDs of agentic servers started this session — VimLeavePre kills the whole
-- .NET process tree on exit (mirrors _al_server_pids for EditorServices).
M.pids = {}

-- Resolve the `al` dotnet tool binary.
function M.binary()
  -- Delegates: altool owns the one resolver (it also searches %USERPROFILE%
  -- and PATH, which a bare "~" misses on Windows).
  return require("al.altool").binary()
end

-- True if the al binary exists AND exposes launchlspserver (older tool versions
-- only have launchmcpserver).
function M.available()
  local bin = M.binary()
  if vim.fn.executable(bin) == 0 then return false end
  local out = vim.fn.system({ bin, "--help" })
  return out:find("launchlspserver", 1, true) ~= nil
end

-- ── Reload after the symbol packages change ───────────────────────────────
--
-- The server reads .alpackages once, at startup. Probed on tool 30.0.42: a
-- package added or replaced afterwards stays invisible — to completion, hover
-- and diagnostics — even after workspace/didChangeWatchedFiles; a fresh server
-- sees it. EditorServices reloaded on its own, so this was a regression when
-- the tool's server became the backend: after a symbol download, a dependency's
-- new table was "missing" in Neovim and offered by VS Code's completion.
-- So the client is restarted: after :ALDownloadSymbols, on :ALReindex, and when
-- a .app in the package cache changes on disk (VS Code's download, a copied
-- dependency build).

M.watchers = {}       -- [root] = uv fs_event handle
M.suspended = {}      -- [root] = true while ALNvim itself is downloading
M.RELOAD_DEBOUNCE_MS = 3000

local function norm(p) return vim.fs.normalize(p or "") end

local function clients_for(root)
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = "al_agentic_lsp" })) do
    if norm(c.root_dir) == norm(root) then out[#out + 1] = c end
  end
  return out
end

-- Stop root's agentic client(s) and start a fresh one on the same buffers.
-- Returns false when no client was running for root.
function M.restart(root, reason)
  local olds, bufs = clients_for(root), {}
  if #olds == 0 then return false end
  for _, c in ipairs(olds) do
    for b in pairs(c.attached_buffers or {}) do bufs[#bufs + 1] = b end
    pcall(function()
      local pid = c.rpc.handle:get_pid()
      if pid then M.pids[pid] = nil end
    end)
    c:stop(true)
  end
  vim.notify("AL: reloading the language server — " .. (reason or "restart"), vim.log.levels.INFO)
  -- vim.lsp.start would hand back a client that is still shutting down, so
  -- wait until every old one has stopped (max 5s), then start once per buffer
  -- (the first creates the client, the rest attach to it).
  local waited, timer = 0, vim.uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    if timer:is_closing() then return end
    waited = waited + 100
    local busy = false
    for _, c in ipairs(olds) do if not c:is_stopped() then busy = true end end
    if busy and waited < 5000 then return end
    timer:stop(); timer:close()
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then M.start(b, root) end
    end
  end))
  return true
end

-- Watch root's package cache; a changed .app restarts the server once the
-- writes settle. One watcher per root. Silent no-op where the filesystem
-- reports no events (some network shares) — the explicit hooks still apply.
function M.watch_packages(root, cache)
  if M.watchers[root] or vim.fn.isdirectory(cache) == 0 then return end
  local ev = vim.uv.new_fs_event()
  if not ev then return end
  local debounce = vim.uv.new_timer()
  local ok = ev:start(cache, {}, function(err, fname)
    if err or not fname or not fname:lower():match("%.app$") then return end
    debounce:stop()
    debounce:start(M.RELOAD_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      if M.suspended[root] then return end
      M.restart(root, "symbol packages changed")
    end))
  end)
  if ok then M.watchers[root] = ev else ev:close(); debounce:close() end
end

-- ── Warm-up ───────────────────────────────────────────────────────────────
--
-- The server answers `initialize` in ~0.5s but loads the symbols lazily, on
-- the first semantic request: that request takes 6–9s (tool 30.0.42), however
-- long the server sat idle before it. on_attach used to mark the client ready
-- at once, so the statusline said "ready" and the user's first `.` waited the
-- whole load; nvim-cmp gave up after its fetching_timeout and showed snippets
-- only. So the warm-up sends a hover, then a completion, discards both, and
-- only then says ready. A cap stops a server that never answers from leaving
-- the status at "loading".
--
-- Probed on tool 30.0.42 (ALTest, BC 21 symbols):
--   * The completion must be a *member* completion (just after `X.`). One at
--     (0,0) loaded the symbols but left the first `Cust.` at 1.0–1.5s; after a
--     member completion on any variable, `Cust.` answered in 40ms.
--   * A document that is not on disk gets empty answers in ~80ms and loads
--     nothing — the VimEnter anchor `_al_startup_.al` included. So the target
--     is a real project file: the attached buffer when it is on disk and has a
--     member access, else the first project file with one, opened for the
--     server only (didOpen/didClose, no Neovim buffer).

M.WARM_CAP_MS = 30000
local WARM_SCAN_FILES = 200

-- 0-based position just after the first member-access dot in `lines`
-- (`Cust.Get(`, `Rec."No."`, a bare `SH.`), or nil. Skips namespace/using
-- lines, numbers (`1.5`), ranges (`1..9`), strings and // comments.
function M.warm_position(lines)
  for i, line in ipairs(lines) do
    local code = line:gsub("//.*$", ""):gsub("'[^']*'", function(q) return (" "):rep(#q) end)
    if not code:match("^%s*namespace%s") and not code:match("^%s*using%s") then
      local from = 1
      while true do
        local s = code:find('[%w_"%)]%.', from)
        if not s then break end
        local word = code:sub(1, s):match("[%w_]*$")
        local nxt = code:sub(s + 2, s + 2)
        if nxt ~= "." and not word:match("^%d+$") then
          -- s is the 1-based index of the char before the dot; the dot is at
          -- 1-based s+1, so 0-based "just after the dot" is s+1.
          return { line = i - 1, character = s + 1 }
        end
        from = s + 2
      end
    end
  end
end

local function on_disk(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fn.filereadable(name) == 1
end

-- Pick the warm-up target: { uri, pos, text? }. `text` is set when the file
-- has to be opened for the server (not loaded in Neovim).
function M.warm_target(buf, root)
  if on_disk(buf) then
    local pos = M.warm_position(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if pos then return { uri = vim.uri_from_bufnr(buf), pos = pos } end
  end
  if root then
    local files = vim.fs.find(function(name) return name:match("%.[Aa][Ll]$") ~= nil end,
      { path = root, type = "file", limit = WARM_SCAN_FILES })
    for _, f in ipairs(files) do
      local fb = vim.fn.bufnr(f)
      local loaded = fb ~= -1 and vim.api.nvim_buf_is_loaded(fb)
      local okk, lines = pcall(vim.fn.readfile, f)
      if okk then
        local pos = M.warm_position(loaded and vim.api.nvim_buf_get_lines(fb, 0, -1, false) or lines)
        if pos then
          -- A loaded buffer was opened for the server by Neovim already (when
          -- attached); a second didOpen would be a protocol error.
          return { uri = vim.uri_from_fname(f), pos = pos,
                   text = not loaded and (table.concat(lines, "\n") .. "\n") or nil }
        end
      end
    end
  end
  if on_disk(buf) then
    return { uri = vim.uri_from_bufnr(buf), pos = { line = 0, character = 0 } }
  end
end

-- Warm `client` once: hover then completion, ready after the second answer or
-- WARM_CAP_MS, whichever comes first (exactly once).
function M.warm(client, buf, root)
  if client._al_warm then return end
  client._al_warm = true
  local status = require("al.status")
  status.set_lsp_loading(nil, root)

  local done = false
  local function finish()
    if done then return end
    done = true
    status.set_lsp_ready(root)
  end

  local target = M.warm_target(buf, root)
  if not target then finish(); return end   -- nothing on disk to warm with
  vim.defer_fn(finish, M.WARM_CAP_MS)

  local doc = { uri = target.uri }
  if target.text then
    client:notify("textDocument/didOpen", { textDocument = {
      uri = target.uri, languageId = "al", version = 0, text = target.text } })
  end
  local function close()
    if target.text then client:notify("textDocument/didClose", { textDocument = doc }) end
  end
  local function send(method, pos, cb)
    local okk, sent = pcall(client.request, client, method,
      { textDocument = doc, position = pos }, cb, buf)
    if not okk or sent == false then close(); finish() end
    return okk and sent ~= false
  end
  local p = target.pos
  local qualifier = { line = p.line, character = math.max(0, p.character - 2) }
  send("textDocument/hover", qualifier, function()
    send("textDocument/completion", p, function() close(); finish() end)
  end)
end

-- Start the agentic LSP for `root`, attaching buffer `bufnr`.
function M.start(bufnr, root)
  local bin = M.binary()
  if vim.fn.executable(bin) == 0 then
    vim.notify(
      "AL agentic LSP: al binary not found at " .. bin
      .. "\nInstall/update with: dotnet tool update "
      .. "Microsoft.Dynamics.BusinessCentral.Development.Tools --prerelease --global",
      vim.log.levels.ERROR)
    return
  end

  local cfg   = require("al").config
  local cache = root .. "/" .. (cfg.packagecachepath or ".alpackages")

  -- Positional <root> enables single-project resolution; --packagecachepath points
  -- at the .app symbol packages the server needs for full language intelligence.
  local cmd = {
    bin, "launchlspserver", root,
    "--packagecachepath", cache,
    "--disableTelemetry",
  }
  for _, dir in ipairs(require("al.lsp").assembly_probing_paths(root)) do
    vim.list_extend(cmd, { "--assemblyprobingpath", dir })
  end
  -- A .vscode/settings.json (if present) supplies al.* keys the server honours.
  local vscode_settings = root .. "/.vscode/settings.json"
  if vim.fn.filereadable(vscode_settings) == 1 then
    vim.list_extend(cmd, { "--settingspath", vscode_settings })
  end
  if cfg.ruleset_path and cfg.ruleset_path ~= "" then
    vim.list_extend(cmd, { "--ruleset", cfg.ruleset_path })
  end

  M.watch_packages(root, cache)

  vim.lsp.start({
    name     = "al_agentic_lsp",
    cmd      = cmd,
    root_dir = root,
    capabilities = require("al.lsp").capabilities(),
    on_init  = function(client)
      -- vim syntax file (syntax/al.vim) owns highlighting; drop semantic tokens
      -- so the server's classification doesn't override it (same reason as the
      -- EditorServices path).
      client.server_capabilities.semanticTokensProvider = nil
      -- It advertises rename but never answers textDocument/rename, so any
      -- vim.lsp.buf.rename() (a user's own mapping, a picker's action) waited
      -- forever with no message. Unadvertised, Neovim says rename is not
      -- supported instead; grn / :ALRenameObject rename through references
      -- (refactor.rename_via_references).
      client.server_capabilities.renameProvider = nil
      pcall(function()
        local pid = client.rpc.handle:get_pid()
        if pid and pid > 0 then M.pids[pid] = true end
      end)
    end,
    on_attach = function(client, buf)
      -- Label objects and quoted filterText: one shared patch (al.lsp).
      require("al.lsp").patch_completion(client)

      local status = require("al.status")
      -- Standard LSP: no al/progressNotification or al/activeProjectLoaded
      -- events. Ready is set when the warm-up below has loaded the symbols.
      local app = require("al.lsp").read_app_json(root)
      if app then status.set_project(app.name, app.version, root) end
      M.warm(client, buf, root)

      if cfg.inlay_hints ~= false and client.server_capabilities.inlayHintProvider
         and vim.lsp.inlay_hint then
        pcall(vim.lsp.inlay_hint.enable, true, { bufnr = buf })
      end

      -- Auto-configure the AL MCP server once per client (the EditorServices
      -- LspAttach path that normally does this is skipped in agentic mode).
      if cfg.auto_mcp and not client._al_mcp_configured then
        client._al_mcp_configured = true
        require("al.mcp").configure(root)
      end

      -- gd: the server's definition, falling back to the extracted symbol
      -- sources for base-app objects it cannot locate (al.basedef).
      -- vim.schedule defers past the user's own generic LspAttach handler so
      -- this buffer-local map wins.
      vim.schedule(function()
        vim.keymap.set("n", "gd", function() require("al.basedef").definition() end,
          { buffer = buf, desc = "AL: Go to definition" })
      end)

      if type(cfg.on_attach) == "function" then
        pcall(cfg.on_attach, client, buf)
      end
    end,
  }, { bufnr = bufnr })
end

return M
