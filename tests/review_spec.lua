-- Regression tests for the 2026-11-27 review (bugs and save-time performance).
-- Each test fails against the code before its fix.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local W       = require("al.wizard")
local compile = require("al.compile")
local host    = require("al.host")
local lsp     = require("al.lsp")
local A       = require("al.agentic_lsp")
local basedef = require("al.basedef")
local status  = require("al.status")

local api = vim.api

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ vim.fn.json_encode({
    name = "T", publisher = "P", version = "1.0.0.0",
    idRanges = { { from = 50100, to = 50149 } },
  }) }, root .. "/app.json")
  return root
end

local function open_al(root, rel, lines)
  local path = root .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf(), path
end

local function quiet(fn)
  local seen, orig = {}, vim.notify
  vim.notify = function(msg, level) seen[#seen + 1] = { msg = msg, level = level } end
  local okk, err = xpcall(fn, debug.traceback)
  vim.notify = orig
  if not okk then error(err, 0) end
  return seen
end

-- No Catnip, whatever the machine has in ~/.config/nvim.
local function native(fn)
  local saved = package.loaded["catnip.ui"]
  local pre = package.preload["catnip.ui"]
  package.loaded["catnip.ui"] = nil
  package.preload["catnip.ui"] = function() error("catnip not installed (test)") end
  host._test.reset()
  local okk, err = xpcall(fn, debug.traceback)
  package.loaded["catnip.ui"], package.preload["catnip.ui"] = saved, pre
  host._test.reset()
  if not okk then error(err, 0) end
end

describe("wizard.organise_file after a move", function()
  it("leaves the buffer writable with a plain :w", function()
    -- nvim_buf_set_name marks the buffer "not edited"; the next :w stopped
    -- with E13 "File exists" until the buffer was written with ! once.
    local root = project()
    local b, path = open_al(root, "Foo.al", { 'codeunit 50100 "Foo"', "{", "}" })
    quiet(function() W.organise_file(b) end)
    local target = root .. "/src/codeunit/Foo.Codeunit.al"
    eq(target, api.nvim_buf_get_name(b))
    eq(0, vim.fn.filereadable(path))
    api.nvim_buf_set_lines(b, 1, 1, false, { "    // edit" })
    local wrote, err = pcall(vim.cmd, "write")
    ok(wrote, "plain :w failed after the move: " .. tostring(err))
    eq("    // edit", vim.fn.readfile(target)[2])
    api.nvim_buf_delete(b, { force = true })
  end)

  it("never replaces another object's file", function()
    -- "Item No." and "Item No" both sanitise to ItemNo.Table.al.
    local root = project()
    local other = root .. "/src/table/ItemNo.Table.al"
    vim.fn.mkdir(root .. "/src/table", "p")
    vim.fn.writefile({ 'table 50101 "Item No"', "{", "    // the other object", "}" }, other)
    local b, path = open_al(root, "New.al", { 'table 50100 "Item No."', "{", "}" })
    local seen = quiet(function() W.organise_file(b) end)
    eq("    // the other object", vim.fn.readfile(other)[3])
    eq(path, api.nvim_buf_get_name(b))
    eq(1, vim.fn.filereadable(path))
    ok(#seen == 1 and seen[1].msg:find("already exists", 1, true), "expected one warning")
    api.nvim_buf_delete(b, { force = true })
  end)
end)

describe("compile diagnostics per project", function()
  local C = compile._test

  local function diag_count(buf)
    return #vim.diagnostic.get(buf, { namespace = C.DIAG_NS })
  end

  it("publishing one project's result keeps the other project's diagnostics", function()
    local ra, rb = project(), project()
    local fa, fb = ra .. "/a.al", rb .. "/b.al"
    vim.fn.writefile({ "x" }, fa); vim.fn.writefile({ "x" }, fb)
    vim.diagnostic.reset(C.DIAG_NS)
    C.push_diagnostics({ { filename = fa, lnum = 1, col = 1, type = "E", text = "AL0001: a" } }, ra)
    C.push_diagnostics({ { filename = fb, lnum = 1, col = 1, type = "E", text = "AL0001: b" } }, rb)
    eq(1, diag_count(vim.fn.bufnr(fa)))
    eq(1, diag_count(vim.fn.bufnr(fb)))
    -- A clean result for B clears B only.
    C.push_diagnostics({}, rb)
    eq(1, diag_count(vim.fn.bufnr(fa)))
    eq(0, diag_count(vim.fn.bufnr(fb)))
    vim.diagnostic.reset(C.DIAG_NS)
  end)

  -- Record every jobstart / jobstop while fn runs.
  local function with_jobs(fn)
    local orig_start, orig_stop = vim.fn.jobstart, vim.fn.jobstop
    local started, stopped, next_id = {}, {}, 100
    vim.fn.jobstart = function(cmd) next_id = next_id + 1; started[#started + 1] = { id = next_id, cmd = cmd }; return next_id end
    vim.fn.jobstop = function(id) stopped[#stopped + 1] = id; return 1 end
    local altool = require("al.altool")
    local orig_avail, orig_bin = altool.available, altool.binary
    altool.available = function() return true end
    altool.binary = function() return "/fake/al" end
    local okk, err = xpcall(function() fn(started, stopped) end, debug.traceback)
    vim.fn.jobstart, vim.fn.jobstop = orig_start, orig_stop
    altool.available, altool.binary = orig_avail, orig_bin
    for k in pairs(C.analyze or {}) do C.analyze[k] = nil end
    if not okk then error(err, 0) end
  end

  it("analysing a second project does not cancel the first", function()
    with_jobs(function(started, stopped)
      local ra, rb = project(), project()
      compile.analyze_diagnostics(ra)
      compile.analyze_diagnostics(rb)
      eq(2, #started)
      eq({}, stopped)
    end)
  end)

  it("the analysis pass writes its package outside the project", function()
    with_jobs(function(started)
      local ra = project()
      compile.analyze_diagnostics(ra)
      local out
      for _, a in ipairs(started[1].cmd) do out = a:match("^/out:(.+)$") or out end
      ok(out, "no /out: argument in " .. table.concat(started[1].cmd, " "))
      ok(out:sub(1, #ra) ~= ra, "/out: points into the project: " .. tostring(out))
    end)
  end)

  it("an explicit build stops the pending and the running analysis of that root", function()
    native(function()
      with_jobs(function(started, stopped)
        local ra, rb = project(), project()
        compile.analyze_diagnostics(ra)          -- running
        compile.analyze_diagnostics(rb)          -- another project: untouched
        compile.analyze_soon(ra, 60000)          -- pending
        local a = C.analyze[ra]
        ok(a.timer ~= nil, "expected a pending timer")
        quiet(function() compile.compile(ra) end)
        eq({ started[1].id }, stopped)
        eq(nil, a.timer)
        -- While the build runs, a save-time analysis of that root is skipped.
        local before = #started
        compile.analyze_diagnostics(ra)
        eq(before, #started)
        compile._builds[ra].sink:close()
        compile._builds[ra], compile._builds[rb] = nil, nil
      end)
    end)
  end)
end)

describe("host sink close_later", function()
  it("does not close a view that a later run opened again", function()
    native(function()
      local orig_defer, timers = vim.defer_fn, {}
      vim.defer_fn = function(f) timers[#timers + 1] = f end
      local sink = host.output({ id = "test.review.close" })
      sink:clear(); sink:open({ focus = false })
      sink:close_later(2500)                      -- run 1 ended
      sink:clear(); sink:open({ focus = false })  -- run 2 started inside the delay
      timers[1]()
      local still = sink:is_open()
      sink:close_later(2500)                      -- run 2 ended: its own timer closes
      timers[2]()
      local closed = not sink:is_open()
      vim.defer_fn = orig_defer
      eq(true, still)
      eq(true, closed)
    end)
  end)
end)

describe("host sink under Catnip", function()
  local FAKE_UI = require("tests.fakes.catnip.ui")

  it("starts on line 1 after clear and follows the tail", function()
    local saved = package.loaded["catnip.ui"]
    FAKE_UI._reset()
    package.loaded["catnip.ui"] = FAKE_UI
    host._test.reset()
    local okk, err = xpcall(function()
      local sink = host.output({ id = "test.review.tail" })
      sink:clear(); sink:open({ focus = false })
      local lines = {}
      for i = 1, 200 do lines[i] = "line " .. i end
      sink:append({ "first" })
      sink:append(lines)
      eq("first", api.nvim_buf_get_lines(sink.buf, 0, 1, false)[1])
      local win = vim.fn.win_findbuf(sink.buf)[1]
      eq(201, api.nvim_win_get_cursor(win)[1])
      sink:clear()
      sink:append({ "again" })
      eq({ "again" }, api.nvim_buf_get_lines(sink.buf, 0, -1, false))
      sink:close()
    end, debug.traceback)
    package.loaded["catnip.ui"] = saved
    host._test.reset()
    if not okk then error(err, 0) end
  end)
end)

describe("lsp.read_app_json", function()
  it("reads an app.json that starts with a byte-order mark", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local f = assert(io.open(root .. "/app.json", "wb"))
    f:write("\239\187\191" .. '{"name":"Bom","version":"1.0.0.0"}')
    f:close()
    local app = lsp.read_app_json(root)
    eq("Bom", app and app.name)
  end)
end)

describe("basedef.open_at", function()
  it("locks a symbol stub but not a file of the project", function()
    local root = project()
    local own = root .. "/src/table/Mine.Table.al"
    vim.fn.mkdir(root .. "/src/table", "p")
    vim.fn.writefile({ 'table 50100 "Mine"', "{", "}" }, own)
    local stub = vim.fn.tempname() .. ".al"
    vim.fn.writefile({ 'table 18 "Customer"', "{", "}" }, stub)

    basedef._test.open_at(own, 1, root)
    local b1 = api.nvim_get_current_buf()
    eq(true, vim.bo[b1].modifiable)
    eq(false, vim.bo[b1].readonly)

    basedef._test.open_at(stub, 1, root)
    local b2 = api.nvim_get_current_buf()
    eq(false, vim.bo[b2].modifiable)
    api.nvim_buf_delete(b1, { force = true })
    api.nvim_buf_delete(b2, { force = true })
  end)
end)

describe("agentic_lsp package watcher", function()
  it("a restart cancels the watcher's pending debounce", function()
    -- The download's own restart left the 3s debounce running, so the server
    -- restarted a second time just after it.
    local root = vim.fn.tempname()
    local t = vim.uv.new_timer()
    local fired = false
    t:start(150, 0, function() fired = true end)
    A.debounces = A.debounces or {}
    A.debounces[root] = t
    local orig = vim.lsp.get_clients
    vim.lsp.get_clients = function() return {} end
    A.restart(root, "test")
    vim.lsp.get_clients = orig
    vim.wait(400)
    A.debounces[root] = nil
    t:close()
    eq(false, fired)
  end)
end)

describe("agentic_lsp.warm", function()
  it("does not close a file the user opened during the warm-up", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/src", "p")
    local file = root .. "/src/A.Codeunit.al"
    vim.fn.writefile({ 'codeunit 50100 "A"', "{", "    procedure Run()", "    var",
      "        Cust: Record Customer;", "    begin", "        Cust.Get('1');", "    end;", "}" }, file)
    local anchor = api.nvim_create_buf(false, false)
    api.nvim_buf_set_name(anchor, root .. "/_al_startup_.al")

    local c = { notes = {}, pending = {}, attached_buffers = {} }
    function c.notify(self, method, params) self.notes[#self.notes + 1] = { method, params } end
    function c.request(self, _, _, cb) self.pending[#self.pending + 1] = cb; return true, #self.pending end

    local orig_defer = vim.defer_fn
    vim.defer_fn = function(f, ms) if ms < 1000 then orig_defer(f, ms) end end
    local okk, err = xpcall(function()
      A.warm(c, anchor, root)
      eq("textDocument/didOpen", c.notes[1][1])
      -- The user opens that file now; Neovim attaches it (its own didOpen).
      local b = vim.fn.bufadd(file)
      vim.fn.bufload(b)
      c.attached_buffers[b] = true
      table.remove(c.pending, 1)(nil, {}, {})
      table.remove(c.pending, 1)(nil, {}, {})
      for _, n in ipairs(c.notes) do
        ok(n[1] ~= "textDocument/didClose", "warm-up closed a document the user has open")
      end
      eq(true, status.is_ready(root))
      api.nvim_buf_delete(b, { force = true })
    end, debug.traceback)
    vim.defer_fn = orig_defer
    api.nvim_buf_delete(anchor, { force = true })
    if not okk then error(err, 0) end
  end)
end)

describe("explorer package cache", function()
  it("honours setup({ packagecachepath })", function()
    local explorer = require("al.explorer")
    local al = require("al")
    local root = project()
    vim.fn.mkdir(root .. "/symbols", "p")
    vim.fn.writefile({ "not a zip" }, root .. "/symbols/Pub_App_1.0.0.0.app")
    local saved = al.config.packagecachepath
    al.config.packagecachepath = "symbols"
    local n = explorer.pending_extracts(root)
    al.config.packagecachepath = saved
    eq(1, n)
  end)
end)
