-- AL MCP Server integration for Claude Code.
--
-- Writes/updates ~/.claude/settings.json so Claude Code can spawn the
-- Microsoft AL Development Tools MCP server (dotnet tool `al`) for the
-- current project via stdio transport.
--
-- Each project gets its own named entry ("al:<projectName>") so switching
-- between projects just adds a new entry rather than overwriting the last one.
--
-- Usage:
--   require("al.mcp").configure(root)   -- add/update entry for root
--   require("al.mcp").deconfigure(root) -- remove entry for root
--   require("al.mcp").status()          -- return table of all al:* entries

local M = {}

local SETTINGS_PATH = vim.fn.expand("~/.claude/settings.json")
local AL_BINARY     = vim.fn.expand("~/.dotnet/tools/al")

-- Read ~/.claude/settings.json, returning a table (empty if missing/invalid).
local function read_settings()
  local ok, lines = pcall(vim.fn.readfile, SETTINGS_PATH)
  if not ok or not lines or #lines == 0 then return {} end
  local ok2, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok2 or type(data) ~= "table" then return {} end
  return data
end

-- Persist the settings table to disk.
local function write_settings(data)
  vim.fn.mkdir(vim.fn.fnamemodify(SETTINGS_PATH, ":h"), "p")
  vim.fn.writefile({ vim.fn.json_encode(data) }, SETTINGS_PATH)
end

-- Entry key for a project root, e.g. "al:HTest".
local function entry_key(root)
  return "al:" .. vim.fn.fnamemodify(root, ":t")
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
  if cfg.ruleset_path and cfg.ruleset_path ~= "" then
    vim.list_extend(args, { "--ruleset", cfg.ruleset_path })
  end
  -- Project root is the final positional argument.
  args[#args + 1] = root
  return args
end

-- Add or update the MCP server entry for the given project root.
-- Returns true on success, false on error.
function M.configure(root)
  if not root then
    vim.notify("AL MCP: no project root provided", vim.log.levels.WARN)
    return false
  end

  if vim.fn.executable(AL_BINARY) == 0 then
    vim.notify(
      "AL MCP: al binary not found at " .. AL_BINARY .. "\n"
      .. "Install with: dotnet tool install "
      .. "Microsoft.Dynamics.BusinessCentral.Development.Tools --prerelease --global",
      vim.log.levels.ERROR)
    return false
  end

  local settings = read_settings()
  if type(settings.mcpServers) ~= "table" then
    settings.mcpServers = {}
  end

  local key = entry_key(root)
  settings.mcpServers[key] = {
    command = AL_BINARY,
    args    = build_args(root),
  }

  write_settings(settings)
  vim.notify("AL MCP: configured '" .. key .. "' — restart Claude Code or run /mcp to activate.",
    vim.log.levels.INFO)
  return true
end

-- Remove the MCP server entry for the given project root.
function M.deconfigure(root)
  if not root then
    vim.notify("AL MCP: no project root provided", vim.log.levels.WARN)
    return
  end

  local settings = read_settings()
  if type(settings.mcpServers) ~= "table" then
    vim.notify("AL MCP: no mcpServers entries found", vim.log.levels.WARN)
    return
  end

  local key = entry_key(root)
  if not settings.mcpServers[key] then
    vim.notify("AL MCP: no entry found for '" .. key .. "'", vim.log.levels.WARN)
    return
  end

  settings.mcpServers[key] = nil
  write_settings(settings)
  vim.notify("AL MCP: removed '" .. key .. "'", vim.log.levels.INFO)
end

-- Open an Ollama chat session in a terminal buffer with the AL MCP server wired in.
-- Requires mcphost (github.com/mark3labs/mcphost) on PATH or via config.ollama_binary.
-- Writes a temp config file so mcphost can spawn the AL MCP server for this project.
function M.launch_ollama(root)
  if not root then
    vim.notify("AL Ollama: no project root", vim.log.levels.WARN)
    return
  end

  local cfg    = require("al").config
  local mcpbin = cfg.ollama_binary or "mcphost"
  if vim.fn.executable(mcpbin) == 0 then
    vim.notify(
      "AL Ollama: '" .. mcpbin .. "' not found.\n"
        .. "Install: go install github.com/mark3labs/mcphost@latest",
      vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable(AL_BINARY) == 0 then
    vim.notify(
      "AL Ollama: al binary not found at " .. AL_BINARY .. "\n"
        .. "Install with :ALInstallDotnetTool",
      vim.log.levels.ERROR)
    return
  end

  local model = cfg.ollama_model or "qwen2.5-coder:32b"
  local host  = cfg.ollama_host  or "http://localhost:11434"

  -- Write a temp config file in the same mcpServers format as ~/.claude/settings.json.
  local tmp_cfg = vim.fn.tempname() .. ".json"
  vim.fn.writefile({
    vim.fn.json_encode({
      mcpServers = {
        [entry_key(root)] = {
          command = AL_BINARY,
          args    = build_args(root),
        },
      },
    }),
  }, tmp_cfg)

  -- Open a 15-line horizontal split at the bottom for the chat session.
  vim.cmd("botright 15new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf,
    "AL: Ollama Chat (" .. vim.fn.fnamemodify(root, ":t") .. ")")

  vim.fn.termopen({
    mcpbin,
    "--model",  "ollama:" .. model,
    "--config", tmp_cfg,
  }, {
    env     = { OLLAMA_HOST = host },
    on_exit = function() pcall(os.remove, tmp_cfg) end,
  })
  vim.cmd("startinsert")
end

-- Return a table of all "al:*" MCP entries currently in settings.json.
function M.status()
  local settings = read_settings()
  local servers  = settings.mcpServers or {}
  local entries  = {}
  for k, v in pairs(servers) do
    if k:match("^al:") then
      entries[#entries + 1] = { key = k, command = v.command, args = v.args }
    end
  end
  return entries
end

return M
