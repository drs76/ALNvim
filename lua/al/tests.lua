-- AL test running, reference docs and "run object" through the AL dotnet tool.
--
--   :ALRunTests   — `al runtests <codeunit> --raw` streamed live, pass/fail → quickfix
--   :ALRunTests!  — the [Test] procedure under the cursor only
--   :ALDoc        — `al doc build` reference documentation into <root>/.aldoc
--   :ALRunObject  — open the object declared in the buffer in the web client
--
-- Discovery is offline: `al listtests --appfile <built .app>` reads the test
-- codeunits out of the package, so no server round trip is needed to pick one.
-- When no .app exists a compile is chained first. All three subcommands are
-- tool 30+; older tools get a clear "update the tool" message, never a
-- fallback to the VS Code extension.
--
-- Output formats are not documented; both parsers are fixtured in
-- tests/tests_spec.lua from what tool 30.0.42 emits:
--   listtests  → one JSON document  {"appId":…,"codeunits":[{"id":50130,"name":"My Tests",
--                "namespace":"","methods":[{"name":"FailingTest","isDataDriven":false}]}]}
--   runtests --raw → server log lines, then per codeunit
--                ===== Codeunit 50130 =====
--                Test run completed: 1 passed, 1 failed, 0 skipped.
--                Results:
--                  PASS PassingTest (12ms)
--                  FAIL FailingTest (3ms)
--                         <error text>
--                and a final "Test run completed: P passed, F failed, S skipped." On
--                failure the whole summary is printed to stderr prefixed
--                "Test run failed: " — so the prefix can sit in front of the first line.

local M = {}

local altool   = require("al.altool")
local lsp      = require("al.lsp")
local conn     = require("al.connection")
local platform = require("al.platform")

-- ── Pure helpers ────────────────────────────────────────────────────────────

-- `al listtests` output → { { codeunitId, name, methods = { "A", "B" } }, … }.
-- Tolerates log lines before the JSON document. Returns (nil, reason) when no
-- JSON is found.
local function parse_listtests(text)
  local start = text:find("{", 1, true)
  if not start then return nil, "no JSON in listtests output" end
  local ok, data = pcall(vim.fn.json_decode, text:sub(start))
  if not ok or type(data) ~= "table" then return nil, "listtests output is not JSON" end
  local out = {}
  for _, cu in ipairs(data.codeunits or {}) do
    local methods = {}
    for _, m in ipairs(cu.methods or {}) do
      if type(m) == "table" then methods[#methods + 1] = m.name else methods[#methods + 1] = m end
    end
    out[#out + 1] = { codeunitId = tonumber(cu.id), name = cu.name or "", methods = methods }
  end
  return out
end

-- `al runtests --raw` output lines → {
--   results = { { codeunit = 50130, method = "X", status = "PASS"|"FAIL"|"SKIP",
--                 ms = 3, output = "…" }, … },
--   passed = n, failed = n, skipped = n,   -- counted over `results`
-- }
-- Verified live on BC 28.5 (pcp-dev2): a FAIL's output is the error text on a
-- 7-space-indented line followed by an *unindented* "AL Callstack:" block, so
-- everything up to the next blank / result / summary line belongs to it. Each
-- codeunit also reports one nameless result (`  FAIL  (40ms)` — the codeunit
-- run itself, mirroring its worst method) which the tool counts in its totals;
-- it is dropped here and the counts are recomputed, so "1 failed" means one
-- method.
local function parse_runtests(lines)
  local res = { results = {}, passed = 0, failed = 0, skipped = 0 }
  local cu, last
  local function stop_output() last = nil end
  for _, raw in ipairs(lines) do
    local l = raw:gsub("\r", "")
    l = l:gsub("^Test run failed: ", "")
    local id = l:match("^===== Codeunit (%d+) =====")
    local status, name, ms = l:match("^  (%u%u%u%u?) (.-) %((%d+)ms%)%s*$")
    if id then
      cu = tonumber(id); stop_output()
    elseif status and (status == "PASS" or status == "FAIL" or status == "SKIP") then
      if name == "" then
        stop_output()                       -- the codeunit-level phantom
      else
        last = { codeunit = cu, method = name, status = status, ms = tonumber(ms) }
        res.results[#res.results + 1] = last
      end
    elseif l:match("^Test run completed:") or l:match("^Results:%s*$") or l:match("^%s*$") then
      stop_output()
    elseif last and last.status == "FAIL" then
      local txt = vim.trim(l)
      last.output = last.output and (last.output .. " " .. txt) or txt
    end
  end
  for _, r in ipairs(res.results) do
    if r.status == "PASS" then res.passed = res.passed + 1
    elseif r.status == "FAIL" then res.failed = res.failed + 1
    else res.skipped = res.skipped + 1 end
  end
  return res
end

-- Arguments for `al runtests`. `methods` nil/empty runs the whole codeunit.
-- `--raw` is what makes the output streamable and parseable; without it the
-- tool prints one JSON document at the end. Connection flags come from the
-- same launch.json mapping publish and symbols use.
local function build_runtests_args(root, codeunit_id, methods, cfg)
  local args = { "runtests", tostring(codeunit_id), "--project", root, "--raw" }
  for _, m in ipairs(methods or {}) do vim.list_extend(args, { "--testmethods", m }) end
  if cfg then vim.list_extend(args, altool.connection_flags(cfg)) end
  return args
end

-- Web-client query parameter per AL object type; nil = not runnable.
local RUN_PARAM = { page = "page", report = "report", table = "table", query = "query",
                    xmlport = "xmlport", codeunit = "codeunit" }

-- Parse `codeunit 50130 "My Tests"` → ("codeunit", 50130, "My Tests").
local function parse_obj_header(line)
  local kind, id = line:match("^%s*(%a+)%s+(%d+)")
  if not kind then return nil end
  local name = line:match('^%s*%a+%s+%d+%s+"([^"]+)"') or line:match("^%s*%a+%s+%d+%s+([^%s{]+)")
  return kind:lower(), tonumber(id), name
end

-- Web-client URL that opens object `id` of `kind`. Builds on conn.webclient_url
-- (same server/instance/tenant/cloud rules) but replaces its startup-object
-- query. Returns (nil, reason) for types the web client cannot open directly.
local function object_url(cfg, kind, id)
  local param = RUN_PARAM[kind]
  if not param then return nil, ("cannot run a %s in the web client"):format(kind) end
  local base = conn.webclient_url(cfg)
  local path, query = base:match("^([^?]*)%??(.*)$")
  path = path:gsub("/*$", "")
  local url = ("%s/?%s=%d"):format(path, param, id)
  local tenant = query:match("tenant=([^&]+)")
  if tenant then url = url .. "&tenant=" .. tenant end
  return url
end

-- The [Test] procedure enclosing 1-based `cursor_lnum`, or (nil, reason).
-- Attribute lines (`[Test]`, `[HandlerFunctions(...)]`) sit directly above the
-- header; anything else between them ends the attribute block.
local function test_method_at(lines, cursor_lnum)
  local b = require("al.refactor").helpers.find_proc_bounds(lines, cursor_lnum)
  if not b then return nil, "cursor is not inside a procedure" end
  local name = lines[b.hdr]:match('procedure%s+"([^"]+)"') or lines[b.hdr]:match("procedure%s+([%w_]+)")
  if not name then return nil, "cannot read the procedure name" end
  local i = b.hdr - 1
  while i >= 1 and lines[i]:match("^%s*%[") do
    if lines[i]:match("^%s*%[%s*[Tt]est%s*%]") then return name end
    i = i - 1
  end
  return nil, ("procedure %s has no [Test] attribute"):format(name)
end

-- Locate `procedure <method>(` inside the `codeunit <id>` file of the project.
-- Returns (file, lnum) or nil. Project files only — a test run never points
-- into a symbol package.
local function locate_method(root, codeunit_id, method)
  local want_decl = "^%s*codeunit%s+" .. codeunit_id .. "%f[%D]"
  local want_proc = "procedure%s+\"?" .. vim.pesc(method) .. "\"?%s*%("
  for _, file in ipairs(platform.glob_al_files(root)) do
    local fh = io.open(file, "r")
    if fh then
      local content = fh:read("*a"); fh:close()
      local lines = vim.split(content, "\n", { plain = true })
      local in_cu = false
      for n, l in ipairs(lines) do
        if l:match(want_decl) then in_cu = true end
        if in_cu and l:match(want_proc) then return file, n end
      end
    end
  end
  return nil
end

-- ── Guards ──────────────────────────────────────────────────────────────────

local function need(subcmd, what)
  if not altool.available() then
    vim.notify(altool.missing_msg(what), vim.log.levels.ERROR)
    return false
  end
  if not altool.has(subcmd) then
    vim.notify(("AL: %s needs `al %s`, which this AL dotnet tool lacks (tool 30+) — update:"
      .. " :ALInstallDotnetTool"):format(what, subcmd), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function get_root(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
  end
  return root
end

local function package_cache(root)
  local cfg = package.loaded["al"] and package.loaded["al"].config or {}
  return root .. "/" .. (cfg.packagecachepath or ".alpackages")
end

-- cb(app_file) with the built .app, compiling first when there is none.
local function with_app(root, cb)
  local publish = require("al.publish")
  local app = publish.find_app(root, lsp.read_app_json(root) or {})
  if app then cb(app); return end
  vim.notify("AL: no .app built yet — compiling first", vim.log.levels.INFO)
  require("al.compile").compile(root, nil, function()
    app = publish.find_app(root, lsp.read_app_json(root) or {})
    if app then cb(app) else
      vim.notify("AL: compile finished but no .app was found in " .. root, vim.log.levels.ERROR)
    end
  end)
end

-- ── Discovery ───────────────────────────────────────────────────────────────

-- cb(list) with the parsed test codeunits of the built package (compiles when
-- there is no .app). On failure notifies and does not call cb.
function M.list(root, cb)
  root = get_root(root)
  if not root or not need("listtests", "Listing tests") then return end
  with_app(root, function(app)
    altool.run_json({ "listtests", "--appfile", app, "--project", root }, nil,
      function(ok, text)
        if not ok then
          vim.notify("AL: al listtests failed:\n" .. text, vim.log.levels.ERROR)
          return
        end
        local list, err = parse_listtests(text)
        if not list then
          vim.notify("AL: " .. err .. "\n" .. text, vim.log.levels.ERROR)
          return
        end
        cb(list)
      end)
  end)
end

-- ── Pickers ─────────────────────────────────────────────────────────────────

local function pick_codeunit(list, cb)
  if #list == 0 then
    vim.notify("AL: the built .app contains no test codeunits", vim.log.levels.WARN)
    return
  end
  if #list == 1 then cb(list[1]); return end
  local labels = {}
  for _, cu in ipairs(list) do
    labels[#labels + 1] = ("%d  %s  (%d tests)"):format(cu.codeunitId, cu.name, #cu.methods)
  end
  vim.ui.select(labels, { prompt = "AL: Test codeunit" }, function(_, idx)
    if idx then cb(list[idx]) end
  end)
end

-- Multi-select of methods: Telescope (<Tab> toggles, <CR> runs the toggled set
-- or everything when nothing is toggled), else vim.ui.select with an "all
-- methods" entry. cb(methods) — empty table means the whole codeunit.
local function pick_methods(cu, cb)
  if #cu.methods <= 1 then cb({}); return end
  if pcall(require, "telescope") then
    local pickers      = require("telescope.pickers")
    local finders      = require("telescope.finders")
    local conf         = require("telescope.config").values
    local actions      = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    pickers.new({}, {
      prompt_title = ("AL: Tests in %d %s  (<Tab> toggle, <CR> run — none toggled = all)")
        :format(cu.codeunitId, cu.name),
      finder = finders.new_table({ results = cu.methods }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local chosen = {}
          for _, e in ipairs(picker:get_multi_selection()) do chosen[#chosen + 1] = e[1] end
          actions.close(prompt_bufnr)
          cb(chosen)
        end)
        return true
      end,
    }):find()
    return
  end
  local items = { "<all methods>" }
  vim.list_extend(items, cu.methods)
  vim.ui.select(items, { prompt = "AL: Test method" }, function(choice, idx)
    if not idx then return end
    cb(idx == 1 and {} or { choice })
  end)
end

-- ── Running ─────────────────────────────────────────────────────────────────

local function results_to_qf(root, parsed)
  local qf = {}
  for _, r in ipairs(parsed.results) do
    local file, lnum = locate_method(root, r.codeunit, r.method)
    local text = ("%s %s (%dms)"):format(r.status, r.method, r.ms or 0)
    if r.output then text = text .. ": " .. r.output end
    qf[#qf + 1] = {
      filename = file, lnum = lnum or 1, col = 1, text = text,
      type = r.status == "FAIL" and "E" or (r.status == "SKIP" and "W" or "I"),
      valid = file and 1 or 0,
    }
  end
  return qf
end

local function run_tests(root, codeunit_id, methods)
  conn.pick_launch(root, function(cfg)
    local args  = build_runtests_args(root, codeunit_id, methods, cfg)
    local lines = {}
    local what  = #methods > 0 and (codeunit_id .. " " .. table.concat(methods, ",")) or tostring(codeunit_id)
    require("al.status").set_compiling()
    altool.run(args, {
      title = "AL runtests " .. what, cwd = root, env = altool.cred_env(cfg),
      on_lines = function(batch) vim.list_extend(lines, batch) end,
    }, function(ok, _, _, win)
      local parsed = parse_runtests(lines)
      local qf     = results_to_qf(root, parsed)
      vim.fn.setqflist({}, " ", { title = "AL tests " .. what, items = qf })
      if #parsed.results > 0 then
        local msg = ("AL tests: %d passed, %d failed, %d skipped"):format(
          parsed.passed, parsed.failed, parsed.skipped)
        if parsed.failed > 0 then
          require("al.status").set_compile_result(parsed.failed, 0)
          vim.notify(msg, vim.log.levels.ERROR)
          vim.cmd("copen")
        else
          require("al.status").set_compile_result(0, 0)
          vim.notify(msg, vim.log.levels.INFO)
          altool.close_later(win)
        end
      else
        require("al.status").set_compile_result(ok and 0 or 1, 0)
        if ok then
          vim.notify("AL tests: run finished with no results", vim.log.levels.WARN)
        else
          vim.notify("AL tests: run failed — see the output window", vim.log.levels.ERROR)
        end
      end
    end)
  end)
end

-- Run tests. opts.cursor = true runs the [Test] procedure under the cursor in
-- the codeunit declared by the current buffer; otherwise discovery + pickers.
function M.run(root, opts)
  opts = opts or {}
  root = get_root(root)
  if not root or not need("runtests", "Running tests") then return end

  if opts.cursor then
    local bufnr = vim.api.nvim_get_current_buf()
    local _, decl = require("al.wizard").find_obj_decl(bufnr)
    local kind, id = decl and parse_obj_header(decl)
    if kind ~= "codeunit" then
      vim.notify("AL: the current buffer does not declare a codeunit", vim.log.levels.WARN)
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local method, err = test_method_at(lines, vim.api.nvim_win_get_cursor(0)[1])
    if not method then
      vim.notify("AL: " .. err, vim.log.levels.WARN)
      return
    end
    with_app(root, function() run_tests(root, id, { method }) end)
    return
  end

  M.list(root, function(list)
    pick_codeunit(list, function(cu)
      pick_methods(cu, function(methods) run_tests(root, cu.codeunitId, methods) end)
    end)
  end)
end

-- ── Docs ────────────────────────────────────────────────────────────────────

-- `al doc build` into <root>/.aldoc. The tool emits a docfx-style YAML tree
-- (reference/<app>/toc.yml …); when an index.html exists it is opened in the
-- browser, else the output folder is reported.
function M.doc(root)
  root = get_root(root)
  if not root or not need("doc", "Building docs") then return end
  with_app(root, function(app)
    local out = root .. "/.aldoc"
    altool.run({ "doc", "build", "-s", app, "-o", out, "-c", package_cache(root) },
      { title = "AL doc build", cwd = root }, function(ok, _, _, win)
        if not ok then
          vim.notify("AL: doc build failed — see the output window", vim.log.levels.ERROR)
          return
        end
        altool.close_later(win)
        local index = vim.fn.glob(out .. "/**/index.html", false, true)[1]
        if index then
          platform.open_url("file://" .. index, require("al.cops").get_browser(root))
        else
          vim.notify("AL: reference docs written to " .. out, vim.log.levels.INFO)
        end
      end)
  end)
end

-- ── Run object ──────────────────────────────────────────────────────────────

-- Open the object declared in the current buffer in the BC web client of the
-- picked launch configuration, honouring the alnvim.json browser.
function M.run_object(root)
  root = get_root(root)
  if not root then return end
  local _, decl = require("al.wizard").find_obj_decl(vim.api.nvim_get_current_buf())
  local kind, id = decl and parse_obj_header(decl)
  if not kind then
    vim.notify("AL: no object declaration found in this buffer", vim.log.levels.WARN)
    return
  end
  conn.pick_launch(root, function(cfg)
    local url, err = object_url(cfg, kind, id)
    if not url then
      vim.notify("AL: " .. err, vim.log.levels.WARN)
      return
    end
    vim.notify("AL: opening " .. url, vim.log.levels.INFO)
    platform.open_url(url, require("al.cops").get_browser(root))
  end)
end

-- Internals reached by tests only — never call from plugin code.
M._test = {
  parse_listtests     = parse_listtests,
  parse_runtests      = parse_runtests,
  build_runtests_args = build_runtests_args,
  object_url          = object_url,
  parse_obj_header    = parse_obj_header,
  test_method_at      = test_method_at,
}

return M
