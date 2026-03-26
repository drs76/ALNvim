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

local function do_upload(base, tenant, schema, auth, app_file, cfg)
  local url = string.format("%s/dev/apps?tenant=%s&SchemaUpdateMode=%s",
    base, conn.urlencode(tenant), conn.urlencode(schema))

  local cmd = {
    "curl", "-sL", "--fail", "-X", "POST",
    "-H", "Content-Type: application/octet-stream",
    "--data-binary", "@" .. app_file,
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
    on_exit = vim.schedule_wrap(function(_, code)
      if code == 0 then
        vim.notify("AL: Published successfully", vim.log.levels.INFO)
        if cfg and cfg.launchBrowser then
          local obj_id   = cfg.startupObjectId or 22
          local obj_type = cfg.startupObjectType or "Page"
          local url_bc   = string.format(
            "%s/WebClient/?%s=%s&tenant=%s",
            base, obj_type, obj_id, conn.urlencode(tenant))
          vim.fn.jobstart({ "xdg-open", url_bc })
        end
      else
        local msg = table.concat(output, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        vim.notify(
          "AL: Publish failed (exit " .. code .. ")" .. (msg ~= "" and ("\n" .. msg) or ""),
          vim.log.levels.ERROR)
      end
    end),
  })
end

-- Compile then publish.
-- @param root         Optional project root override.
-- @param skip_compile If true, skip compilation and upload whatever .app exists.
function M.publish(root, skip_compile)
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
    do_upload(base, tenant, schema, auth, app_file, cfg)
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
      do_upload(base, tenant, schema, auth, app_file, cfg)
    end)
  end)
end

return M
