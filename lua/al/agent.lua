-- In-editor AI agents: open Claude Code or Pi in a terminal split at the AL
-- project root, so the agent's tools (read/write/edit/bash, al-mcp, AGENTS.md)
-- operate on the current project. Replaces the old mcphost "Ollama chat" idea.

local M = {}

-- One terminal per (command, project root): { buf, win, job }. A second
-- :ALClaude used to add another split and another agent every time.
M._terms = {}

local function job_running(job)
  return job and job > 0 and vim.fn.jobwait({ job }, 0)[1] == -1
end

-- Show `buf` in a new window: a float under Catnip (host.float_for), else the
-- `botright vsplit` it always was.
local function show(buf, title)
  local win = require("al.host").float_for(buf, title)
  if not win then
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  return win
end

-- Open `cmd` (list) in a terminal at the project root (dir with app.json), or
-- bring back the one already running for this command and project. Closing
-- the window never stops the agent (bufhidden=hide).
-- `env` (optional table) is added on top of the inherited environment.
local function open_term(cmd, title, env)
  if type(cmd) ~= "table" or not cmd[1] then
    vim.notify("AL agent: no command configured", vim.log.levels.ERROR)
    return
  end
  local root = require("al.lsp").get_root(0) or vim.fn.getcwd()
  local key  = cmd[1] .. "\0" .. root
  local t    = M._terms[key]
  if t and vim.api.nvim_buf_is_valid(t.buf) and job_running(t.job) then
    local here = t.win and vim.api.nvim_win_is_valid(t.win)
      and vim.api.nvim_win_get_buf(t.win) == t.buf
      and vim.api.nvim_win_get_tabpage(t.win) == vim.api.nvim_get_current_tabpage()
    if not here then
      -- Hidden, or open in another tab (focusing it there would switch tab).
      if t.win and vim.api.nvim_win_is_valid(t.win) and vim.api.nvim_win_get_buf(t.win) == t.buf then
        pcall(vim.api.nvim_win_close, t.win, true)
      end
      t.win = show(t.buf, title or cmd[1])
    end
    vim.api.nvim_set_current_win(t.win)
    vim.cmd("startinsert")
    return t.buf
  end

  if vim.fn.executable(cmd[1]) == 0 then
    vim.notify(
      ("AL agent: '%s' not found in PATH. Install it first."):format(cmd[1]),
      vim.log.levels.ERROR)
    return
  end
  local buf = vim.api.nvim_create_buf(true, false)
  local win = show(buf, title or cmd[1])
  local job = vim.fn.jobstart(cmd, { term = true, cwd = root, env = env })  -- nvim 0.11 terminal
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].term_title = title or cmd[1]
  M._terms[key] = { buf = buf, win = win, job = job }
  vim.cmd("startinsert")
  return buf
end

-- Claude Code (Pro-sub quota; uses the al:<project> entry al.mcp writes to <project>/.claude/settings.json).
function M.claude()
  return open_term(require("al").config.agent.claude_cmd, "Claude Code")
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
  return open_term(cmd, "Pi", env)
end

return M
