local M = {}

local EXT_PATH = require("al.ext").path or ""
local ALC      = EXT_PATH .. "/bin/linux/alc"
local lsp      = require("al.lsp")

-- Map VSCode cop tokens to the actual analyzer DLL paths that alc accepts.
local ANALYZER_DLLS = {
  ["${CodeCop}"]               = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.CodeCop.dll",
  ["${PerTenantExtensionCop}"] = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll",
  ["${UICop}"]                 = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.UICop.dll",
  ["${AppSourceCop}"]          = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.AppSourceCop.dll",
}

-- Ensure alc is executable (the file is shipped without the exec bit set)
local function ensure_executable(path)
  local stat = vim.uv.fs_stat(path)
  if stat and bit.band(stat.mode, 73) == 0 then
    vim.uv.fs_chmod(path, bit.bor(stat.mode, 73))
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

-- Open a floating window for build output. Returns (buf, win).
local function open_build_win(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local width  = math.max(80, math.floor(vim.o.columns * 0.8))
  local height = math.max(10, math.floor(vim.o.lines   * 0.6))
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
  })

  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q",     "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })

  return buf, win
end

-- Append non-empty lines to a buffer and scroll to the bottom.
local function buf_append(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local nonempty = vim.tbl_filter(function(l) return l ~= "" end, lines)
  if #nonempty == 0 then return end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, nonempty)
  -- Scroll every window showing this buffer to the last line
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(w, { last, 0 })
  end
end

-- Add simple highlight passes over the finished buffer.
local function buf_highlight(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local ns = vim.api.nvim_create_namespace("al_build")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local hl
    if line:match("%serror%s") or line:match("^error") then
      hl = "DiagnosticError"
    elseif line:match("%swarning%s") or line:match("^warning") then
      hl = "DiagnosticWarn"
    elseif line:match("Build succeeded") then
      hl = "DiagnosticOk"
    end
    if hl then
      vim.api.nvim_buf_add_highlight(buf, ns, hl, i - 1, 0, -1)
    end
  end
end

local function finish(buf, qf, exit_code, on_success)
  vim.schedule(function()
    -- Summary line
    local errors   = vim.tbl_filter(function(e) return e.type == "E" end, qf)
    local warnings = vim.tbl_filter(function(e) return e.type == "W" end, qf)
    local summary
    if exit_code == 0 and #errors == 0 then
      if #warnings > 0 then
        summary = string.format("Build succeeded  (%d warning(s))", #warnings)
      else
        summary = "Build succeeded"
      end
    else
      summary = string.format("%d error(s), %d warning(s)", #errors, #warnings)
    end
    buf_append(buf, { "", "── " .. summary .. " ──" })
    buf_highlight(buf)

    require("al.status").set_compile_result(#errors, #warnings)

    -- Populate quickfix (for jump-to-error with <leader>aq)
    vim.fn.setqflist(qf, "r")

    -- Success = clean exit and no errors. Warnings are allowed — they don't block publish.
    if exit_code == 0 and #errors == 0 then
      if on_success then on_success() end
    end
  end)
end

-- Run alc asynchronously, stream output into a floating window,
-- and populate the quickfix list with parsed errors/warnings.
-- @param project_dir  optional override; defaults to the directory of app.json
-- @param extra_args   optional table of additional /flag:value strings
-- @param on_success   optional function() called after a clean build (no errors)
function M.compile(project_dir, extra_args, on_success)
  project_dir = project_dir or lsp.get_root()
  if not project_dir then
    vim.notify("AL: Cannot find project root (no app.json found)", vim.log.levels.ERROR)
    return
  end

  ensure_executable(ALC)
  require("al.status").set_compiling()

  local cfg          = require("al").config
  local packagecache = project_dir .. "/" .. (cfg.packagecachepath or ".alpackages")

  local cmd = {
    ALC,
    "/project:" .. project_dir,
    "/packagecachepath:" .. packagecache,
  }

  -- Add active code analyzers so warnings from CodeCop etc. appear in compile output.
  -- Uses the same cop selection as the LSP (saved in .vscode/alnvim.json or defaults).
  for _, token in ipairs(require("al.cops").get_active(project_dir)) do
    local dll = ANALYZER_DLLS[token]
    if dll and vim.fn.filereadable(dll) == 1 then
      table.insert(cmd, "/analyzer:" .. dll)
    end
  end

  -- Ruleset: suppress/adjust specific diagnostic severities.
  -- Set via require("al").setup({ ruleset_path = "/path/to/codeanalyzer.json" })
  if cfg.ruleset_path and vim.fn.filereadable(cfg.ruleset_path) == 1 then
    table.insert(cmd, "/ruleset:" .. cfg.ruleset_path)
  end

  for _, arg in ipairs(extra_args or cfg.alc_extra_args or {}) do
    table.insert(cmd, arg)
  end

  local proj_name = vim.fn.fnamemodify(project_dir, ":t")
  local buf, _win = open_build_win("AL Build — " .. proj_name)
  buf_append(buf, { "$ " .. table.concat(cmd, " "), "" })

  local output = {}
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      vim.list_extend(output, data)
      vim.schedule(function() buf_append(buf, data) end)
    end,
    on_stderr = function(_, data)
      vim.list_extend(output, data)
      vim.schedule(function() buf_append(buf, data) end)
    end,
    on_exit = function(_, code)
      finish(buf, parse_output(output), code, on_success)
    end,
  })
end

-- Open app.json for the current project
function M.open_app_json()
  local root = lsp.get_root()
  if not root then
    vim.notify("AL: No app.json found", vim.log.levels.ERROR)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/app.json"))
end

-- Open .vscode/launch.json for the current project
function M.open_launch_json()
  local root = lsp.get_root()
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
