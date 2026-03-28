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

  local ext  = require("al").config.ext_path or require("al.ext").path
  local host = ext .. "/bin/linux/Microsoft.Dynamics.Nav.EditorServices.Host"

  install_xdg_open_stub()

  -- Register the adapter — no options.env so uv.spawn inherits Neovim's env.
  dap.adapters.al = {
    type    = "executable",
    command = host,
    args    = { "/startDebugging", "/projectRoot:" .. root },
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

-- ── launch.json patching ─────────────────────────────────────────────────────
--
-- The v18 adapter reads .vscode/launch.json directly via /projectRoot: before
-- processing DAP arguments. It deserialises breakOnError strictly as bool
-- ("All" string → exception), and it tries xdg-open when launchBrowser is true.
-- We patch the file in-place before launching and restore it afterwards.

local function patch_launch_json(root)
  local path = root .. "/.vscode/launch.json"
  local f = io.open(path, "r")
  if not f then return nil end
  local original = f:read("*a")
  f:close()

  local patched = original
  -- breakOnError / breakOnRecordWrite: "All"|"ExcludeTry"|"ExcludeTemporary" → true, "None" → false
  for _, field in ipairs({ "breakOnError", "breakOnRecordWrite" }) do
    local esc = field:gsub("([^%w])", "%%%1")
    patched = patched:gsub('"' .. esc .. '"%s*:%s*"All"',             '"' .. field .. '": true')
    patched = patched:gsub('"' .. esc .. '"%s*:%s*"ExcludeTry"',      '"' .. field .. '": true')
    patched = patched:gsub('"' .. esc .. '"%s*:%s*"ExcludeTemporary"','"' .. field .. '": true')
    patched = patched:gsub('"' .. esc .. '"%s*:%s*"None"',            '"' .. field .. '": false')
  end
  -- launchBrowser: adapter xdg-open fails on Linux; we open the URL from Lua
  patched = patched:gsub('"launchBrowser"%s*:%s*true', '"launchBrowser": false')

  if patched == original then return nil end  -- nothing to patch

  -- Write backup alongside the original
  local bak = path .. ".alnvim.bak"
  local fb = io.open(bak, "w")
  if not fb then return nil end
  fb:write(original)
  fb:close()

  local fw = io.open(path, "w")
  if not fw then os.remove(bak) return nil end
  fw:write(patched)
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

-- Create a no-op xdg-open stub and prepend its directory to Neovim's own PATH
-- so all child processes (including the DAP adapter and its children) inherit
-- it and find our stub before the system xdg-open.
-- Called once; subsequent calls skip the write and the PATH prepend if already done.
local _xdg_stub_installed = false
local function install_xdg_open_stub()
  if _xdg_stub_installed then return end
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
  -- Prepend to Neovim's process PATH so the adapter inherits it.
  local current_path = os.getenv("PATH") or ""
  if not current_path:find(dir .. ":", 1, true) then
    vim.fn.setenv("PATH", dir .. ":" .. current_path)
  end
  _xdg_stub_installed = true
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

  local ext  = require("al").config.ext_path or require("al.ext").path
  local host = ext .. "/bin/linux/Microsoft.Dynamics.Nav.EditorServices.Host"

  -- Adapter registration shared by both paths.
  -- No options.env: let uv.spawn inherit Neovim's full environment so the
  -- adapter gets our setenv-patched PATH (with the xdg-open stub dir) and
  -- DISPLAY.  Passing a Lua dict as options.env causes luv to hand libuv an
  -- empty string array, giving the adapter NO environment at all.
  local function register_adapter()
    install_xdg_open_stub()
    dap.adapters.al = {
      type    = "executable",
      command = host,
      args    = { "/startDebugging", "/projectRoot:" .. root },
    }
  end

  local function open_browser()
    if not cfg.launchBrowser then return end
    local url = conn.webclient_url(cfg)
    if vim.ui.open then
      vim.ui.open(url)
    else
      vim.fn.jobstart({ "xdg-open", url }, { detach = true })
    end
  end

  -- ── On-prem: compile → HTTP publish → DAP "attach" ───────────────────────
  -- The DAP "launch" request triggers a browser-open inside the adapter that
  -- fails on Linux (xdg-open or similar tools cannot run from the .NET subprocess
  -- context).  For on-prem we can publish via HTTP ourselves and then attach,
  -- which bypasses the adapter's browser-open code path entirely.
  if not cfg.environmentType then
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
        open_browser()
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
    open_browser()
  end)
end

return M
