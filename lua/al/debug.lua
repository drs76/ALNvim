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

-- Minimal JSONC comment stripper (single-line // only; preserves URLs).
local function strip_jsonc(text)
  local lines = {}
  for line in text:gmatch("[^\n]*") do
    lines[#lines + 1] = line:gsub("([^:/])//[^\n]*$", "%1")
  end
  return table.concat(lines, "\n")
end

local function patch_launch_json(root)
  local path = root .. "/.vscode/launch.json"
  local f = io.open(path, "r")
  if not f then return nil end
  local original = f:read("*a")
  f:close()

  -- Parse via JSON (stripping JSONC comments first)
  local ok, data = pcall(vim.fn.json_decode, strip_jsonc(original))
  if not ok or type(data) ~= "table" then return nil end

  local changed = false
  for _, cfg_entry in ipairs(data.configurations or {}) do
    if cfg_entry.type == "al" then
      -- breakOnError / breakOnRecordWrite: string enum → bool
      for _, field in ipairs({ "breakOnError", "breakOnRecordWrite" }) do
        local v = cfg_entry[field]
        if type(v) == "string" then
          cfg_entry[field] = (v == "All" or v == "ExcludeTry" or v == "ExcludeTemporary")
          changed = true
        end
      end
      -- launchBrowser: adapter's own browser open fails; handled from Lua
      if cfg_entry.launchBrowser == true then
        cfg_entry.launchBrowser = false
        changed = true
      end
    end
  end

  if not changed then return nil end

  -- Write backup (preserves original with comments intact)
  local bak = path .. ".alnvim.bak"
  local fb = io.open(bak, "w")
  if not fb then return nil end
  fb:write(original)
  fb:close()

  -- Write patched JSON (comments stripped, but backup restores the original)
  local fw = io.open(path, "w")
  if not fw then os.remove(bak) return nil end
  fw:write(vim.fn.json_encode(data))
  fw:close()

  return bak
end

local function restore_launch_json(root, bak)
  if not bak then return end
  local path = root .. "/.vscode/launch.json"
  local f = io.open(bak, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  local fw = io.open(path, "w")
  if fw then fw:write(content) fw:close() end
  os.remove(bak)
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

-- Register listeners for the two custom AL DAP events the adapter fires.
-- al/openUri   — adapter sends the real BC web client URL (with debug context)
--               after publishing; we open the browser here, not in open_browser().
-- al/deviceLogin — OAuth2 device code flow; adapter sends message + token + URI;
--               copy the code to clipboard and open the login URL.
-- al/launchDeviceLoginWindow — reverse request (server→client); adapter asks us
--               to open the browser for device login. Must send a response.
local _al_dap_events_registered = false
local function register_al_dap_events(dap)
  if _al_dap_events_registered then return end
  _al_dap_events_registered = true

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
  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  patch_dap_nil_command(dap)
  register_al_dap_events(dap)

  local ext  = require("al").config.ext_path or require("al.ext").path
  local p    = require("al.platform")
  local host = ext .. "/bin/" .. p.bin_subdir() .. "/" .. p.exe("Microsoft.Dynamics.Nav.EditorServices.Host")

  dap.adapters.al = {
    type    = "executable",
    command = host,
    args    = { "/startDebugging", "/projectRoot:" .. root },
    options = {
      env = make_adapter_env(),
      initialize_timeout_sec = 30,
    },
  }

  local base   = conn.base_url(cfg)
  local tenant = cfg.tenant or "default"

  -- Map the launch.json attach configuration to a nvim-dap configuration
  dap.configurations.al = {
    {
      type                          = "al",
      request                       = "attach",
      name                          = "AL: Attach to " .. (cfg.serverInstance or "BC"),
      server                        = cfg.server or "http://localhost",
      serverInstance                = cfg.serverInstance or "BC",
      authentication                = cfg.authentication or "Windows",
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
      type          = "al",
      request       = "attach",
      name          = "AL: Attach to Web Service client",
      server        = cfg.server or "http://localhost",
      serverInstance = cfg.serverInstance or "BC",
      authentication = cfg.authentication or "Windows",
      tenant        = tenant,
      breakOnError  = to_break_bool(cfg.breakOnError, true),
      breakOnNext   = "WebServiceClient",
    },
  }

  vim.notify(
    "AL: nvim-dap configured for " .. base .. "\nRun :DapContinue to attach.",
    vim.log.levels.INFO)
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

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  patch_dap_nil_command(dap)
  register_al_dap_events(dap)

  local ext  = require("al").config.ext_path or require("al.ext").path
  local p    = require("al.platform")
  local host = ext .. "/bin/" .. p.bin_subdir() .. "/" .. p.exe("Microsoft.Dynamics.Nav.EditorServices.Host")

  local function register_adapter()
    dap.adapters.al = {
      type    = "executable",
      command = host,
      args    = { "/startDebugging", "/projectRoot:" .. root },
      options = {
        env = make_adapter_env(),
        initialize_timeout_sec = 30,
      },
      -- al/launchDeviceLoginWindow is a server-initiated request asking us to
      -- open the browser for OAuth2 device code login. Must send back a response.
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

  -- For on-prem "attach" path only: open the BC web client after HTTP publish
  -- so the user can start a session. Cloud uses al/openUri from the adapter instead.
  local function open_browser_onprem()
    if not cfg.launchBrowser then return end
    local url = conn.webclient_url(cfg)
    require("al.platform").open_url(url)
    vim.notify("AL: BC web client — " .. url, vim.log.levels.INFO)
  end

  -- ── On-prem: compile → HTTP publish → DAP "attach" ───────────────────────
  -- Treat any non-cloud environmentType (nil, "OnPrem", etc.) as on-prem.
  -- Cloud is only "Sandbox" or "Production" (Azure BC).
  -- The DAP "launch" request triggers a browser-open inside the adapter that
  -- fails on Linux; for on-prem we publish via HTTP ourselves and use "attach".
  local is_cloud = conn.is_cloud(cfg)
  if not is_cloud then
    local attach_cfg = {
      type               = "al",
      request            = "attach",
      name               = "AL: Attach (after publish)",
      server             = cfg.server,
      serverInstance     = cfg.serverInstance,
      authentication     = cfg.authentication or "Windows",
      tenant             = cfg.tenant or "default",
      breakOnError       = to_break_bool(cfg.breakOnError, true),
      breakOnNext        = cfg.breakOnNext or "WebClient",
      breakOnRecordWrite = to_break_bool(cfg.breakOnRecordWrite, false),
      enableSqlInformationDebugger      = cfg.enableSqlInformationDebugger  ~= false,
      enableLongRunningSqlStatements    = cfg.enableLongRunningSqlStatements ~= false,
      longRunningSqlStatementsThreshold = cfg.longRunningSqlStatementsThreshold or 500,
      numberOfSqlStatements             = cfg.numberOfSqlStatements or 10,
      -- Adapter reads launch.json AND DAP request for launchBrowser; set false
      -- in both places so it never tries to invoke xdg-open itself.
      launchBrowser      = false,
    }
    dap.configurations.al = { attach_cfg }

    require("al.compile").compile(root, nil, function()
      vim.notify("AL: Compile succeeded — uploading to BC…", vim.log.levels.INFO)
      -- Patch launch.json so the adapter sees launchBrowser=false even if it
      -- reads the file directly (which it does for both launch and attach).
      local bak = patch_launch_json(root)
      if bak then
        local restored = false
        local function restore()
          if not restored then
            restored = true
            dap.listeners.after.event_terminated["alnvim_restore_launch"] = nil
            dap.listeners.after.event_exited["alnvim_restore_launch"]     = nil
            restore_launch_json(root, bak)
          end
        end
        dap.listeners.after.event_terminated["alnvim_restore_launch"] = restore
        dap.listeners.after.event_exited["alnvim_restore_launch"]     = restore
      end
      -- skip_compile=true: upload whatever .app the compile just produced.
      require("al.publish").publish(root, true, function()
        vim.notify("AL: Published — attaching debugger…", vim.log.levels.INFO)
        register_adapter()
        dap.run(attach_cfg)
        open_browser_onprem()
      end)
    end)
    return
  end

  -- ── Cloud: compile → DAP "launch" (adapter handles publish + attach) ─────
  -- Cloud endpoints reject direct HTTP publish (HTTP 415), so we must use
  -- the adapter's "launch" request.  We patch launch.json to suppress the
  -- adapter's built-in browser-open (which also fails on Linux) and open
  -- the URL from Lua instead.
  local launch_cfg = {
    type               = "al",
    request            = "launch",
    name               = "AL: Launch",
    schemaUpdateMode   = cfg.schemaUpdateMode or "synchronize",
    environmentType    = cfg.environmentType,
    environmentName    = cfg.environmentName,
    tenant             = cfg.tenant,
    primaryTenantDomain = cfg.primaryTenantDomain,
    authentication     = cfg.authentication or "MicrosoftEntraID",
    breakOnError       = to_break_bool(cfg.breakOnError, true),
    breakOnNext        = cfg.breakOnNext or "WebClient",
    breakOnRecordWrite = to_break_bool(cfg.breakOnRecordWrite, false),
    enableSqlInformationDebugger      = cfg.enableSqlInformationDebugger  ~= false,
    enableLongRunningSqlStatements    = cfg.enableLongRunningSqlStatements ~= false,
    longRunningSqlStatementsThreshold = cfg.longRunningSqlStatementsThreshold or 500,
    numberOfSqlStatements             = cfg.numberOfSqlStatements or 10,
    launchBrowser      = false,
    startupObjectType  = cfg.startupObjectType or "Page",
    startupObjectId    = cfg.startupObjectId or 22,
  }
  dap.configurations.al = { launch_cfg }

  require("al.compile").compile(root, nil, function()
    vim.notify("AL: Compile succeeded — adapter is publishing and attaching…", vim.log.levels.INFO)

    local bak = patch_launch_json(root)
    if bak then
      local restored = false
      local function restore()
        if not restored then
          restored = true
          dap.listeners.after.event_terminated["alnvim_restore_launch"] = nil
          dap.listeners.after.event_exited["alnvim_restore_launch"]     = nil
          restore_launch_json(root, bak)
        end
      end
      dap.listeners.after.event_terminated["alnvim_restore_launch"] = restore
      dap.listeners.after.event_exited["alnvim_restore_launch"]     = restore
    end

    register_adapter()
    dap.run(launch_cfg)
    -- Browser will be opened by the al/openUri event the adapter fires
    -- after it finishes publishing (includes the debug-context in the URL).
  end)
end

return M
