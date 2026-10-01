-- Compile the AL project then publish the resulting .app to Business Central.
--
-- One backend: `al publishapp` from the AL dotnet tool — every BC version,
-- AAD/Windows/UserPassword auth built in, reads launch.json. There is no
-- fallback to the VS Code extension's DAP adapter or to a direct HTTP POST;
-- see M.publish for why.
--
-- After a successful upload the BC client URL is opened in the browser when
-- launchBrowser = true in launch.json.

local M    = {}
local conn  = require("al.connection")
local lsp   = require("al.lsp")

-- Find the compiled .app in the project root.
-- Tries the standard Publisher_Name_Version.app name first, then globs.
-- Also exported as M.find_app so debug.lua can pre-flight check the .app exists.
local function find_app_file(root, app_json)
  local function safe(s) return (s or ""):gsub("[/\\%?%%*:|\"<>]", "_") end
  local names = {
    root .. "/" .. safe(app_json.publisher) .. "_"
               .. safe(app_json.name) .. "_"
               .. (app_json.version or "0.0.0.0") .. ".app",
    root .. "/output/" .. safe(app_json.publisher) .. "_"
                       .. safe(app_json.name) .. "_"
                       .. (app_json.version or "0.0.0.0") .. ".app",
  }
  for _, p in ipairs(names) do
    if vim.fn.filereadable(p) == 1 then return p end
  end
  -- Glob fallback: pick the most recently modified .app in the project root
  local found = vim.fn.glob(root .. "/*.app", false, true)
  if #found > 0 then
    table.sort(found, function(a, b)
      local sa = vim.uv.fs_stat(a)
      local sb = vim.uv.fs_stat(b)
      return (sa and sa.mtime.sec or 0) > (sb and sb.mtime.sec or 0)
    end)
    return found[1]
  end
end

-- ── `al publishapp` ───────────────────────────────────────────────────────────

-- Build `al publishapp` args from the picked launch configuration. Explicit
-- flags override launch.json so the user's config picker choice wins even
-- when launch.json has several configurations (the CLI would take the first).
-- The connection flags come from altool, shared with symbol downloads, so one
-- launch configuration means one server to every operation.
local function publishapp_args(root, cfg, app_file)
  -- Explicit appPath: newer tool builds (18.0.37+) no longer search for the
  -- .app when --project is given — they demand a build delegate instead
  -- ("No .app file specified and build delegate is not available").
  local a = { "publishapp", app_file, "--project", root }
  if cfg.schemaUpdateMode then
    vim.list_extend(a, { "--schemaupdatemode", cfg.schemaUpdateMode })
  end
  vim.list_extend(a, require("al.altool").connection_flags(cfg))
  return a
end

-- Publish via `al publishapp`, streaming output into a float.
local function publish_dotnet(root, cfg, app_file, on_success)
  local altool = require("al.altool")
  require("al.status").set_publishing()
  altool.run(publishapp_args(root, cfg, app_file), {
    title = "AL: Publishing (al publishapp)",
    cwd   = root,
    env   = altool.cred_env(cfg),
  }, function(ok, code, log, win)
    require("al.status").set_publish_result(ok)
    if not ok then
      log({ "", "── Publish failed (exit " .. code .. ") ──" })
      vim.notify("AL: Publish failed (al publishapp exit " .. code .. ") — see float",
        vim.log.levels.ERROR)
      return
    end
    log({ "", "── Published successfully ──" })
    vim.notify("AL: Published successfully", vim.log.levels.INFO)
    altool.close_later(win)
    if cfg.launchBrowser then
      local browser = require("al.cops").get_browser(root)
      require("al.platform").open_url(conn.webclient_url(cfg), browser)
    end
    if on_success then on_success() end
  end)
end

-- ── Dispatcher ────────────────────────────────────────────────────────────────

-- Compile then publish via the best available backend.
-- @param root         Optional project root override.
-- @param skip_compile If true, skip compilation and publish whatever .app exists.
-- @param on_success   Optional callback invoked after a successful upload.
function M.publish(root, skip_compile, on_success)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end
  local app = lsp.read_app_json(root)
  if not app then
    vim.notify("AL: Cannot read app.json", vim.log.levels.ERROR)
    return
  end

  -- `al publishapp` only. There used to be two fallbacks behind it — the DAP
  -- adapter (VS Code extension) and a direct HTTP POST — and they are what
  -- made a missing tool look like a crash: on Windows, with the tool not
  -- found, publishing fell through to the DAP adapter, which cannot publish to
  -- on-prem there ("Could not publish the package"). The HTTP POST is also
  -- rejected by BC 25+ (HTTP 415). The tool publishes to every BC version with
  -- AAD, Windows and UserPassword auth built in, so failing loudly beats
  -- degrading silently to something that cannot work.
  local altool = require("al.altool")
  if not altool.available() then
    vim.notify(altool.missing_msg("Publishing"), vim.log.levels.ERROR)
    return
  end
  if not altool.has("publishapp") then
    vim.notify("AL: this AL dotnet tool has no `publishapp` command — update it:"
      .. " :ALInstallDotnetTool", vim.log.levels.ERROR)
    return
  end

  conn.pick_launch(root, function(cfg)
    local function go()
      local app_file = find_app_file(root, app)
      if not app_file then
        vim.notify("AL: No .app file found. Run :ALCompile first.", vim.log.levels.ERROR)
        return
      end
      publish_dotnet(root, cfg, app_file, on_success)
    end
    if skip_compile then go() else require("al.compile").compile(root, nil, go) end
  end)
end

M.find_app = find_app_file

return M
