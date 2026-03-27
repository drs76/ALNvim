-- Compile the AL project then upload the resulting .app to Business Central.
--
-- Publish endpoint (on-prem):
--   POST <base>/dev/apps?tenant=<t>&SchemaUpdateMode=<mode>
--   Content-Type: application/octet-stream
--   Body: raw bytes of the compiled .app file
--
-- After a successful upload the BC client URL is opened in the browser when
-- launchBrowser = true in launch.json.

local M    = {}
local conn  = require("al.connection")
local lsp   = require("al.lsp")

-- Find the compiled .app in the project root.
-- Tries the standard Publisher_Name_Version.app name first, then globs.
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

local function do_upload(base, tenant, schema, auth, app_file, cfg, on_success)
  local url = string.format("%s/dev/apps?tenant=%s&SchemaUpdateMode=%s",
    base, conn.urlencode(tenant), conn.urlencode(schema))

  -- Drop --fail so the BC error response body is captured; use -w to append the
  -- HTTP status as a sentinel line we can parse regardless of exit code.
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

      if status >= 200 and status < 300 then
        vim.notify("AL: Published successfully", vim.log.levels.INFO)
        if cfg and cfg.launchBrowser then
          vim.fn.jobstart({ "xdg-open", conn.webclient_url(cfg) })
        end
        if on_success then on_success() end
      else
        vim.notify(
          string.format("AL: Publish failed (HTTP %s)%s",
            http_status, body ~= "" and ("\n" .. body) or ""),
          vim.log.levels.ERROR)
      end
    end),
  })
end

-- Compile then publish.
-- @param root         Optional project root override.
-- @param skip_compile If true, skip compilation and upload whatever .app exists.
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

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  local base   = conn.base_url(cfg)
  local tenant = cfg.tenant or "default"
  local schema = cfg.schemaUpdateMode or "synchronize"
  local auth   = conn.curl_auth(cfg)

  if skip_compile then
    local app_file = find_app_file(root, app)
    if not app_file then
      vim.notify("AL: No .app file found. Run :ALCompile first.", vim.log.levels.ERROR)
      return
    end
    do_upload(base, tenant, schema, auth, app_file, cfg, on_success)
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
      do_upload(base, tenant, schema, auth, app_file, cfg, on_success)
    end)
  end)
end

return M
