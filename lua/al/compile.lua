local M = {}

local platform = require("al.platform")
local lsp      = require("al.lsp")

-- Namespace for compile diagnostics pushed to vim.diagnostic (file-tree badges).
local DIAG_NS = vim.api.nvim_create_namespace("al_compile")

-- The compiler: `al compile` from the dotnet tool, which forwards its args to
-- the alc it bundles (so /project: /packagecachepath: /analyzer: all work).
--
-- There is deliberately NO fallback to the VS Code extension's alc. There used
-- to be, and it hid the real problem: on a Windows machine where the tool was
-- not found (see altool.candidates for why that happens), every build silently
-- ran the extension's compiler instead — with the extension's analyzers, from
-- a different release than the tool the rest of ALNvim was using. A missing
-- tool is now an error that says where it looked.
--
-- Returns a fresh array (safe to append to), or nil when the tool is missing.
local function compiler_prefix()
  local altool = require("al.altool")
  if not altool.available() then return nil end
  return { altool.binary(), "compile" }
end

-- Map VSCode cop tokens to analyzer DLL basenames, resolved to full paths by
-- analyzer_dll() from the dotnet tool's own store.
local COP_DLL = {
  ["${CodeCop}"]               = "Microsoft.Dynamics.Nav.CodeCop.dll",
  ["${PerTenantExtensionCop}"] = "Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll",
  ["${UICop}"]                 = "Microsoft.Dynamics.Nav.UICop.dll",
  ["${AppSourceCop}"]          = "Microsoft.Dynamics.Nav.AppSourceCop.dll",
}

-- Analyzer directory inside the dotnet tool store, cached per resolved binary.
--
-- The store is a sibling of the binary (<tools>/.store/<package>/...), so it is
-- located from altool.binary() rather than from "~": on Windows those can
-- differ, and a store looked up under the wrong home is simply not found.
-- Globbed paths come back with backslashes on Windows, so they are normalised
-- before matching the framework folder.
local _analyzers = { bin = nil, dir = nil }
local function dotnet_analyzer_dir()
  local bin = require("al.altool").binary()
  if _analyzers.bin == bin then return _analyzers.dir or nil end
  local store = vim.fn.fnamemodify(bin, ":h")
    .. "/.store/microsoft.dynamics.businesscentral.development.tools"
  local hits = vim.fn.glob(store .. "/**/Microsoft.Dynamics.Nav.CodeCop.dll", false, true)
  -- Prefer the net8.0 build: it matches the alc the tool bundles on the
  -- broadest set of installed runtimes.
  local chosen
  for _, h in ipairs(hits) do
    if h:gsub("\\", "/"):match("/net8%.0/") then chosen = h break end
  end
  chosen = chosen or hits[1]
  _analyzers.bin = bin
  _analyzers.dir = chosen and vim.fn.fnamemodify(chosen, ":h") or false
  return _analyzers.dir or nil
end

-- Resolve a cop token to an analyzer DLL path (or nil if unavailable).
local function analyzer_dll(token)
  local base = COP_DLL[token]
  if not base then return nil end
  local dir = dotnet_analyzer_dir()
  if not dir then return nil end
  local p = dir .. "/" .. base
  return vim.fn.filereadable(p) == 1 and p or nil
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

-- Track the running silent-analyze job so repeated calls cancel the previous one.
-- _analyze_gen is bumped per call so a cancelled job's late on_exit can identify
-- itself as stale and stay out of the way of the job that replaced it.
local _analyze_job = nil
local _analyze_gen = 0

-- Line framing for job output lives in altool (shared with the tool runner).
local line_stream = require("al.altool").line_stream

-- Strip \r so Windows \r\n output doesn't show ^M in the buffer or break parsing.
local function strip_cr(lines)
  return vim.tbl_map(function(l) return (l:gsub("\r", "")) end, lines)
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
      -- `code` ("AL0118", "AA0137") is what lua/al/codeactions.lua keys its
      -- quick fixes on; alc puts it at the start of the message text.
      table.insert(diag_by_buf[bufnr], {
        lnum     = math.max(0, (item.lnum or 1) - 1),
        col      = math.max(0, (item.col  or 1) - 1),
        message  = item.text,
        code     = (item.text or ""):match("^(%u%u%d%d%d%d)"),
        source   = "alc",
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
  for _, name in ipairs(lsp.CLIENT_NAMES) do
    for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
      if c.root_dir == project_dir then
        local ns = vim.lsp.diagnostic.get_namespace(c.id)
        for bufnr in pairs(c.attached_buffers or {}) do
          vim.diagnostic.reset(ns, bufnr)
        end
        return
      end
    end
  end
end

-- Per-root build state: { sink, qf, job, gen }. One build view per project
-- root (id "alnvim.build:<root>"), so two projects — two Catnip workspace tabs —
-- never share or wipe each other's output. `gen` is bumped per compile so a
-- stopped job's late output and on_exit stay out of the build that replaced it.
M._builds = {}

local function build_state(root)
  local b = M._builds[root]
  if not b then b = { gen = 0 }; M._builds[root] = b end
  return b
end

-- Open the navigator (Catnip) or quickfix (native) on a build's diagnostics.
local function browse(root, qf)
  return require("al.host").locations({
    id       = "alnvim.build.diagnostics:" .. root,
    title    = "AL Build Diagnostics — " .. vim.fn.fnamemodify(root, ":t"),
    qf_title = "AL Build",
    items    = qf,
  })
end

local function nonempty(lines)
  return vim.tbl_filter(function(l) return l ~= "" end, lines)
end

local function finish(b, gen, qf, exit_code, on_success, project_dir)
  vim.schedule(function()
    if b.gen ~= gen then return end
    b.job = nil
    local sink     = b.sink
    local errors   = vim.tbl_filter(function(e) return e.type == "E" end, qf)
    local warnings = vim.tbl_filter(function(e) return e.type == "W" end, qf)
    local ok = exit_code == 0 and #errors == 0
    local summary
    if ok then
      if #warnings > 0 then
        summary = string.format("Build succeeded  (%d warning(s))", #warnings)
      else
        summary = "Build succeeded"
      end
    else
      summary = string.format("%d error(s), %d warning(s)", #errors, #warnings)
    end
    local line = "── " .. summary .. " ──"
    -- Under Catnip a failed build gets `d` in its view: the linked navigator on
    -- this build's diagnostics. Natively quickfix is already filled (<leader>aq).
    local navigable = not ok and sink.host == "catnip"
      and #(require("al.host").to_items(qf)) > 0
    if navigable then
      line = line .. "  d: browse"
      local snapshot = vim.deepcopy(qf)
      sink:map("d", function() browse(project_dir, snapshot) end, "Browse build diagnostics")
    end
    sink:append(nonempty({ "", line }))
    buf_highlight(sink.buf)

    require("al.status").set_compile_result(#errors, #warnings)
    b.qf = vim.deepcopy(qf)
    vim.fn.setqflist(qf, "r")
    push_diagnostics(qf)

    if ok then
      if project_dir then clear_lsp_diagnostics(project_dir) end
      if on_success then on_success() end
    end
  end)
end

-- Run alc asynchronously, stream output into the host's build view (Catnip
-- view or native bottom split, one per root), and populate the quickfix list
-- with parsed errors/warnings.
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
    vim.notify(require("al.altool").missing_msg("Compiling"), vim.log.levels.ERROR)
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
  -- Repeated rather than one comma list: alc accumulates them, and a directory
  -- name may itself contain a comma.
  for _, dir in ipairs(lsp.assembly_probing_paths(project_dir)) do
    table.insert(cmd, "/assemblyprobingpaths:" .. dir)
  end

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

  -- One build per root: a second compile of the same project stops the first
  -- before clearing its view (the generation guard drops its late output).
  local b = build_state(project_dir)
  if b.job then pcall(vim.fn.jobstop, b.job) end
  b.job = nil
  b.gen = b.gen + 1
  local gen = b.gen
  -- Never expose diagnostics from a previous build while a new one runs.
  b.qf = nil

  -- The host picks the sink (Catnip view or the native bottom split); callers
  -- — :ALCompile, publish, tests, debug — never choose it.
  local proj_name = vim.fn.fnamemodify(project_dir, ":t")
  local sink = require("al.host").output({
    id     = "alnvim.build:" .. project_dir,
    title  = "AL Build — " .. proj_name,
    hint   = "q to close, <CR> to open error",
    native = "split",
  })
  b.sink = sink
  sink:unmap("d") -- the previous build's navigator key
  sink:clear()
  sink:open({ focus = true })
  -- <CR> on a diagnostic line opens it: a managed child tab under Catnip, the
  -- edit window the build was started from natively. Commands and the summary
  -- line are inert.
  sink:on_enter(function(text)
    local file, lnum, col = text:match("^(.+)%((%d+),(%d+)%)%s*:%s*(%a+)%s")
    if not file then return end
    file = file:gsub("\\", "/")
    if not (file:match("^[A-Za-z]:/") or file:match("^/")) then
      file = (build_cwd or project_dir) .. "/" .. file
    end
    require("al.host").edit(file, tonumber(lnum), tonumber(col), { from = sink })
  end)

  local function emit(lines)
    if b.gen ~= gen then return end
    sink:append(nonempty(lines))
  end
  emit({ "$ " .. table.concat(cmd, " "), "" })

  local output = {}
  local function consume(lines)
    local clean = strip_cr(lines)
    vim.list_extend(output, clean)
    vim.schedule(function() emit(clean) end)
  end
  -- Separate carries: stdout and stderr are independent streams and interleaving
  -- their partial lines through one buffer would corrupt both.
  local feed_out, flush_out = line_stream(consume)
  local feed_err, flush_err = line_stream(consume)

  b.job = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data) feed_out(data) end,
    on_stderr = function(_, data) feed_err(data) end,
    on_exit = function(_, code)
      flush_out()
      flush_err()
      if b.gen ~= gen then return end
      finish(b, gen, parse_output(output, build_cwd), code, on_success, project_dir)
    end,
  })
end

-- Run alc silently (no build window, no quickfix) and push results to vim.diagnostic.
-- Used by ALAnalyze to populate file-tree badges for all project files.
-- @param on_done  optional function(qf) called (scheduled) once the results are
--                 published; a run cancelled by a newer one never calls it.
function M.analyze_diagnostics(project_dir, on_done)
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
  -- Repeated rather than one comma list: alc accumulates them, and a directory
  -- name may itself contain a comma.
  for _, dir in ipairs(lsp.assembly_probing_paths(project_dir)) do
    table.insert(cmd, "/assemblyprobingpaths:" .. dir)
  end
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
        if on_done then on_done(qf) end
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

-- Reopen the build view of `root` (default: the current project).
function M.open_build_output(root)
  root = root or lsp.get_root()
  local b = root and M._builds[root]
  if not (b and b.sink) then
    vim.notify("AL: no build output for this project yet; run :ALCompile", vim.log.levels.INFO)
    return false
  end
  b.sink:open({ focus = true })
  return true
end

-- Browse the diagnostics of the last *finished* build of `root`.
function M.open_build_diagnostics(root)
  root = root or lsp.get_root()
  local b = root and M._builds[root]
  if not (b and b.qf) then
    vim.notify("AL: run :ALCompile and wait for it to finish first", vim.log.levels.INFO)
    return false
  end
  return browse(root, b.qf)
end

-- Expose the resolved compiler invocation (for :ALInfo / diagnostics).
M.compiler_prefix = compiler_prefix

-- Pure internals exposed for tests/ only. Not API — do not call from plugin code.
M._test = { line_stream = line_stream, parse_output = parse_output,
            push_diagnostics = push_diagnostics, DIAG_NS = DIAG_NS }

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
