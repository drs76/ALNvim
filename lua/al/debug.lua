-- AL debugging support.
--
-- Two modes are available:
--
--   1. Snapshot debugging (no extra tools required)
--      BC captures a full execution trace server-side. You start a session,
--      perform actions in the BC client, then download the snapshot file.
--      Commands: :ALSnapshotStart / :ALSnapshotFinish
--
--   2. Live attach (requires nvim-dap)
--      Attaches the AL debug adapter to a running BC session.
--      The adapter is the same EditorServices.Host binary used for LSP.
--      Command: :ALDebugSetup  then  :DapContinue

local M    = {}

-- The DAP adapter (16.x+) deserialises breakOnError / breakOnRecordWrite as
-- strict booleans even though the VSCode schema accepts string enum values.
-- "All" → true, anything else ("None", false, nil) → false.
local function to_break_bool(v, default_true)
  if v == nil then return default_true or false end
  if type(v) == "boolean" then return v end
  return v == "All" or v == "ExcludeTry" or v == "ExcludeTemporary"
end
local conn  = require("al.connection")
local lsp   = require("al.lsp")

-- Save UserPassword credentials to the AL LSP credential store before launching.
-- VSCode calls al/saveUsernamePassword on the LSP server before starting the debug
-- adapter; the adapter reads credentials from the store (Windows Credential Manager)
-- rather than from the DAP launch request. Without this call the credential store
-- is empty and the adapter cannot authenticate with BC.
-- Calls cb() immediately if UserPassword auth is not in use or no LSP client exists.
local function save_creds_to_lsp(cfg, user, pass, cb)
  if not user or user == "" then cb(); return end
  local auth = cfg.authentication or ""
  if auth ~= "UserPassword" and auth ~= "NavUserPassword" then cb(); return end
  local clients = vim.lsp.get_clients({ name = "al_language_server" })
  if #clients == 0 then cb(); return end
  local client = clients[1]
  local attached = vim.lsp.get_buffers_by_client_id(client.id)
  local bufnr = (attached and #attached > 0) and attached[1] or 0
  client:request("al/saveUsernamePassword", {
    configuration = cfg,
    credentials   = { username = user, password = pass },
  }, function(err)
    if err then
      vim.notify("AL: Warning — could not save credentials to LSP: " .. tostring(err.message or err),
        vim.log.levels.WARN)
    else
      vim.notify("AL: Credentials saved to LSP credential store (user: " .. (user or "") .. ")",
        vim.log.levels.INFO)
    end
    cb()
  end, bufnr)
end

-- ── Snapshot debugging ────────────────────────────────────────────────────────

-- BC dev snapshot API endpoints (on-prem):
--   POST   <base>/dev/debugging/snapshots           – initialise session
--   GET    <base>/dev/debugging/snapshots/<id>      – download snapshot file
--   DELETE <base>/dev/debugging/snapshots/<id>      – clean up

local function snapshot_base_url(base, tenant)
  return string.format("%s/dev/debugging/snapshots?tenant=%s",
    base, conn.urlencode(tenant or "default"))
end

local function snapshot_id_url(base, sid, tenant)
  return string.format("%s/dev/debugging/snapshots/%s?tenant=%s",
    base, conn.urlencode(tostring(sid)), conn.urlencode(tenant or "default"))
end

-- Initialise a snapshot session on BC.
-- Stores the returned session ID in vim.g.al_snapshot_session.
function M.snapshot_start(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found", vim.log.levels.ERROR)
    return
  end

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  local base   = conn.base_url(cfg)
  local tenant = cfg.tenant or "default"
  local auth   = conn.curl_auth(cfg)

  local body = vim.fn.json_encode({
    breakOnNext      = cfg.breakOnNext or "WebClient",
    executionContext = cfg.executionContext or "DebugAndProfile",
  })

  local cmd = {
    "curl", "-sL", "--fail", "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", body,
  }
  vim.list_extend(cmd, auth)
  table.insert(cmd, snapshot_base_url(base, tenant))

  local output = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data) vim.list_extend(output, data) end,
    on_exit = vim.schedule_wrap(function(_, code)
      if code == 0 then
        local raw = table.concat(output, "")
        local ok, resp = pcall(vim.fn.json_decode, raw)
        local sid = (ok and type(resp) == "table" and resp.sessionId) or "unknown"
        vim.g.al_snapshot_session = tostring(sid)
        vim.g.al_snapshot_root    = root
        vim.notify(
          "AL: Snapshot session started  (id: " .. sid .. ")\n"
          .. "Perform actions in the BC client, then run :ALSnapshotFinish",
          vim.log.levels.INFO)
      else
        vim.notify(
          "AL: Failed to start snapshot session (curl exit " .. code .. ")\n"
          .. "Check server/credentials in .vscode/launch.json",
          vim.log.levels.ERROR)
      end
    end),
  })
end

-- Download the snapshot file from BC and open it in a new buffer.
function M.snapshot_finish(root)
  local sid = vim.g.al_snapshot_session
  if not sid then
    vim.notify("AL: No active snapshot session. Run :ALSnapshotStart first.", vim.log.levels.WARN)
    return
  end

  root = root or vim.g.al_snapshot_root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found", vim.log.levels.ERROR)
    return
  end

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found", vim.log.levels.ERROR)
    return
  end

  local base    = conn.base_url(cfg)
  local tenant  = cfg.tenant or "default"
  local auth    = conn.curl_auth(cfg)
  local outdir  = root .. "/.snapshots"
  vim.fn.mkdir(outdir, "p")
  local outfile = outdir .. "/snapshot_" .. sid .. ".snapshots"

  local cmd = { "curl", "-sL", "--fail" }
  vim.list_extend(cmd, auth)
  vim.list_extend(cmd, { "-o", outfile, snapshot_id_url(base, sid, tenant) })

  vim.fn.jobstart(cmd, {
    on_exit = vim.schedule_wrap(function(_, code)
      if code == 0 then
        vim.g.al_snapshot_session = nil
        vim.g.al_snapshot_root    = nil
        vim.notify("AL: Snapshot saved to " .. outfile, vim.log.levels.INFO)
        vim.cmd("edit " .. vim.fn.fnameescape(outfile))
      else
        vim.notify(
          "AL: Failed to download snapshot (exit " .. code .. ")",
          vim.log.levels.ERROR)
      end
    end),
  })
end

-- ── launch.json patching ─────────────────────────────────────────────────────
--
-- The adapter reads .vscode/launch.json directly via /projectRoot: and
-- deserialises breakOnError as a strict bool — sending the string "All" throws
-- ArgumentException. We patch the file before launching and restore afterwards.
-- Uses JSON parse+encode so the patch works regardless of whitespace/formatting.

-- If a previous session left a backup of launch.json, restore it now.
-- This is a one-time recovery for the no-longer-used patching approach.
local function restore_bak_if_exists(root)
  local bak  = root .. "/.vscode/launch.json.alnvim.bak"
  local path = root .. "/.vscode/launch.json"
  local fb = io.open(bak, "r")
  if not fb then return end
  local content = fb:read("*a")
  fb:close()
  local fw = io.open(path, "w")
  if fw then
    fw:write(content)
    fw:close()
    os.remove(bak)
    vim.notify("AL: Restored launch.json from backup (previous patching removed)", vim.log.levels.INFO)
  end
end

-- ── Launch (F5 equivalent) ────────────────────────────────────────────────────
--
-- Mirrors the VSCode F5 flow: compile → DAP launch request.
-- The DAP adapter (EditorServices.Host) handles publishing to BC when it
-- receives a "launch" request — VSCode never does a direct HTTP POST to
-- /dev/apps. We compile with alc, then hand a launch config to dap.run().

-- Create a no-op xdg-open stub in the ALNvim cache dir (Linux/macOS only).
-- On Windows the adapter is given nil env (inherit parent), and launchBrowser is
-- patched to false, so the adapter never tries to invoke xdg-open.
-- Returns the stub directory path (empty string on Windows — unused by adapter_env).
local _xdg_stub_dir = nil
local function ensure_xdg_stub()
  if require("al.platform").is_windows then return "" end
  if _xdg_stub_dir then return _xdg_stub_dir end
  local dir  = vim.fn.stdpath("cache") .. "/alnvim"
  local stub = dir .. "/xdg-open"
  vim.fn.mkdir(dir, "p")
  if vim.fn.filereadable(stub) == 0 then
    local f = io.open(stub, "w")
    if f then
      f:write("#!/bin/sh\n# no-op stub — ALNvim handles browser open from Lua\nexit 0\n")
      f:close()
      vim.uv.fs_chmod(stub, 493)   -- 0755 decimal
    end
  end
  _xdg_stub_dir = dir
  return dir
end

-- ── Adapter output floating window ───────────────────────────────────────────
-- Shows all DAP "output" events from the adapter in a non-focused float.
-- Useful for diagnosing publish failures ("An internal error has occurred" etc).
-- The buffer is kept alive across window closes (bufhidden=hide) so previous
-- output is always visible when the window is reopened (manually or on new output).
local _out_buf     = nil   -- persists for the lifetime of the Neovim session
local _out_win     = nil   -- nil when closed; recreated by ensure_output_win()
local _out_win_auid = nil  -- autocmd id watching for WinClosed

local function reset_output_win()
  -- Clear content for the new launch; keep the buffer alive for reuse.
  if _out_buf and vim.api.nvim_buf_is_valid(_out_buf) then
    vim.api.nvim_buf_set_lines(_out_buf, 0, -1, false, {})
    return  -- window (if still open) is reused as-is
  end
  _out_buf = nil  -- buffer was deleted externally; will be re-created on demand
end

local function open_output_win(buf)
  local w   = math.min(96, vim.o.columns - 4)
  local h   = math.min(14, math.floor(vim.o.lines * 0.35))
  local row = vim.o.lines - h - 3
  local col = math.floor((vim.o.columns - w) / 2)
  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = w,
    height    = h,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " AL: Adapter Output (q = close) ",
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true, silent = true })
  _out_win = win
  -- Watch for the window being closed by anything (DapLog, :q, etc.) and
  -- update _out_win so the next ensure_output_win() recreates it correctly.
  if _out_win_auid then pcall(vim.api.nvim_del_autocmd, _out_win_auid) end
  _out_win_auid = vim.api.nvim_create_autocmd("WinClosed", {
    pattern  = tostring(win),
    once     = true,
    callback = function()
      _out_win     = nil
      _out_win_auid = nil
    end,
  })
  return win
end

local function ensure_output_win()
  -- Fast path: both buffer and window are still alive.
  if _out_buf and vim.api.nvim_buf_is_valid(_out_buf)
     and _out_win and vim.api.nvim_win_is_valid(_out_win) then
    return _out_buf, _out_win
  end
  -- Reuse the existing buffer (content preserved) or create a fresh one.
  local buf
  if _out_buf and vim.api.nvim_buf_is_valid(_out_buf) then
    buf = _out_buf
  else
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    _out_buf = buf
  end
  local win = open_output_win(buf)
  return buf, win
end

-- Show (or reopen) the adapter output window. Exported as M.show_output().
local function show_output_win()
  if not (_out_buf and vim.api.nvim_buf_is_valid(_out_buf))
     or vim.api.nvim_buf_line_count(_out_buf) == 0 then
    vim.notify("AL: No adapter output yet (run :ALLaunch first)", vim.log.levels.WARN)
    return
  end
  if _out_win and vim.api.nvim_win_is_valid(_out_win) then
    vim.api.nvim_set_current_win(_out_win)
    return
  end
  open_output_win(_out_buf)
  pcall(vim.api.nvim_win_set_cursor, _out_win,
    { vim.api.nvim_buf_line_count(_out_buf), 0 })
end

-- Register listeners for custom AL DAP events the adapter fires.
-- al/openUri              — real BC web client URL after publish (cloud / on-prem)
-- al/deviceLogin          — OAuth2 device code flow
-- al/launchDeviceLoginWindow — reverse request to open browser for device login
-- al/refreshExplorerObjects — fired after a successful publish; used as the
--                             publish-complete signal for the publish-only path
local _al_dap_events_registered = false
local function register_al_dap_events(dap)
  if _al_dap_events_registered then return end
  _al_dap_events_registered = true

  -- Show all adapter output events in the floating window.
  dap.listeners.before["event_output"]["alnvim_output"] = function(_, body)
    if not (body and body.output) then return end
    local text = (body.output:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n$", ""))
    if text == "" then return end
    vim.schedule(function()
      local buf, win = ensure_output_win()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(text, "\n", { plain = true }))
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end)
  end

  -- The AL adapter's setBreakpoints handler does an indexed lookup of the source
  -- file in the project. It can throw ArgumentOutOfRangeException when:
  --   1. The source path contains a trailing slash or mismatched separators.
  --   2. The path isn't under projectRoot (e.g. a symbol-package stub file).
  -- Strip trailing slashes and ensure Unix separators before the request is sent.
  dap.listeners.before.setBreakpoints["alnvim"] = function(session, body)
    if not (body and body.source and body.source.path) then return end
    local p = body.source.path
    p = p:gsub("\\", "/")          -- Windows → Unix separators
    p = p:gsub("/+$", "")          -- strip trailing slash
    body.source.path = p
    -- Also normalise each breakpoint's column: the AL adapter ignores column
    -- but some versions throw on non-nil values — send nil explicitly.
    if type(body.breakpoints) == "table" then
      for _, bp in ipairs(body.breakpoints) do
        bp.column = nil
      end
    end
  end

  dap.listeners.before["event_al/openUri"]["alnvim"] = function(_, body)
    if not (body and body.uri) then return end
    require("al.platform").open_url(body.uri)
    vim.notify("AL: BC web client — " .. body.uri, vim.log.levels.INFO)
  end

  -- Fired by the adapter after a successful publish on all environment types.
  -- For publish-only mode a one-shot listener ("alnvim_publish_only") handles
  -- this instead and shows the success message; here we just update the status.
  dap.listeners.before["event_al/refreshExplorerObjects"]["alnvim"] = function()
    require("al.status").set_publish_result(true)
  end

  dap.listeners.before["event_al/deviceLogin"]["alnvim"] = function(_, body)
    if not body then return end
    local token = body.token or ""
    local uri   = body.uri   or ""
    -- Copy device code to clipboard and open the login page.
    vim.fn.setreg("+", token)
    require("al.platform").open_url(uri)
    vim.notify(
      string.format("AL: Device login — code %s copied to clipboard\n%s\n%s",
        token, body.message or "", uri),
      vim.log.levels.WARN)
  end
end

-- The AL adapter responds to configurationDone with {"command":null,...}.
-- nvim-dap's listener dispatch does listeners.before[decoded.command] without
-- a nil guard, so rawset(tbl, nil, {}) crashes with "table index is nil".
-- Patch both listener metatables to return {} for nil keys so the callback
-- that sets adapter_responded=true can still run.
local _dap_listeners_patched = false
local function patch_dap_nil_command(dap)
  if _dap_listeners_patched then return end
  _dap_listeners_patched = true
  for _, name in ipairs({ "before", "after" }) do
    local tbl = dap.listeners[name]
    local mt  = getmetatable(tbl)
    if mt and type(mt.__index) == "function" then
      local orig = mt.__index
      mt.__index = function(t, k)
        if k == nil then return {} end
        return orig(t, k)
      end
    end
  end
end

-- Build a minimal string-array environment for the DAP adapter process.
-- uv.spawn expects env as {"KEY=value", ...} (integer-keyed array).
-- Passing nil inherits Neovim's full env, which causes the adapter to SIGABRT
-- (likely due to NVIM/LD_* vars). Passing a Lua dict (non-integer keys) is
-- silently treated as an empty array by luv — adapter gets no env and works,
-- but then xdg-open cannot be found. A minimal string-array env gives the
-- adapter just enough context while keeping our stub dir at the front of PATH.
local function make_adapter_env()
  return require("al.platform").adapter_env(ensure_xdg_stub())
end

-- ── Live attach via nvim-dap ──────────────────────────────────────────────────
--
-- The AL debug adapter is the EditorServices.Host binary.
-- It speaks DAP over stdio when launched in adapter mode.
-- NOTE: The exact launch arguments for debug-adapter mode are not publicly
-- documented by Microsoft. This configuration may need adjustment – start with
-- :ALDebugSetup, then :DapContinue, and inspect :DapLog if it does not connect.

function M.setup_dap(root)
  local ok, dap = pcall(require, "dap")
  if not ok then
    vim.notify(
      "AL: nvim-dap not installed.\n"
      .. "Add { src = 'https://github.com/mfussenegger/nvim-dap' } to vim.pack.add",
      vim.log.levels.WARN)
    return
  end

  root = root or lsp.get_root()
  conn.pick_launch(root, function(cfg)
    patch_dap_nil_command(dap)
    register_al_dap_events(dap)

    local ext  = require("al").config.ext_path or require("al.ext").path
    local p    = require("al.platform")
    local host = ext .. "/bin/" .. p.bin_subdir() .. "/" .. p.exe("Microsoft.Dynamics.Nav.EditorServices.Host")

    dap.adapters.al = {
      type    = "executable",
      command = host,
      args    = { "/startDebugging", "/projectRoot:" .. require("al.platform").native_path(root) },
      options = {
        env      = make_adapter_env(),
        detached = not p.is_windows,
        initialize_timeout_sec = 30,
      },
    }

    local base   = conn.base_url(cfg)
    local tenant = cfg.tenant or "default"
    local user, pass = conn.user_password(cfg)

    dap.configurations.al = {
      {
        type                          = "al",
        request                       = "attach",
        name                          = "AL: Attach to " .. (cfg.serverInstance or "BC"),
        server                        = cfg.server or "http://localhost",
        serverInstance                = cfg.serverInstance or "BC",
        authentication                = cfg.authentication or "Windows",
        userName                      = user,
        password                      = pass,
        tenant                        = tenant,
        breakOnError                  = to_break_bool(cfg.breakOnError, true),
        breakOnRecordWrite            = to_break_bool(cfg.breakOnRecordWrite, false),
        breakOnNext                   = cfg.breakOnNext or "WebClient",
        enableSqlInformationDebugger  = cfg.enableSqlInformationDebugger  ~= false,
        enableLongRunningSqlStatements = cfg.enableLongRunningSqlStatements ~= false,
        longRunningSqlStatementsThreshold = cfg.longRunningSqlStatementsThreshold or 500,
        numberOfSqlStatements         = cfg.numberOfSqlStatements or 10,
      },
      {
        type           = "al",
        request        = "attach",
        name           = "AL: Attach to Web Service client",
        server         = cfg.server or "http://localhost",
        serverInstance = cfg.serverInstance or "BC",
        authentication = cfg.authentication or "Windows",
        userName       = user,
        password       = pass,
        tenant         = tenant,
        breakOnError   = to_break_bool(cfg.breakOnError, true),
        breakOnNext    = "WebServiceClient",
      },
    }

    vim.notify(
      "AL: nvim-dap configured for " .. base .. "\nRun :DapContinue to attach.",
      vim.log.levels.INFO)
  end)
end

-- Apply the fields that VSCode computes and adds to every DAP launch request.
-- These are NOT in launch.json; VSCode derives them from launch.json values or
-- global settings. The 18.x adapter requires them — missing fields cause
-- "An internal error has occurred" before any HTTP call is made.
--
-- @param cfg        the launch config table to mutate in place
-- @param root       project root path (native separators on Windows)
-- @param boe        breakOnError boolean (already converted from string)
-- @param borw       breakOnRecordWrite boolean (already converted from string)
-- @param root   project root (native path) — used to set directory field
local function apply_vscode_defaults(cfg, root, boe, borw)
  -- Boolean conversions — C# deserialiser rejects string enum values ("All", "None").
  cfg.breakOnError                = boe
  cfg.breakOnRecordWrite          = borw
  -- VSCode always computes and sends these as ValueAsNotBoolean(...).
  cfg.breakOnErrorBehaviour       = not boe
  cfg.breakOnRecordWriteBehaviour = not borw
  -- VSCode always sends these three; adapter may require them to know session type.
  cfg.publishOnly = cfg.publishOnly or false
  cfg.isRad       = cfg.isRad       or false
  cfg.justDebug   = cfg.justDebug   or false
  -- Port: VSCode sends r.port || DefaultDevEndpointPort (7049).
  if cfg.port == nil then cfg.port = 7049 end
  -- validateServerCertificate: VSCode sends r.validateServerCertificate ?? true.
  if cfg.validateServerCertificate == nil then cfg.validateServerCertificate = true end
  -- useMcpServerForDebugging: when true the adapter uses BC Management Services (port 7047)
  -- for BOTH publish and debug session registration instead of the dev endpoint (port 7049).
  -- AL 18.0 / VSCode defaults this to true. BCContainerHelper containers expose port 7047
  -- by default (alongside 7049), so using true should work and matches VSCode behaviour.
  -- BC's dev endpoint (7049) does not support live debug session registration in newer BC
  -- versions — only port 7047 (MCP) does — which explains why false always fails.
  if cfg.useMcpServerForDebugging == nil then cfg.useMcpServerForDebugging = true end
  if cfg.mcpServerPort            == nil then cfg.mcpServerPort            = 7047 end
  -- directory: where the adapter looks for the compiled .app file.
  -- VSCode always sends this (as getAlParams().outFolder). Default to the project root.
  if cfg.directory == nil and root then
    cfg.directory = require("al.platform").native_path(root)
  end
  -- schemaUpdateMode: how the adapter handles schema changes during publish.
  -- VSCode defaults to "synchronize". Absence causes nil publish body field.
  if cfg.schemaUpdateMode == nil then cfg.schemaUpdateMode = "synchronize" end
  -- startupObjectType: paired with startupObjectId (default 22 = Customer List).
  -- VSCode defaults to "Page". Missing this alongside startupObjectId can cause
  -- a null-ref in the adapter when building the WebClient navigation URL.
  if cfg.startupObjectType == nil then cfg.startupObjectType = "Page" end
  -- dependencyPublishingOption: controls how dependent apps are published.
  -- VSCode defaults to "default". Absence may cause adapter null-ref.
  if cfg.dependencyPublishingOption == nil then cfg.dependencyPublishingOption = "default" end
end

-- Publish the compiled .app to BC via the adapter without starting a debug session.
-- Works on all BC versions (adapter handles the correct publish API internally).
-- Falls back to direct HTTP publish if nvim-dap is not installed.
function M.publish_only(root)
  local ok, dap = pcall(require, "dap")
  if not ok then
    require("al.publish").publish(root)
    return
  end

  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  restore_bak_if_exists(root)
  reset_output_win()

  conn.pick_launch(root, function(cfg)
    patch_dap_nil_command(dap)
    register_al_dap_events(dap)

    local ext  = require("al").config.ext_path or require("al.ext").path
    local p    = require("al.platform")
    local host = ext .. "/bin/" .. p.bin_subdir() .. "/" .. p.exe("Microsoft.Dynamics.Nav.EditorServices.Host")
    local user, pass = conn.user_password(cfg)

    dap.adapters.al = {
      type    = "executable",
      id      = "al",     -- nvim-dap sends this as adapterID in DAP initialize
      command = host,
      args    = { "/startDebugging", "/logLevel:Verbose",
                  "/projectRoot:" .. require("al.platform").native_path(root) },
      options = {
        env      = make_adapter_env(),
        cwd      = root,   -- adapter must run from project root to find the .app
        detached = not p.is_windows,
        initialize_timeout_sec = 30,
      },
      reverse_request_handlers = {
        ["al/launchDeviceLoginWindow"] = function(session, request)
          local uri = ((request.arguments or {}).Uri or "")
          if uri ~= "" then
            require("al.platform").open_url(uri)
            vim.notify("AL: Opening device login — " .. uri, vim.log.levels.INFO)
          end
          session:response(request, {})
        end,
      },
    }

    -- Pass through ALL fields from launch.json unchanged (deepcopy), then apply
    -- only the transforms VSCode applies. Do NOT inject userName/password here —
    -- VSCode does not include them in the DAP launch request; the adapter reads
    -- credentials from the LSP credential store (populated by save_creds_to_lsp).
    local launch_cfg = vim.deepcopy(cfg)
    launch_cfg.type    = "al"
    launch_cfg.request = "launch"
    -- On Linux/macOS: adapter's launchBrowser calls xdg-open (our no-op stub); open
    -- from Lua instead via the refreshExplorerObjects event listener below.
    -- On Windows: adapter opens the browser natively — leave launchBrowser as-is.
    if not p.is_windows then
      launch_cfg.launchBrowser = false
    end
    -- BCContainer launch.json uses environmentType="Sandbox" with a custom server URL.
    -- Force "OnPrem" so the adapter uses on-prem routing, not cloud Entra auth.
    if not conn.is_cloud(cfg) then
      launch_cfg.environmentType = "OnPrem"
      -- BCContainerHelper sets usePublicURLFromServer=true; causes adapter to call an
      -- AAD-backed endpoint to resolve the public URL — fails on local containers.
      launch_cfg.usePublicURLFromServer = false
    end
    -- Publish-only: never break on errors (not a debug session).
    apply_vscode_defaults(launch_cfg, root, false, false)

    -- One-shot listener: fires when the adapter signals publish is complete.
    -- Disconnect so the adapter exits cleanly without starting a debug session
    -- (which would occupy the BC debug slot and block a subsequent ALLaunch).
    dap.listeners.before["event_al/refreshExplorerObjects"]["alnvim_publish_only"] = function()
      dap.listeners.before["event_al/refreshExplorerObjects"]["alnvim_publish_only"] = nil
      vim.notify("AL: Published successfully", vim.log.levels.INFO)
      -- On Linux/macOS: launchBrowser=true makes the adapter call xdg-open (our stub).
      -- Open from Lua instead. On Windows: adapter opens the browser natively — skip.
      if not p.is_windows then
        require("al.platform").open_url(conn.webclient_url(cfg))
      end
      vim.schedule(function()
        if dap.session() then dap.disconnect({ terminateDebuggee = false }) end
      end)
    end

    require("al.compile").compile(root, nil, function()
      -- Verify the .app was produced before handing off to the adapter.
      local app_json = require("al.lsp").read_app_json(root)
      local app_file = app_json and require("al.publish").find_app(root, app_json)
      if not app_file then
        vim.notify(
          "AL: Compile succeeded but no .app found in " .. root
          .. "\nCheck that alc is producing output to the project root.",
          vim.log.levels.ERROR)
        return
      end
      vim.notify("AL: Publishing " .. vim.fn.fnamemodify(app_file, ":t") .. " …", vim.log.levels.INFO)
      -- Pass launch_cfg (resolved config) so the LSP stores credentials under the
      -- same key the adapter will look up (environmentType=OnPrem, etc.).
      save_creds_to_lsp(launch_cfg, user, pass, function()
        dap.run(launch_cfg)
      end)
    end)
  end)
end

function M.launch(root)
  local ok, dap = pcall(require, "dap")
  if not ok then
    vim.notify(
      "AL: nvim-dap not installed.\n"
      .. "Add { src = 'https://github.com/mfussenegger/nvim-dap' } to vim.pack.add",
      vim.log.levels.WARN)
    return
  end

  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  restore_bak_if_exists(root)
  reset_output_win()

  conn.pick_launch(root, function(cfg)
    patch_dap_nil_command(dap)
    register_al_dap_events(dap)

    local ext  = require("al").config.ext_path or require("al.ext").path
    local p    = require("al.platform")
    local host = ext .. "/bin/" .. p.bin_subdir() .. "/" .. p.exe("Microsoft.Dynamics.Nav.EditorServices.Host")
    local user, pass = conn.user_password(cfg)

    local function register_adapter()
      dap.adapters.al = {
        type    = "executable",
        id      = "al",     -- nvim-dap sends this as adapterID in DAP initialize
        command = host,
        args    = { "/startDebugging", "/logLevel:Verbose",
                    "/projectRoot:" .. require("al.platform").native_path(root) },
        options = {
          env      = make_adapter_env(),
          cwd      = root,   -- adapter must run from project root to find the .app
          detached = not p.is_windows,
          initialize_timeout_sec = 30,
        },
        reverse_request_handlers = {
          ["al/launchDeviceLoginWindow"] = function(session, request)
            local uri = ((request.arguments or {}).Uri or "")
            if uri ~= "" then
              require("al.platform").open_url(uri)
              vim.notify("AL: Opening device login — " .. uri, vim.log.levels.INFO)
            end
            session:response(request, {})
          end,
        },
      }
    end

    -- ── On-prem ───────────────────────────────────────────────────────────────
    local is_cloud = conn.is_cloud(cfg)
    if not is_cloud then
      -- Deepcopy launch.json fields, then apply only VSCode's transforms.
      -- userName/password are NOT injected — VSCode doesn't include them in the DAP
      -- launch request; credentials are passed via save_creds_to_lsp instead.
      local launch_cfg = vim.deepcopy(cfg)
      launch_cfg.type    = "al"
      launch_cfg.request = "launch"
      -- On Linux/macOS: adapter calls xdg-open (no-op stub); open from Lua instead.
      -- On Windows: adapter opens the browser natively — leave launchBrowser as-is.
      if not p.is_windows then
        launch_cfg.launchBrowser = false
      end
      -- BCContainer launch.json uses environmentType="Sandbox" with a custom server URL.
      -- Force "OnPrem" so the adapter uses on-prem routing and auth, not cloud Entra.
      launch_cfg.environmentType = "OnPrem"
      -- BCContainerHelper sets usePublicURLFromServer=true; this causes the adapter to call
      -- an AAD-backed Azure endpoint to resolve the public URL, which returns HTTP 500 on
      -- containers with conflicting AzureActiveDirectoryClientCertificateThumbprint / Secret.
      launch_cfg.usePublicURLFromServer = false
      apply_vscode_defaults(launch_cfg, root,
        to_break_bool(cfg.breakOnError, true),
        to_break_bool(cfg.breakOnRecordWrite, false))
      dap.configurations.al = { launch_cfg }

      -- On Linux/macOS: adapter calls xdg-open (our no-op stub). Open from Lua instead.
      -- On Windows: adapter opens the browser natively via launchBrowser — skip here.
      dap.listeners.before["event_al/refreshExplorerObjects"]["alnvim_launch_browser"] = function()
        dap.listeners.before["event_al/refreshExplorerObjects"]["alnvim_launch_browser"] = nil
        if not p.is_windows then
          local url = conn.webclient_url(cfg)
          require("al.platform").open_url(url)
          vim.notify("AL: BC web client — " .. url, vim.log.levels.INFO)
        end
      end

      require("al.compile").compile(root, nil, function()
        local app_json = require("al.lsp").read_app_json(root)
        local app_file = app_json and require("al.publish").find_app(root, app_json)
        if not app_file then
          vim.notify(
            "AL: Compile succeeded but no .app found in " .. root
            .. "\nCheck that alc is producing output to the project root.",
            vim.log.levels.ERROR)
          return
        end
        vim.notify(
          "AL: Compile succeeded — publishing " .. vim.fn.fnamemodify(app_file, ":t") .. " …",
          vim.log.levels.INFO)
        -- Save credentials to LSP store before starting the adapter.
        -- Pass launch_cfg (resolved config) so the LSP stores under the same key
        -- the adapter will look up (environmentType=OnPrem instead of Sandbox, etc.).
        save_creds_to_lsp(launch_cfg, user, pass, function()
          register_adapter()
          dap.run(launch_cfg)
        end)
      end)
      return
    end

    -- ── Cloud ─────────────────────────────────────────────────────────────────
    -- Pass through ALL fields; only fix types. launchBrowser=false because the
    -- debug-context URL comes from the al/openUri DAP event (handled below).
    local launch_cfg = vim.deepcopy(cfg)
    launch_cfg.type          = "al"
    launch_cfg.request       = "launch"
    launch_cfg.launchBrowser = false  -- browser opened from Lua via al/openUri event
    apply_vscode_defaults(launch_cfg, root,
      to_break_bool(cfg.breakOnError, true),
      to_break_bool(cfg.breakOnRecordWrite, false))
    dap.configurations.al = { launch_cfg }

    require("al.compile").compile(root, nil, function()
      vim.notify("AL: Compile succeeded — adapter is publishing and attaching…", vim.log.levels.INFO)
      register_adapter()
      dap.run(launch_cfg)
      -- Browser opened by al/openUri event (includes the debug-context URL).
    end)
  end)
end

M.show_output = show_output_win

return M
