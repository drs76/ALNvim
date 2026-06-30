-- In-editor AI agents: open Claude Code or Pi in a terminal split at the AL
-- project root, so the agent's tools (read/write/edit/bash, al-mcp, AGENTS.md)
-- operate on the current project. Replaces the old mcphost "Ollama chat" idea.

local M = {}

-- Open `cmd` (list) in a terminal split rooted at the project (dir with app.json).
-- `env` (optional table) is added on top of the inherited environment.
local function open_term(cmd, title, env)
  if type(cmd) ~= "table" or not cmd[1] then
    vim.notify("AL agent: no command configured", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable(cmd[1]) == 0 then
    vim.notify(
      ("AL agent: '%s' not found in PATH. Install it first."):format(cmd[1]),
      vim.log.levels.ERROR)
    return
  end
  local root = require("al.lsp").get_root(0) or vim.fn.getcwd()
  vim.cmd("botright vsplit")
  vim.cmd("enew")
  vim.fn.jobstart(cmd, { term = true, cwd = root, env = env })  -- nvim 0.11 terminal
  vim.b.term_title = title or cmd[1]
  vim.cmd("startinsert")
end

-- Claude Code (Pro-sub quota; uses ~/.claude/settings.json al-mcp registered by al.mcp).
function M.claude()
  open_term(require("al").config.agent.claude_cmd, "Claude Code")
end

-- Pi (local ollama via the LAN HTTPS proxy, or any provider; free).
function M.pi()
  local a = require("al").config.agent
  local cmd = a.pi_cmd
  if not cmd then
    cmd = { "pi", "-e", vim.fn.expand(a.pi_provider), "--model", a.pi_model }
  end
  -- TLS / other env is user-supplied via agent.pi_env (see docs/pi-setup.md).
  local env = (a.pi_env and next(a.pi_env)) and a.pi_env or nil
  open_term(cmd, "Pi", env)
end

return M
