local M = {}

local EXT_PATH = require("al.ext").path or ""
local ALC      = EXT_PATH .. "/bin/linux/alc"

-- Locate the AL project root by searching upward for app.json
local function find_project_root()
  local buf_path = vim.fn.expand("%:p")
  return vim.fs.root(buf_path, { "app.json" })
end

-- Ensure alc is executable (the file is shipped without the exec bit set)
local function ensure_executable(path)
  local stat = vim.uv.fs_stat(path)
  if stat and bit.band(stat.mode, 0o111) == 0 then
    vim.uv.fs_chmod(path, bit.bor(stat.mode, 0o111))
  end
end

-- Parse alc compiler output into a quickfix-compatible list.
-- alc format:  /path/to/file.al(line,col): error|warning ALxxxx: message
local function parse_output(lines)
  local qf = {}
  for _, line in ipairs(lines) do
    local file, lnum, col, kind, code, msg =
      line:match("^(.+)%((%d+),(%d+)%)%s*:%s*(%a+)%s+(%S+):%s+(.+)$")
    if file then
      table.insert(qf, {
        filename = file,
        lnum     = tonumber(lnum),
        col      = tonumber(col),
        type     = kind:sub(1, 1):upper(),   -- "E" or "W"
        text     = code .. ": " .. msg,
      })
    end
  end
  return qf
end

local function finish(qf, exit_code, on_success)
  vim.schedule(function()
    vim.fn.setqflist(qf, "r")
    if #qf > 0 then
      vim.cmd("copen")
      local errors   = vim.tbl_filter(function(e) return e.type == "E" end, qf)
      local warnings = vim.tbl_filter(function(e) return e.type == "W" end, qf)
      vim.notify(
        string.format("AL: %d error(s), %d warning(s)", #errors, #warnings),
        #errors > 0 and vim.log.levels.ERROR or vim.log.levels.WARN
      )
    elseif exit_code == 0 then
      vim.notify("AL: Build succeeded", vim.log.levels.INFO)
      if on_success then on_success() end
    end
  end)
end

-- Run alc asynchronously and populate the quickfix list with results.
-- @param project_dir  optional override; defaults to the directory of app.json
-- @param extra_args   optional table of additional /flag:value strings
-- @param on_success   optional function() called after a clean build (no errors)
function M.compile(project_dir, extra_args, on_success)
  project_dir = project_dir or find_project_root()
  if not project_dir then
    vim.notify("AL: Cannot find project root (no app.json found)", vim.log.levels.ERROR)
    return
  end

  ensure_executable(ALC)

  local cfg          = require("al").config
  local packagecache = project_dir .. "/" .. (cfg.packagecachepath or ".alpackages")

  local cmd = {
    ALC,
    "/project:" .. project_dir,
    "/packagecachepath:" .. packagecache,
  }
  for _, arg in ipairs(extra_args or cfg.alc_extra_args or {}) do
    table.insert(cmd, arg)
  end

  vim.notify("AL: Building " .. vim.fn.fnamemodify(project_dir, ":t") .. "…", vim.log.levels.INFO)

  local output = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) vim.list_extend(output, data) end,
    on_stderr = function(_, data) vim.list_extend(output, data) end,
    on_exit   = function(_, code)
      finish(parse_output(output), code, on_success)
    end,
  })
end

-- Open app.json for the current project
function M.open_app_json()
  local root = find_project_root()
  if not root then
    vim.notify("AL: No app.json found", vim.log.levels.ERROR)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/app.json"))
end

-- Open .vscode/launch.json for the current project
function M.open_launch_json()
  local root = find_project_root()
  if not root then
    vim.notify("AL: No app.json found", vim.log.levels.ERROR)
    return
  end
  local launch = root .. "/.vscode/launch.json"
  if vim.fn.filereadable(launch) == 0 then
    vim.notify("AL: No .vscode/launch.json found at " .. launch, vim.log.levels.WARN)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(launch))
end

return M
