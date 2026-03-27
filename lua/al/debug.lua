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

  -- Register the adapter (stdio transport, same binary as the LSP)
  dap.adapters.al = {
    type    = "executable",
    command = host,
    args    = {},
    options = {
      env = { DOTNET_ROOT = "/usr/share/dotnet" },
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
      breakOnError                  = cfg.breakOnError or "All",
      breakOnRecordWrite            = cfg.breakOnRecordWrite or "None",
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
      breakOnError  = cfg.breakOnError or "All",
      breakOnNext   = "WebServiceClient",
    },
  }

  vim.notify(
    "AL: nvim-dap configured for " .. base .. "\nRun :DapContinue to attach.",
    vim.log.levels.INFO)
end

-- ── Launch (F5 equivalent) ────────────────────────────────────────────────────
--
-- Mirrors the VSCode F5 flow: compile → publish → attach debugger.
-- Requires nvim-dap. Configures the AL adapter (same as :ALDebugSetup) then
-- chains into publish so the debugger attaches as soon as the app is live.

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

  -- Ensure the DAP adapter and configuration are up to date for this project.
  M.setup_dap(root)

  -- Compile → publish; on successful upload, attach the debugger.
  require("al.publish").publish(root, false, function()
    vim.notify("AL: Attaching debugger…", vim.log.levels.INFO)
    dap.continue()
  end)
end

return M
