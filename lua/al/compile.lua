local M = {}

local platform = require("al.platform")
local EXT_PATH = require("al.ext").path or ""
local ALC      = EXT_PATH .. "/bin/" .. platform.bin_subdir() .. "/" .. platform.exe("alc")
local lsp      = require("al.lsp")

-- Namespace for compile diagnostics pushed to vim.diagnostic (file-tree badges).
local DIAG_NS = vim.api.nvim_create_namespace("al_compile")

-- Map VSCode cop tokens to the actual analyzer DLL paths that alc accepts.
local ANALYZER_DLLS = {
  ["${CodeCop}"]               = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.CodeCop.dll",
  ["${PerTenantExtensionCop}"] = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll",
  ["${UICop}"]                 = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.UICop.dll",
  ["${AppSourceCop}"]          = EXT_PATH .. "/bin/Analyzers/Microsoft.Dynamics.Nav.AppSourceCop.dll",
}

-- Ensure alc is executable (no-op on Windows; sets exec bit on Linux/macOS)
local function ensure_executable(path)
  platform.ensure_executable(path)
end

-- Parse alc compiler output into a quickfix-compatible list.
-- Two formats:
--   /path/to/file.al(line,col): error|warning ALxxxx: message   (file diagnostic)
--   error|warning ALxxxx: message                               (no file, e.g. AL1022 missing package)
local function parse_output(lines)
  local qf = {}
  for _, line in ipairs(lines) do
    -- File-scoped diagnostic (has filename + position)
    local file, lnum, col, kind, code, msg =
      line:match("^(.+)%((%d+),(%d+)%)%s*:%s*(%a+)%s+(%S+):%s+(.+)$")
    if file then
      table.insert(qf, {
        filename = file,
        lnum     = tonumber(lnum),
        col      = tonumber(col),
        type     = kind:sub(1, 1):upper(),
        text     = code .. ": " .. msg,
      })
    else
      -- Project-level diagnostic (no filename, e.g. missing package AL1022)
      local kind2, code2, msg2 = line:match("^(%a+)%s+(AL%d+):%s+(.+)$")
      if kind2 then
        table.insert(qf, {
          type = kind2:sub(1, 1):upper(),
          text = code2 .. ": " .. msg2,
        })
      end
    end
  end
  return qf
end

-- Track the last build window so re-running compile closes the previous one first.
local _build_win = nil

-- Open a full-width horizontal split at the bottom for build output. Returns (buf, win).
-- The window above (where the file is) is used for <CR> jump-to-error.
local function open_build_win(title, project_dir)
  -- Close any existing build window before opening a new one.
  if _build_win and vim.api.nvim_win_is_valid(_build_win) then
    vim.api.nvim_win_close(_build_win, true)
  end
  _build_win = nil

  -- Sidebar/plugin filetypes that should never be used as edit targets.
  local _sidebar_ft = {
    NvimTree = true, ["neo-tree"] = true, aerial = true,
    Outline = true, undotree = true, oil = true, qf = true,
    alpha = true, dashboard = true,
  }

  -- Returns true if w is a real editing window (not a sidebar, terminal, quickfix, …)
  local function is_edit_win(w)
    local buf = vim.api.nvim_win_get_buf(w)
    local bt  = vim.bo[buf].buftype
    if bt ~= "" and bt ~= "acwrite" then return false end
    return not _sidebar_ft[vim.bo[buf].filetype]
  end

  -- Find the best non-floating editing window, excluding `exclude`.
  local function find_edit_win(exclude)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= exclude and vim.api.nvim_win_get_config(w).relative == "" and is_edit_win(w) then
        return w
      end
    end
  end

  -- Remember the current window — the user ran :ALCompile from here.
  -- Fall back if it's a sidebar or plugin window.
  local cur = vim.api.nvim_get_current_win()
  local file_win = is_edit_win(cur) and cur or find_edit_win(nil)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  -- Full-width split pinned to the bottom of the screen.
  local split_height = math.max(15, math.floor(vim.o.lines * 0.30))
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, split_height)

  vim.wo[win].wrap         = false
  vim.wo[win].cursorline   = true
  vim.wo[win].number       = false
  vim.wo[win].signcolumn   = "no"
  vim.wo[win].winfixheight = true
  vim.wo[win].winbar       = "  " .. title .. "  (q to close, <CR> to open error)"

  _build_win = win

  vim.keymap.set("n", "q",     "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })

  -- <CR> on a diagnostic line: open file in the target pane, keep results visible.
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local file, lnum, col = line:match("^(.+)%((%d+),(%d+)%)%s*:")
    if not file then return end
    -- Normalize path separators (Windows alc uses backslashes).
    file = file:gsub("\\", "/")
    -- alc on Windows emits relative paths; resolve against the project root.
    if not (file:match("^[A-Za-z]:/") or file:match("^/")) then
      file = project_dir .. "/" .. file
    end
    local target = (file_win and vim.api.nvim_win_is_valid(file_win) and is_edit_win(file_win) and file_win)
                   or find_edit_win(win)
    if not target then return end
    vim.api.nvim_win_call(target, function()
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), tonumber(col) - 1 })
      vim.cmd("normal! zz")
    end)
    vim.api.nvim_set_current_win(target)
  end, { buffer = buf, nowait = true, silent = true })

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

local function push_diagnostics(qf)
  vim.diagnostic.reset(DIAG_NS)
  local diag_by_buf = {}
  for _, item in ipairs(qf) do
    if item.filename then
      local bufnr = vim.fn.bufadd(item.filename)
      diag_by_buf[bufnr] = diag_by_buf[bufnr] or {}
      table.insert(diag_by_buf[bufnr], {
        lnum     = math.max(0, (item.lnum or 1) - 1),
        col      = math.max(0, (item.col  or 1) - 1),
        message  = item.text,
        severity = item.type == "E" and vim.diagnostic.severity.ERROR
                                     or vim.diagnostic.severity.WARN,
      })
    end
  end
  for bufnr, diags in pairs(diag_by_buf) do
    vim.diagnostic.set(DIAG_NS, bufnr, diags)
  end
end

local function finish(buf, qf, exit_code, on_success)
  vim.schedule(function()
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
    vim.fn.setqflist(qf, "r")
    push_diagnostics(qf)

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
  local ruleset_path = cfg.ruleset_path and vim.fn.expand(cfg.ruleset_path) or nil
  if ruleset_path and vim.fn.filereadable(ruleset_path) == 1 then
    table.insert(cmd, "/ruleset:" .. ruleset_path)
  end

  for _, id in ipairs(cfg.suppressed_diagnostics or {}) do
    table.insert(cmd, "/nowarn:" .. id)
  end

  for _, arg in ipairs(extra_args or cfg.alc_extra_args or {}) do
    table.insert(cmd, arg)
  end

  local proj_name = vim.fn.fnamemodify(project_dir, ":t")
  local buf, _win = open_build_win("AL Build — " .. proj_name, project_dir)
  buf_append(buf, { "$ " .. table.concat(cmd, " "), "" })

  -- Strip \r so Windows \r\n output doesn't show ^M in the buffer or break parsing.
  local function strip_cr(lines)
    return vim.tbl_map(function(l) return l:gsub("\r", "") end, lines)
  end

  local output = {}
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      local clean = strip_cr(data)
      vim.list_extend(output, clean)
      vim.schedule(function() buf_append(buf, clean) end)
    end,
    on_stderr = function(_, data)
      local clean = strip_cr(data)
      vim.list_extend(output, clean)
      vim.schedule(function() buf_append(buf, clean) end)
    end,
    on_exit = function(_, code)
      finish(buf, parse_output(output), code, on_success)
    end,
  })
end

-- Run alc silently (no build window, no quickfix) and push results to vim.diagnostic.
-- Used by ALAnalyze to populate file-tree badges after LSP re-analysis.
function M.analyze_diagnostics(project_dir)
  project_dir = project_dir or lsp.get_root()
  if not project_dir then return end

  ensure_executable(ALC)

  local cfg          = require("al").config
  local packagecache = project_dir .. "/" .. (cfg.packagecachepath or ".alpackages")
  local cmd = {
    ALC,
    "/project:" .. project_dir,
    "/packagecachepath:" .. packagecache,
  }
  for _, token in ipairs(require("al.cops").get_active(project_dir)) do
    local dll = ANALYZER_DLLS[token]
    if dll and vim.fn.filereadable(dll) == 1 then
      table.insert(cmd, "/analyzer:" .. dll)
    end
  end
  local ruleset_path = cfg.ruleset_path and vim.fn.expand(cfg.ruleset_path) or nil
  if ruleset_path and vim.fn.filereadable(ruleset_path) == 1 then
    table.insert(cmd, "/ruleset:" .. ruleset_path)
  end

  for _, id in ipairs(cfg.suppressed_diagnostics or {}) do
    table.insert(cmd, "/nowarn:" .. id)
  end

  local output = {}
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      vim.list_extend(output, vim.tbl_map(function(l) return l:gsub("\r", "") end, data))
    end,
    on_stderr = function(_, data)
      vim.list_extend(output, vim.tbl_map(function(l) return l:gsub("\r", "") end, data))
    end,
    on_exit = function(_, code)
      local qf = parse_output(output)
      local errors = vim.tbl_filter(function(e) return e.type == "E" end, qf)
      local warnings = vim.tbl_filter(function(e) return e.type == "W" end, qf)
      vim.schedule(function()
        push_diagnostics(qf)
        vim.notify(string.format("AL: analyze complete — %d error(s), %d warning(s)",
          #errors, #warnings), vim.log.levels.INFO)
      end)
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
