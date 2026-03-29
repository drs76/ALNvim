-- Shared Business Central connection utilities.
-- Reads .vscode/launch.json for server, auth, and tenant configuration.
-- Used by symbols.lua, publish.lua, and debug.lua.

local M = {}

-- In-memory credential cache: keyed by base_url .. "|" .. auth_type.
-- UserPassword entries store { "-u", "user:pass" }.
-- Entra manual-entry entries store the raw token string.
-- Clear with M.clear_credentials() or :ALClearCredentials.
local _cache = {}

-- Strip JSONC-style single-line comments (// ...) while preserving URLs (http://).
-- Does not handle /* */ block comments or // inside strings, but is sufficient
-- for standard launch.json content.
local function strip_jsonc(text)
  local out = {}
  for line in text:gmatch("[^\n]*") do
    -- Only strip if // is not preceded by : or another /  (i.e. not in a URL)
    line = line:gsub("([^:/])//[^\n]*$", "%1")
    table.insert(out, line)
  end
  return table.concat(out, "\n")
end

-- Read all AL launch configurations from .vscode/launch.json.
-- Returns a list (possibly empty) of configurations with type="al".
function M.read_launches(root)
  if not root then return {} end
  local path = root .. "/.vscode/launch.json"
  local f    = io.open(path, "r")
  if not f then return {} end
  local raw  = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, strip_jsonc(raw))
  if not ok or type(data) ~= "table" then return {} end
  local out = {}
  for _, cfg in ipairs(data.configurations or {}) do
    if cfg.type == "al" then out[#out + 1] = cfg end
  end
  return out
end

-- Read .vscode/launch.json and return the first configuration with type = "al".
-- Returns nil if the file is missing or cannot be parsed.
function M.read_launch(root)
  local list = M.read_launches(root)
  return list[1]
end

-- Present a picker when multiple AL configs exist, then call cb(cfg).
-- If only one config exists, calls cb immediately without a picker.
function M.pick_launch(root, cb)
  local list = M.read_launches(root)
  if #list == 0 then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end
  if #list == 1 then cb(list[1]); return end
  local names = {}
  for _, cfg in ipairs(list) do names[#names + 1] = cfg.name or "(unnamed)" end
  vim.ui.select(names, { prompt = "AL: Select launch configuration" }, function(_, idx)
    if idx then cb(list[idx]) end
  end)
end

-- Return userName and password strings for UserPassword/NavUserPassword auth.
-- Uses the same credential resolution and caching as curl_auth.
-- Returns nil, nil for other auth types.
function M.user_password(cfg)
  local auth = cfg.authentication or (M.is_cloud(cfg) and "MicrosoftEntraID" or "Windows")
  if auth ~= "UserPassword" and auth ~= "NavUserPassword" then return nil, nil end
  local args = M.curl_auth(cfg)   -- resolves & caches; returns {"-u","user:pass"}
  if type(args) == "table" and args[1] == "-u" then
    local cred = args[2] or ""
    local u    = cred:match("^([^:]*)")
    local p    = cred:match("^[^:]*:(.*)")
    return u, p
  end
  return nil, nil
end

-- URL-encode a string (RFC 3986).
function M.urlencode(s)
  s = tostring(s or "")
  return (s:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Return the BC dev API base URL derived from a launch configuration.
--   On-prem  → http[s]://<server>:<port>/<serverInstance>
--   Cloud    → https://api.businesscentral.dynamics.com/v2.0/<tenant>/<environment>
--
-- Cloud vs on-prem detection:
--   A non-empty cfg.server that does not contain a Microsoft cloud domain always
--   means on-prem — even when environmentType is "Sandbox" or "Production".
--   This allows BCContainer launch.json to keep environmentType without breaking
--   VSCode compatibility (VSCode reads environmentType; ALNvim looks at server first).
--
-- Port resolution for on-prem (dev endpoint, not Web Client):
--   1. cfg.port field in launch.json  (e.g. "port": 7049)
--   2. Port already present in cfg.server  (e.g. "server": "http://bc27:7049")
--   3. Default: 7049  (BC NST dev service port — BCContainer and standard NST)
function M.is_cloud(cfg)
  -- UserPassword / NavUserPassword is never used on BC cloud — cloud always requires
  -- MicrosoftEntraID. Seeing either auth type is an absolute on-prem indicator and
  -- takes precedence over environmentType (BCContainerHelper sets environmentType=Sandbox
  -- even for local containers).
  local auth = cfg.authentication or ""
  if auth == "UserPassword" or auth == "NavUserPassword" then return false end

  local cloud_type = cfg.environmentType == "Sandbox" or cfg.environmentType == "Production"
  if not cloud_type then return false end
  -- If a server is explicitly set and points to a non-Microsoft host, treat as on-prem.
  local srv = cfg.server or ""
  if srv ~= "" and not srv:match("microsoft%.com") and not srv:match("dynamics%.com") then
    return false
  end
  return true
end

function M.base_url(cfg)
  if M.is_cloud(cfg) then
    local tenant = cfg.primaryTenantDomain or cfg.tenant or ""
    local env    = cfg.environmentName or "sandbox"
    return string.format("https://api.businesscentral.dynamics.com/v2.0/%s/%s",
      M.urlencode(tenant), M.urlencode(env))
  end
  local server   = (cfg.server or "http://localhost"):gsub("/*$", "")
  -- Append port if not already in the server URL.
  -- BC dev endpoint (symbols, publish, debug) always uses the NST service port,
  -- not the Web Client port. BCContainer default is 7049.
  if not server:match(":%d+$") then
    local port = cfg.port or 7049
    server = server .. ":" .. tostring(port)
  end
  local instance = cfg.serverInstance or "BC"
  return server .. "/" .. instance
end

-- Return the BC WebClient URL for a launch configuration.
--   Cloud    → https://businesscentral.dynamics.com/<tenant>/<env>
--   On-prem  → http[s]://<server>/<serverInstance>/WebClient/?<ObjType>=<ObjId>&tenant=<tenant>
-- Note: WebClient runs on the HTTP port (80/443), not the NST dev port (7049).
-- The server field is used as-is — no port is appended here.
function M.webclient_url(cfg)
  if M.is_cloud(cfg) then
    local tenant = M.urlencode(cfg.primaryTenantDomain or cfg.tenant or "")
    local env    = M.urlencode(cfg.environmentName or "sandbox")
    return string.format("https://businesscentral.dynamics.com/%s/%s", tenant, env)
  end
  local server   = (cfg.server or "http://localhost"):gsub("/*$", "")
  local instance = cfg.serverInstance or "BC"
  local tenant   = cfg.tenant or "default"
  local obj_type = cfg.startupObjectType or "Page"
  local obj_id   = cfg.startupObjectId or 22
  return string.format("%s/%s/WebClient/?%s=%s&tenant=%s",
    server, instance, obj_type, obj_id, M.urlencode(tenant))
end

-- Clear the in-memory credential cache (all entries or a specific base URL).
function M.clear_credentials()
  _cache = {}
  vim.notify("AL: Credential cache cleared", vim.log.levels.INFO)
end

-- Return a list of curl arguments that handle authentication.
-- Credential resolution order:
--   UserPassword  : 1. launch.json al_username/al_password  2. env vars  3. prompt (cached per session)
--   MicrosoftEntraID / AAD:
--                   1. AL_BC_TOKEN env var
--                   2. Azure CLI  `az account get-access-token` (handles its own refresh)
--                   3. Manual prompt (cached per session)
function M.curl_auth(cfg)
  -- Cloud environments always use Entra ID even when the field is absent (matches VSCode behaviour)
  local auth = cfg.authentication or (M.is_cloud(cfg) and "MicrosoftEntraID" or "Windows")
  local key  = M.base_url(cfg) .. "|" .. auth

  if auth == "Windows" then
    return { "--ntlm", "--negotiate", "-u", ":" }

  elseif auth == "UserPassword" or auth == "NavUserPassword" then
    if not _cache[key] then
      -- Resolution order:
      --   1. Standard BCContainer fields: userName / password  (generated by New-BCContainer)
      --   2. ALNvim custom fields:        al_username / al_password  (manually added to launch.json)
      --   3. Environment variables:       AL_BC_USERNAME / AL_BC_PASSWORD
      --   4. Interactive prompt
      local user = cfg.userName
        or cfg.al_username
        or (os.getenv("AL_BC_USERNAME") ~= "" and os.getenv("AL_BC_USERNAME"))
        or vim.fn.input("BC Username: ")
      local pass = cfg.password
        or cfg.al_password
        or (os.getenv("AL_BC_PASSWORD") ~= "" and os.getenv("AL_BC_PASSWORD"))
        or vim.fn.inputsecret("BC Password: ")
      _cache[key] = { "-u", user .. ":" .. pass }
    end
    return _cache[key]

  elseif auth == "AAD" or auth == "MicrosoftEntraID" then
    -- Env var always wins (not cached — caller controls it)
    local token = os.getenv("AL_BC_TOKEN")
    if token and token ~= "" then
      return { "-H", "Authorization: Bearer " .. token }
    end
    -- Azure CLI: manages its own token cache and handles refresh transparently
    local az = vim.trim(vim.fn.system(
      "az account get-access-token" ..
      " --resource https://api.businesscentral.dynamics.com" ..
      " --query accessToken -o tsv " .. require("al.platform").devnull()))
    if vim.v.shell_error == 0 and az ~= "" then
      return { "-H", "Authorization: Bearer " .. az }
    end
    -- Fall back to manual prompt, cached for the session
    if not _cache[key] then
      vim.notify("AL: Azure CLI not available or not logged in. Enter token manually.", vim.log.levels.WARN)
      _cache[key] = vim.fn.inputsecret("Bearer token (Entra ID): ")
    end
    return { "-H", "Authorization: Bearer " .. _cache[key] }
  end

  return {}
end

return M
