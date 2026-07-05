-- Compile the AL project then publish the resulting .app to Business Central.
--
-- Publish backends, in order of preference (M.publish dispatches):
--   1. `al publishapp` (dotnet AL tool) — extension-free, all BC versions,
--      handles AAD/Windows/UserPassword auth itself, reads launch.json.
--   2. DAP adapter (EditorServices.Host via nvim-dap) — debug.publish_only.
--   3. Direct HTTP POST to <base>/dev/apps (M.publish_http) — BC < 25 only
--      (newer versions return 415 for external octet-stream posts).
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

local function do_upload(root, base, tenant, schema, auth, app_file, cfg, on_success)
  local url = string.format("%s/dev/apps?tenant=%s&SchemaUpdateMode=%s",
    base, conn.urlencode(tenant), conn.urlencode(schema))

  -- Drop --fail so the BC error response body is captured; use -w to append the
  -- HTTP status as a sentinel line we can parse regardless of exit code.
  -- BC 25+ changed the /dev/apps publish endpoint; direct HTTP upload may return
  -- 415 on newer versions. For debugging use :ALLaunch — the adapter handles
  -- publishing internally for all BC versions. :ALPublish works on BC < 25.
  local cmd = {
    "curl", "-sL", "-X", "POST",
    "-H", "Content-Type: application/octet-stream",
    "--data-binary", "@" .. app_file,
    "-w", "\n__STATUS__%{http_code}",
  }
  vim.list_extend(cmd, auth)
  table.insert(cmd, url)

  vim.notify(
    "AL: Uploading " .. vim.fn.fnamemodify(app_file, ":t") .. " to " .. base .. "…",
    vim.log.levels.INFO)
  require("al.status").set_publishing()

  local output = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) vim.list_extend(output, data) end,
    on_stderr = function(_, data) vim.list_extend(output, data) end,
    on_exit = vim.schedule_wrap(function(_, _code)
      -- Extract HTTP status from sentinel line; strip it from body.
      local raw = table.concat(output, "\n")
      local body, http_status = raw:match("^(.-)\n__STATUS__(%d+)%s*$")
      if not http_status then
        body        = raw
        http_status = "0"
      end
      local status = tonumber(http_status) or 0
      body = body:gsub("^%s+", ""):gsub("%s+$", "")

      local pub_ok = status >= 200 and status < 300
      require("al.status").set_publish_result(pub_ok)
      if pub_ok then
        vim.notify("AL: Published successfully", vim.log.levels.INFO)
        if cfg and cfg.launchBrowser then
          local browser = require("al.cops").get_browser(root)
          require("al.platform").open_url(conn.webclient_url(cfg), browser)
        end
        if on_success then on_success() end
      elseif status == 415 then
        vim.notify(
          "AL: Publish failed (HTTP 415 Unsupported Media Type)\n"
          .. "BC 25+ no longer accepts direct HTTP publish.\n"
          .. "Use :ALLaunch instead — the adapter handles publishing for all BC versions.",
          vim.log.levels.ERROR)
      else
        vim.notify(
          string.format("AL: Publish failed (HTTP %s)%s",
            http_status, body ~= "" and ("\n" .. body) or ""),
          vim.log.levels.ERROR)
      end
    end),
  })
end

-- ── Backend 1: dotnet AL tool (`al publishapp`) ───────────────────────────────

-- Map launch.json authentication values to the CLI's accepted set.
local AUTH_MAP = {
  MicrosoftEntraID = "AAD", AAD = "AAD",
  UserPassword = "UserPassword", NavUserPassword = "UserPassword",
  Windows = "Windows",
}

-- Build `al publishapp` args from the picked launch configuration. Explicit
-- flags override launch.json so the user's config picker choice wins even
-- when launch.json has several configurations (the CLI would take the first).
local function publishapp_args(root, cfg)
  local a = { "publishapp", "--project", root }
  if cfg.schemaUpdateMode then
    vim.list_extend(a, { "--schemaupdatemode", cfg.schemaUpdateMode })
  end
  local auth = AUTH_MAP[cfg.authentication or ""]
  if auth then vim.list_extend(a, { "--authentication", auth }) end
  local tenant = cfg.primaryTenantDomain or cfg.tenant
  if tenant and tenant ~= "" and tenant ~= "default" then
    vim.list_extend(a, { "--tenant", tenant })
  end
  if conn.is_cloud(cfg) then
    if cfg.environmentName then vim.list_extend(a, { "--environmentname", cfg.environmentName }) end
    if cfg.environmentType then vim.list_extend(a, { "--environmenttype", cfg.environmentType }) end
  else
    if cfg.server         then vim.list_extend(a, { "--server", cfg.server }) end
    if cfg.serverInstance then vim.list_extend(a, { "--serverinstance", cfg.serverInstance }) end
    if cfg.port           then vim.list_extend(a, { "--port", tostring(cfg.port) }) end
  end
  return a
end

-- Streaming output float: publishapp may print interactive auth instructions
-- (browser/device login), so output must be visible live, not just on exit.
local function open_publish_float(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local w   = math.min(90, math.max(60, vim.o.columns - 8))
  local h   = math.min(16, math.max(8, math.floor(vim.o.lines * 0.35)))
  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = w,
    height    = h,
    row       = math.floor((vim.o.lines - h) / 2),
    col       = math.floor((vim.o.columns - w) / 2),
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[win].wrap = true
  vim.keymap.set("n", "q",     "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  local function log(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
  return buf, win, log
end

-- Publish via `al publishapp`, streaming output into a float.
local function publish_dotnet(root, cfg, on_success)
  local altool = require("al.altool")
  local cmd = { altool.binary() }
  vim.list_extend(cmd, publishapp_args(root, cfg))

  -- UserPassword: the CLI resolves credentials from BC_SERVER_USERNAME /
  -- BC_SERVER_PASSWORD env vars — feed it the same credentials ALNvim already
  -- resolves (launch.json fields → AL_BC_* env → session-cached prompt).
  local env
  local auth = cfg.authentication or ""
  if auth == "UserPassword" or auth == "NavUserPassword" then
    local user, pass = conn.user_password(cfg)
    if user and user ~= "" then
      env = { BC_SERVER_USERNAME = user, BC_SERVER_PASSWORD = pass or "" }
    end
  end

  require("al.status").set_publishing()
  local _buf, win, log = open_publish_float("AL: Publishing (al publishapp)")
  log({ "$ " .. table.concat(cmd, " "), "" })

  local function on_lines(_, data)
    local clean = {}
    for _, l in ipairs(data) do
      l = l:gsub("\r", "")
      if l ~= "" then clean[#clean + 1] = l end
    end
    if #clean > 0 then vim.schedule(function() log(clean) end) end
  end

  vim.fn.jobstart(cmd, {
    cwd  = root,
    env  = env,
    on_stdout = on_lines,
    on_stderr = on_lines,
    on_exit = vim.schedule_wrap(function(_, code)
      local ok = code == 0
      require("al.status").set_publish_result(ok)
      if ok then
        log({ "", "── Published successfully ──" })
        vim.notify("AL: Published successfully", vim.log.levels.INFO)
        -- Auto-close on success; keep open on failure so errors stay readable.
        vim.defer_fn(function()
          if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        end, 2500)
        if cfg.launchBrowser then
          local browser = require("al.cops").get_browser(root)
          require("al.platform").open_url(conn.webclient_url(cfg), browser)
        end
        if on_success then on_success() end
      else
        log({ "", "── Publish failed (exit " .. code .. ") ──" })
        vim.notify("AL: Publish failed (al publishapp exit " .. code .. ") — see float", vim.log.levels.ERROR)
      end
    end),
  })
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

  -- 1. Dotnet AL tool
  if require("al.altool").has("publishapp") then
    conn.pick_launch(root, function(cfg)
      local function go()
        local app_file = find_app_file(root, app)
        if not app_file then
          vim.notify("AL: No .app file found. Run :ALCompile first.", vim.log.levels.ERROR)
          return
        end
        publish_dotnet(root, cfg, on_success)
      end
      if skip_compile then go() else require("al.compile").compile(root, nil, go) end
    end)
    return
  end

  -- 2. DAP adapter (needs nvim-dap + the VSCode extension)
  if package.loaded["dap"] or pcall(require, "dap") then
    if require("al.ext").path then
      require("al.debug").publish_only(root)
      return
    end
  end

  -- 3. Direct HTTP (BC < 25 only)
  M.publish_http(root, skip_compile, on_success)
end

-- ── Backend 3: direct HTTP POST (BC < 25) ─────────────────────────────────────

-- @param root         Optional project root override.
-- @param skip_compile If true, skip compilation and upload whatever .app exists.
-- @param on_success   Optional callback invoked after a successful upload.
function M.publish_http(root, skip_compile, on_success)
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

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  local base   = conn.base_url(cfg)
  local tenant = cfg.tenant or "default"
  local schema = cfg.schemaUpdateMode or "synchronize"

  conn.get_auth(cfg, function(auth)
    if skip_compile then
      local app_file = find_app_file(root, app)
      if not app_file then
        vim.notify("AL: No .app file found. Run :ALCompile first.", vim.log.levels.ERROR)
        return
      end
      do_upload(root, base, tenant, schema, auth, app_file, cfg, on_success)
      return
    end

    -- Compile first; on success, upload the resulting .app
    require("al.compile").compile(root, nil, function()
      vim.schedule(function()
        local app_file = find_app_file(root, app)
        if not app_file then
          vim.notify("AL: Compile succeeded but no .app file found", vim.log.levels.ERROR)
          return
        end
        do_upload(root, base, tenant, schema, auth, app_file, cfg, on_success)
      end)
    end)
  end)
end

M.find_app = find_app_file

return M
