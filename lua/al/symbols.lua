-- Download AL symbol packages (.app files) from the Business Central dev endpoint
-- into the project's .alpackages/ directory.
--
-- Each entry in app.json "dependencies" maps to one GET request:
--   <base>/dev/packages?publisher=<p>&appName=<n>&versionText=<v>&tenant=<t>
--
-- All downloads run in parallel via vim.fn.jobstart.

local M   = {}
local conn = require("al.connection")
local lsp  = require("al.lsp")

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

function M.download(root)
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

  -- Always include the implicit Microsoft base packages derived from app.json
  -- "application" version, unless already listed as an explicit dependency.
  local deps = {}
  local base_pkgs = {
    { publisher = "Microsoft", name = "Application",        version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "System Application", version = app.application or "0.0.0.0" },
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
  local tenant = cfg.tenant or "default"
  local auth   = conn.curl_auth(cfg)

  vim.notify(
    string.format("AL: Downloading %d symbol package(s) from %s…", #deps, base),
    vim.log.levels.INFO)

  local pending = #deps
  local failed  = {}

  for _, dep in ipairs(deps) do
    local url     = packages_url(base, dep, tenant)
    local outfile = string.format("%s/%s_%s_%s.app",
      pkgdir, safe_name(dep.publisher), safe_name(dep.name), dep.version or "0.0.0.0")
    local label   = (dep.publisher or "") .. "_" .. (dep.name or "")

    local cmd = { "curl", "-sL", "--fail" }
    vim.list_extend(cmd, auth)
    vim.list_extend(cmd, { "-o", outfile, url })

    vim.fn.jobstart(cmd, {
      on_exit = vim.schedule_wrap(function(_, code)
        pending = pending - 1
        if code ~= 0 then
          table.insert(failed, label)
          -- Remove the empty / partial file that curl may have created
          pcall(vim.uv.fs_unlink, outfile)
        end
        if pending == 0 then
          if #failed == 0 then
            vim.notify("AL: All symbol packages downloaded successfully", vim.log.levels.INFO)
          else
            vim.notify(
              "AL: Failed to download: " .. table.concat(failed, ", ") ..
              "\nCheck server URL, credentials, and that the package exists on that BC instance.",
              vim.log.levels.WARN)
          end
        end
      end),
    })
  end
end

return M
