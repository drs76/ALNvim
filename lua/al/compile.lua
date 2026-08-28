local M = {}

local platform = require("al.platform")
local lsp      = require("al.lsp")

-- Extension alc invocation, or nil when no VSCode extension is installed.
-- Resolved per call (not at require time) so a mid-session :ALInstallExtension
-- is picked up without restarting Neovim. ext.alc_cmd() owns the layout
-- difference (native bin/<platform>/alc vs `dotnet bin/alc.dll`).
local function ext_alc()
  return require("al.ext").alc_cmd()
end

-- Namespace for compile diagnostics pushed to vim.diagnostic (file-tree badges).
local DIAG_NS = vim.api.nvim_create_namespace("al_compile")

-- Ensure alc is executable (no-op on Windows; sets exec bit on Linux/macOS)
local function ensure_executable(path)
  platform.ensure_executable(path)
end

-- Resolve the compiler invocation prefix.
--   1. `al compile` from the dotnet tool (Microsoft.Dynamics.BusinessCentral.
--      Development.Tools) — forwards its args straight to a bundled alc, so the same
--      /project: /packagecachepath: /analyzer: flags work. Preferred: the extension-free
--      stack is the primary toolchain; the VSCode extension is only needed for
--      EditorServices (LSP/DAP).
--   2. Fallback: the VSCode extension's alc binary, when the dotnet tool is absent.
-- Returns a fresh array (safe to append to), or nil if neither compiler is available.
local function compiler_prefix()
  local al_bin = require("al.agentic_lsp").binary()
  if vim.fn.executable(al_bin) == 1 then
    return { al_bin, "compile" }
  end
  -- Already a command array, and already validated/chmod'd by ext.alc_cmd().
  return ext_alc()
end

-- Map VSCode cop tokens to analyzer DLL basenames. Resolved to a full path by
-- analyzer_dll() below, preferring the DLLs bundled inside the dotnet tool
-- store (version-matched to the `al compile` alc) and falling back to the
-- extension's shared Analyzers dir.
local COP_DLL = {
  ["${CodeCop}"]               = "Microsoft.Dynamics.Nav.CodeCop.dll",
  ["${PerTenantExtensionCop}"] = "Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll",
  ["${UICop}"]                 = "Microsoft.Dynamics.Nav.UICop.dll",
  ["${AppSourceCop}"]          = "Microsoft.Dynamics.Nav.AppSourceCop.dll",
}

-- Analyzer directory inside the dotnet tool store. Cached: nil = not yet probed,
-- false = probed and absent, string = the resolved directory.
local _store_analyzer_dir = nil
local function dotnet_analyzer_dir()
  if _store_analyzer_dir ~= nil then return _store_analyzer_dir or nil end
  local base = vim.fn.expand("~/.dotnet/tools/.store/microsoft.dynamics.businesscentral.development.tools")
  local hits = vim.fn.glob(base .. "/**/Microsoft.Dynamics.Nav.CodeCop.dll", false, true)
  -- Prefer a net8.0 build for broad runtime compatibility, else take the first.
  local chosen
  for _, h in ipairs(hits) do
    if h:match("/net8%.0/") then chosen = h break end
  end
  chosen = chosen or hits[1]
  _store_analyzer_dir = chosen and vim.fn.fnamemodify(chosen, ":h") or false
  return _store_analyzer_dir or nil
end

-- Resolve a cop token to an analyzer DLL path (or nil if unavailable).
local function analyzer_dll(token)
  local base = COP_DLL[token]
  if not base then return nil end
  -- Dotnet tool store first — matches the compiler priority in compiler_prefix()
  -- so analyzer and alc versions stay in sync.
  local dir = dotnet_analyzer_dir()
  if dir then
    local p = dir .. "/" .. base
    if vim.fn.filereadable(p) == 1 then return p end
  end
  -- Extension fallback. Analyzers live in bin/Analyzers/ on the native layout
  -- and flat in bin/ on the dotnet one; ext.analyzers_dir() resolves both.
  local ext_dir = require("al.ext").analyzers_dir()
  if ext_dir then
    local p = ext_dir .. "/" .. base
    if vim.fn.filereadable(p) == 1 then return p end
  end
  return nil
end

-- Parse alc compiler output into a quickfix-compatible list.
-- Two formats:
--   /path/to/file.al(line,col): error|warning ALxxxx: message   (file diagnostic)
--   error|warning ALxxxx: message                               (no file, e.g. AL1022 missing package)
local function parse_output(lines, project_dir)
  local qf = {}
  for _, line in ipairs(lines) do
    -- File-scoped diagnostic (has filename + position)
    local file, lnum, col, kind, code, msg =
      line:match("^(.+)%((%d+),(%d+)%)%s*:%s*(%a+)%s+(%S+):%s+(.+)$")
    if file then
      file = file:gsub("\\", "/")
      if project_dir and not (file:match("^[A-Za-z]:/") or file:match("^/")) then
        file = project_dir .. "/" .. file
      end
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

-- Track the running silent-analyze job so repeated calls cancel the previous one.
-- _analyze_gen is bumped per call so a cancelled job's late on_exit can identify
-- itself as stale and stay out of the way of the job that replaced it.
local _analyze_job = nil
local _analyze_gen = 0

-- jobstart (without stdout_buffered) delivers output in chunks where data[1]
-- continues the previous chunk's trailing partial line and data[#data] is itself
-- partial. Appending chunks verbatim splits a diagnostic across two "lines", so
-- it renders garbled in the panel and never matches the quickfix pattern.
--
-- Returns (feed, flush): feed(data) hands on_lines only complete lines; flush()
-- emits the final partial line and must be called from on_exit.
local function line_stream(on_lines)
  local carry = ""
  local function feed(data)
    if not data then return end
    local out = {}
    carry = carry .. (data[1] or "")
    for i = 2, #data do
      out[#out + 1] = carry
      carry = data[i]
    end
    if #out > 0 then on_lines(out) end
  end
  local function flush()
    if carry ~= "" then
      local last = carry
      carry = ""
      on_lines({ last })
    end
  end
  return feed, flush
end

-- Strip \r so Windows \r\n output doesn't show ^M in the buffer or break parsing.
local function strip_cr(lines)
  return vim.tbl_map(function(l) return (l:gsub("\r", "")) end, lines)
end

-- Open a full-width horizontal split at the bottom for build output. Returns (buf, win).
-- The window above (where the file is) is used for <CR> jump-to-error.
local function open_build_win(title, project_dir, build_cwd)
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
  local file_win = is_edit_win(cur) and cur or find_edit_win(nil)  -- mutable: updated if we create a split

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
    file = file:gsub("\\", "/")
    if not (file:match("^[A-Za-z]:/") or file:match("^/")) then
      file = (build_cwd or project_dir) .. "/" .. file
    end
    local target = (file_win and vim.api.nvim_win_is_valid(file_win) and is_edit_win(file_win) and file_win)
                   or find_edit_win(win)
    if not target then
      -- Fall back to any non-floating, non-build window (e.g. alpha dashboard).
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= win and vim.api.nvim_win_get_config(w).relative == "" then
          target = w
          file_win = w
          break
        end
      end
    end
    if not target then
      -- Last resort: split above build window.
      vim.api.nvim_win_call(win, function() vim.cmd("aboveleft split") end)
      target = vim.api.nvim_get_current_win()
      file_win = target
    end
    vim.api.nvim_win_call(target, function()
      local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file))
      if not ok then
        vim.notify("AL: cannot open " .. file .. "\n" .. tostring(err), vim.log.levels.ERROR)
        return
      end
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
      vim.hl.range(buf, ns, hl, { i - 1, 0 }, { i - 1, -1 })
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

-- After a clean build, reset the AL LSP's diagnostic namespace for all
-- attached buffers so stale server-side false positives don't linger.
local function clear_lsp_diagnostics(project_dir)
  local clients = vim.lsp.get_clients({ name = "al_language_server" })
  for _, c in ipairs(clients) do
    if c.root_dir == project_dir then
      local ns = vim.lsp.diagnostic.get_namespace(c.id)
      for bufnr in pairs(c.attached_buffers or {}) do
        vim.diagnostic.reset(ns, bufnr)
      end
      return
    end
  end
end

local function finish(buf, qf, exit_code, on_success, project_dir)
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
      if project_dir then clear_lsp_diagnostics(project_dir) end
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

  local build_cwd = vim.fn.getcwd()
  local prefix = compiler_prefix()
  if not prefix then
    vim.notify(
      "AL: no compiler found — run :ALInstallExtension or :ALInstallDotnetTool",
      vim.log.levels.ERROR)
    return
  end
  require("al.status").set_compiling()

  local cfg          = require("al").config
  local packagecache = project_dir .. "/" .. (cfg.packagecachepath or ".alpackages")

  local cmd = vim.deepcopy(prefix)
  vim.list_extend(cmd, {
    "/project:" .. project_dir,
    "/packagecachepath:" .. packagecache,
  })

  -- Add active code analyzers so warnings from CodeCop etc. appear in compile output.
  -- Uses the same cop selection as the LSP (saved in .vscode/alnvim.json or defaults).
  for _, token in ipairs(require("al.cops").get_active(project_dir)) do
    local dll = analyzer_dll(token)
    if dll then
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
  local buf, _win = open_build_win("AL Build — " .. proj_name, project_dir, build_cwd)
  buf_append(buf, { "$ " .. table.concat(cmd, " "), "" })

  local output = {}
  local function consume(lines)
    local clean = strip_cr(lines)
    vim.list_extend(output, clean)
    vim.schedule(function() buf_append(buf, clean) end)
  end
  -- Separate carries: stdout and stderr are independent streams and interleaving
  -- their partial lines through one buffer would corrupt both.
  local feed_out, flush_out = line_stream(consume)
  local feed_err, flush_err = line_stream(consume)

  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data) feed_out(data) end,
    on_stderr = function(_, data) feed_err(data) end,
    on_exit = function(_, code)
      flush_out()
      flush_err()
      finish(buf, parse_output(output, build_cwd), code, on_success, project_dir)
    end,
  })
end

-- Run alc silently (no build window, no quickfix) and push results to vim.diagnostic.
-- Used by ALAnalyze to populate file-tree badges for all project files.
function M.analyze_diagnostics(project_dir)
  project_dir = project_dir or lsp.get_root()
  if not project_dir then return end

  local build_cwd = vim.fn.getcwd()
  -- Cancel any in-progress analyze job before starting a new one. The cancelled
  -- job still fires on_exit later with truncated output — _analyze_gen lets that
  -- callback recognise itself as stale (see on_exit below).
  if _analyze_job then
    pcall(vim.fn.jobstop, _analyze_job)
    _analyze_job = nil
  end
  _analyze_gen = _analyze_gen + 1
  local gen = _analyze_gen

  local prefix = compiler_prefix()
  if not prefix then return end

  local cfg          = require("al").config
  local packagecache = project_dir .. "/" .. (cfg.packagecachepath or ".alpackages")
  local cmd = vim.deepcopy(prefix)
  vim.list_extend(cmd, {
    "/project:" .. project_dir,
    "/packagecachepath:" .. packagecache,
  })
  for _, token in ipairs(require("al.cops").get_active(project_dir)) do
    local dll = analyzer_dll(token)
    if dll then
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
  local function consume(lines)
    vim.list_extend(output, strip_cr(lines))
  end
  local feed_out, flush_out = line_stream(consume)
  local feed_err, flush_err = line_stream(consume)

  _analyze_job = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data) feed_out(data) end,
    on_stderr = function(_, data) feed_err(data) end,
    on_exit = function(_, code)
      flush_out()
      flush_err()
      -- A job cancelled by a newer analyze call still reaches on_exit. Publishing
      -- its partial output would reset the diagnostic namespace and write
      -- truncated results over the newer run; clearing _analyze_job would also
      -- orphan the newer job so the call after that could not cancel it.
      if gen ~= _analyze_gen then return end
      _analyze_job = nil
      local qf = parse_output(output, build_cwd)
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

-- Debounced analyze. BufWritePost fires per save, and analyze_diagnostics runs a
-- full-project alc pass; on a burst of saves (:wa, formatter round-trips, rapid
-- edits) that queued one rebuild per file. Coalesce them into a single run.
local _analyze_timer = nil
function M.analyze_soon(project_dir, delay_ms)
  if _analyze_timer then
    _analyze_timer:stop()
    _analyze_timer:close()
    _analyze_timer = nil
  end
  local t = vim.uv.new_timer()
  _analyze_timer = t
  t:start(delay_ms or (require("al").config.analyze_debounce_ms or 1500), 0,
    vim.schedule_wrap(function()
      -- A newer call may have replaced (and closed) this timer between the uv
      -- callback firing and this scheduled function running — identity check,
      -- not a plain nil check, or we would close the timer that replaced us.
      if _analyze_timer ~= t then return end
      _analyze_timer = nil
      if not t:is_closing() then t:close() end
      M.analyze_diagnostics(project_dir)
    end))
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

-- Expose the resolved compiler invocation (for :ALInfo / diagnostics).
M.compiler_prefix = compiler_prefix

-- Pure internals exposed for tests/ only. Not API — do not call from plugin code.
M._test = { line_stream = line_stream, parse_output = parse_output }

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
