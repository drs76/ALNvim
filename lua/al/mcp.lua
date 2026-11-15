-- AL MCP Server integration for Claude Code.
--
-- Writes <project>/.claude/settings.json so Claude Code can spawn the Microsoft
-- AL Development Tools MCP server (dotnet tool `al`) for that project over stdio.
--
-- PER-PROJECT, deliberately. This used to write the *global*
-- ~/.claude/settings.json, and with auto_mcp on by default every AL project ever
-- opened left an entry behind there. Two things went wrong with that:
--
--   * The entries accumulate and outlive the projects. Eleven had built up,
--     including one for a dead scratch directory under /tmp.
--   * The server's last positional argument is its *workspace root*, so a bad
--     root is not inert — it is an AL language server indexing that tree in
--     every Claude Code session, globally. One entry ("al:rojaws") pointed at a
--     3.6TB NFS share because a stray app.json above the projects made
--     get_root() resolve the mount point. lsp.find_root_upward now bounds that
--     resolution, but the blast radius only shrinks if the entry is scoped to
--     the project too.
--
-- Writing next to the project keeps each server's lifetime tied to the checkout
-- it describes, and matches the layout already in use by hand
-- (<project>/.claude/settings.json holding a single "al:<name>" entry).
--
-- Usage:
--   require("al.mcp").configure(root)   -- add/update entry in <root>/.claude
--   require("al.mcp").deconfigure(root) -- remove it
--   require("al.mcp").status(root)      -- entries for root + stale global ones

local M = {}

local GLOBAL_SETTINGS = vim.fn.expand("~/.claude/settings.json")

-- Go through altool so there is one resolver for this path. This module had its
-- own copy that omitted the .exe suffix, so on Windows `executable()` was always
-- 0 and :ALMcpSetup reported "al binary not found" no matter what was installed
-- — MCP could never be configured there at all.
local function al_binary()
  return require("al.altool").binary()
end

-- Claude Code reads MCP servers from <project>/.claude/settings.json.
local function settings_path(root)
  return root .. "/.claude/settings.json"
end

-- Read a settings file. Returns (data, err):
--   {},   nil  — file absent or empty; safe to create
--   data, nil  — parsed successfully
--   nil,  err  — file exists but could not be parsed
--
-- The third case must never be flattened into the first. It used to be: both
-- returned {}, so a settings.json with a single trailing comma — an ordinary
-- hand-edit slip — was treated as empty and then overwritten with a table
-- holding only mcpServers, silently destroying the user's permissions, hooks
-- and env. auto_mcp calls configure() on every AL LspAttach, so opening one
-- .al file was enough to lose the file.
local function read_settings(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return {} end
  local ok2, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok2 or type(data) ~= "table" then
    return nil, "not valid JSON"
  end
  return data
end

-- Persist a settings table as indented JSON.
-- The file is user-owned and hand-edited, and auto_mcp reaches this path on
-- every AL LspAttach, so json_encode's single-line output would flatten the
-- user's formatting each time a project is opened.
local function write_settings(path, data)
  local ok, err = require("al.json").write(path, data)
  if not ok then
    vim.notify("AL MCP: could not write " .. path .. ": " .. tostring(err),
      vim.log.levels.ERROR)
  end
  return ok
end

-- Entry key for a project root, e.g. "al:HTest".
local function entry_key(root)
  return "al:" .. vim.fn.fnamemodify(root, ":t")
end

-- The two MCP proxies the tool ships from 30.x, keyed by the config flag that
-- opts each in (setup({ mcp = { profiling = true, snapshot = true } })).
local PROXIES = {
  { kind = "profiling", subcommand = "launchprofilingmcpproxy", prefix = "al-profiling:" },
  { kind = "snapshot",  subcommand = "launchsnapshotmcpproxy",  prefix = "al-snapshot:" },
}

-- Every key this module may own for `root`: al:, al-profiling:, al-snapshot:.
local function all_keys(root)
  local name = vim.fn.fnamemodify(root, ":t")
  local keys = { entry_key(root) }
  for _, p in ipairs(PROXIES) do keys[#keys + 1] = p.prefix .. name end
  return keys
end

local function is_own_key(k)
  return k:match("^al:") or k:match("^al%-profiling:") or k:match("^al%-snapshot:")
end

-- Args for a proxy entry: the subcommand plus connection flags from a launch
-- configuration on the *MCP service* port (altool.mcp_port — the API/OData
-- port, 7047 by default, never the dev port 7049 the other commands use).
-- Profiling also gets its artifact folder inside the project, so Claude's
-- captures land where :ALProfileOpen looks.
local function proxy_args(kind, root, launch_cfg)
  local altool = require("al.altool")
  local proxy
  for _, p in ipairs(PROXIES) do if p.kind == kind then proxy = p end end
  local args = { proxy.subcommand }
  vim.list_extend(args, altool.connection_flags(launch_cfg, { port = "mcp" }))
  if kind == "profiling" then
    vim.list_extend(args, { "--profilefolder", root .. "/.profiles" })
  end
  return args
end

-- Environment block for a proxy entry. UserPassword proxies read
-- BC_SERVER_USERNAME / BC_SERVER_PASSWORD; the entry references the AL_BC_*
-- variables ALNvim already honours (Claude Code expands ${VAR} in MCP server
-- env) rather than copying a password out of launch.json into another file.
local function proxy_env(launch_cfg)
  local auth = launch_cfg.authentication or ""
  if auth == "UserPassword" or auth == "NavUserPassword" then
    return { BC_SERVER_USERNAME = "${AL_BC_USERNAME}", BC_SERVER_PASSWORD = "${AL_BC_PASSWORD}" }
  end
  return nil
end

-- The proxy entries configure() should write for `root`: only those opted in,
-- only when the installed tool has the subcommand, and only with a launch
-- configuration to point them at. Returns { [key] = entry }.
local function proxy_entries(root)
  local cfg    = require("al").config
  local altool = require("al.altool")
  local out    = {}
  local opt    = type(cfg.mcp) == "table" and cfg.mcp or {}
  local launch = require("al.connection").read_launch(root)
  if not launch then return out end
  local name = vim.fn.fnamemodify(root, ":t")
  for _, p in ipairs(PROXIES) do
    if opt[p.kind] and altool.has(p.subcommand) then
      out[p.prefix .. name] = {
        command = al_binary(),
        args    = proxy_args(p.kind, root, launch),
        env     = proxy_env(launch),
      }
    end
  end
  return out
end

-- Build the args array for the MCP server process.
local function build_args(root)
  local cfg   = require("al").config
  local args  = {
    "launchmcpserver",
    "--transport", "stdio",
    "--disableTelemetry",
    "--packagecachepath", root .. "/" .. (cfg.packagecachepath or ".alpackages"),
  }
  for _, dir in ipairs(require("al.lsp").assembly_probing_paths(root)) do
    vim.list_extend(args, { "--assemblyprobingpath", dir })
  end
  if cfg.ruleset_path and cfg.ruleset_path ~= "" then
    vim.list_extend(args, { "--ruleset", cfg.ruleset_path })
  end
  -- Project root is the final positional argument.
  args[#args + 1] = root
  return args
end

-- Add or update the MCP server entry for the given project root.
-- Writes <root>/.claude/settings.json. Returns true on success, false on error.
function M.configure(root)
  if not root then
    vim.notify("AL MCP: no project root provided", vim.log.levels.WARN)
    return false
  end

  if vim.fn.executable(al_binary()) == 0 then
    vim.notify(
      "AL MCP: al binary not found at " .. al_binary() .. "\n"
      .. "Install with: dotnet tool install "
      .. "Microsoft.Dynamics.BusinessCentral.Development.Tools --prerelease --global",
      vim.log.levels.ERROR)
    return false
  end

  local path           = settings_path(root)
  local settings, err  = read_settings(path)
  if not settings then
    -- Refuse rather than clobber: this is the user's file and we cannot merge
    -- into something we could not read.
    vim.notify("AL MCP: " .. vim.fn.fnamemodify(path, ":~:.") .. " is " .. err
      .. " — not modifying it. Fix the file, then run :ALMcpSetup.",
      vim.log.levels.ERROR)
    return false
  end
  if type(settings.mcpServers) ~= "table" then
    settings.mcpServers = {}
  end

  local wanted = proxy_entries(root)
  wanted[entry_key(root)] = { command = al_binary(), args = build_args(root) }

  -- auto_mcp calls this on every LspAttach. Skip the write (and the notify) when
  -- every entry is already correct, so simply opening an AL file does not
  -- rewrite the user's settings file or spam the message area. Entries for a
  -- proxy that is opted out are left alone, not removed — :ALMcpRemove does that.
  local changed = {}
  for key, entry in pairs(wanted) do
    if not vim.deep_equal(settings.mcpServers[key], entry) then
      settings.mcpServers[key] = entry
      changed[#changed + 1] = key
    end
  end
  if #changed == 0 then return true end
  table.sort(changed)

  if not write_settings(path, settings) then return false end
  vim.notify("AL MCP: configured '" .. table.concat(changed, "', '") .. "' in "
    .. vim.fn.fnamemodify(path, ":~:.")
    .. " — restart Claude Code or run /mcp to activate.", vim.log.levels.INFO)
  return true
end

-- Remove the MCP server entry for the given project root.
function M.deconfigure(root)
  if not root then
    vim.notify("AL MCP: no project root provided", vim.log.levels.WARN)
    return
  end

  local path          = settings_path(root)
  local settings, err = read_settings(path)
  if not settings then
    vim.notify("AL MCP: " .. vim.fn.fnamemodify(path, ":~:.") .. " is " .. err
      .. " — not modifying it.", vim.log.levels.ERROR)
    return
  end
  -- Remove every entry this module may have written: the project server and
  -- both proxies, whether or not they are currently opted in.
  local removed = {}
  for _, key in ipairs(all_keys(root)) do
    if type(settings.mcpServers) == "table" and settings.mcpServers[key] then
      settings.mcpServers[key] = nil
      removed[#removed + 1] = key
    end
  end
  if #removed == 0 then
    vim.notify("AL MCP: no entry for '" .. entry_key(root) .. "' in "
      .. vim.fn.fnamemodify(path, ":~:."), vim.log.levels.WARN)
    return
  end
  -- Drop the container when it empties, rather than leaving "mcpServers": {}.
  if vim.tbl_isempty(settings.mcpServers) then settings.mcpServers = nil end
  if vim.tbl_isempty(settings) then
    -- Nothing else in the file: remove it instead of leaving an empty object.
    pcall(vim.uv.fs_unlink, path)
  else
    write_settings(path, settings)
  end
  vim.notify("AL MCP: removed '" .. table.concat(removed, "', '") .. "'", vim.log.levels.INFO)
end

-- Report the al:* / al-profiling:* / al-snapshot:* entries for `root`, plus any left in the GLOBAL settings file.
--
-- The global list matters: entries written there by older versions of this
-- module keep starting an AL language server in every Claude Code session, for
-- projects that may no longer exist. They are reported so :ALMcpStatus can
-- point at them; nothing is removed automatically, since the file is shared
-- with the user's own configuration.
--
-- Returns (project_entries, global_entries), each { key, command, args, path }.
function M.status(root)
  local function collect(path)
    local out = {}
    -- Read-only: an unparseable file just reports nothing rather than erroring.
    for k, v in pairs((read_settings(path) or {}).mcpServers or {}) do
      if is_own_key(k) then
        out[#out + 1] = { key = k, command = v.command, args = v.args, path = path }
      end
    end
    -- al:<name> first, then its proxies ('-' sorts before ':' otherwise).
    local function rank(k) return (k:gsub("^al:", "al!:")) end
    table.sort(out, function(a, b) return rank(a.key) < rank(b.key) end)
    return out
  end
  local project = root and collect(settings_path(root)) or {}
  return project, collect(GLOBAL_SETTINGS)
end

M._test = { build_args = build_args, proxy_args = proxy_args, proxy_env = proxy_env,
            proxy_entries = proxy_entries, all_keys = all_keys }

return M
