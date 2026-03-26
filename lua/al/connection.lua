-- Shared Business Central connection utilities.
-- Reads .vscode/launch.json for server, auth, and tenant configuration.
-- Used by symbols.lua, publish.lua, and debug.lua.

local M = {}

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

-- Read .vscode/launch.json and return the first configuration with type = "al".
-- Returns nil if the file is missing or cannot be parsed.
function M.read_launch(root)
  if not root then return nil end
  local path = root .. "/.vscode/launch.json"
  local f    = io.open(path, "r")
  if not f then return nil end
  local raw  = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, strip_jsonc(raw))
  if not ok or type(data) ~= "table" then return nil end
  for _, cfg in ipairs(data.configurations or {}) do
    if cfg.type == "al" then return cfg end
  end
  return nil
end

-- URL-encode a string (RFC 3986).
function M.urlencode(s)
  s = tostring(s or "")
  return (s:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Return the BC dev API base URL derived from a launch configuration.
--   On-prem  → http[s]://<server>/<serverInstance>
--   Cloud    → https://api.businesscentral.dynamics.com/v2.0/<tenant>/<environment>
function M.base_url(cfg)
  if cfg.environmentType == "Sandbox" or cfg.environmentType == "Production" then
    local tenant = cfg.primaryTenantDomain or cfg.tenant or ""
    local env    = cfg.environmentName or "sandbox"
    return string.format("https://api.businesscentral.dynamics.com/v2.0/%s/%s",
      M.urlencode(tenant), M.urlencode(env))
  end
  local server   = (cfg.server or "http://localhost"):gsub("/*$", "")
  local instance = cfg.serverInstance or "BC"
  return server .. "/" .. instance
end

-- Prompt for a credential, trying env-var then interactive prompt.
local function get_cred(env_key, prompt_label)
  local val = os.getenv(env_key)
  if val and val ~= "" then return val end
  return vim.fn.input(prompt_label .. ": ")
end

local function get_secret(env_key, prompt_label)
  local val = os.getenv(env_key)
  if val and val ~= "" then return val end
  return vim.fn.inputsecret(prompt_label .. ": ")
end

-- Return a list of curl arguments that handle authentication.
-- Credential resolution order:
--   1. launch.json  al_username / al_password  (non-standard, user-added)
--   2. env vars     AL_BC_USERNAME / AL_BC_PASSWORD
--   3. interactive  vim.fn.input / vim.fn.inputsecret
function M.curl_auth(cfg)
  local auth = cfg.authentication or "Windows"

  if auth == "Windows" then
    -- Use current user's Kerberos/NTLM ticket when possible
    return { "--ntlm", "--negotiate", "-u", ":" }

  elseif auth == "UserPassword" or auth == "NavUserPassword" then
    local user = cfg.al_username or get_cred("AL_BC_USERNAME", "BC Username")
    local pass = cfg.al_password or get_secret("AL_BC_PASSWORD", "BC Password")
    return { "-u", user .. ":" .. pass }

  elseif auth == "AAD" or auth == "MicrosoftEntraID" then
    vim.notify(
      "AL: AAD/Entra auth requires a bearer token. Set AL_BC_TOKEN env var.",
      vim.log.levels.WARN)
    local token = os.getenv("AL_BC_TOKEN") or vim.fn.inputsecret("Bearer token: ")
    return { "-H", "Authorization: Bearer " .. token }
  end

  return {}
end

return M
