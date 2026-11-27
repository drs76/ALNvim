-- Second pass on the review (2026-11-27): background symbol extraction, <CR>
-- from a view opened over a float, and the last views that bypassed the host.
-- Each test fails against the code before its change.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

if not vim.g.alnvim_loaded then vim.cmd("runtime plugin/al.lua") end

local host     = require("al.host")
local explorer = require("al.explorer")
local basedef  = require("al.basedef")
local FAKE_UI  = require("tests.fakes.catnip.ui")
local FAKE_NAV = require("tests.fakes.catnip.navigator")
local api = vim.api

local function absent() error("catnip not installed (test)") end

local function with_catnip(present, fn)
  local saved_ui, saved_nav = package.loaded["catnip.ui"], package.loaded["catnip.navigator"]
  local pre_ui, pre_nav = package.preload["catnip.ui"], package.preload["catnip.navigator"]
  if present then
    FAKE_UI._reset(); FAKE_NAV._reset()
    package.loaded["catnip.ui"], package.loaded["catnip.navigator"] = FAKE_UI, FAKE_NAV
  else
    package.loaded["catnip.ui"], package.loaded["catnip.navigator"] = nil, nil
    package.preload["catnip.ui"], package.preload["catnip.navigator"] = absent, absent
  end
  host._test.reset()
  local okc, err = xpcall(fn, debug.traceback)
  package.loaded["catnip.ui"], package.loaded["catnip.navigator"] = saved_ui, saved_nav
  package.preload["catnip.ui"], package.preload["catnip.navigator"] = pre_ui, pre_nav
  host._test.reset()
  if not okc then error(err, 0) end
end

local function quiet(fn)
  local seen, orig = {}, vim.notify
  vim.notify = function(msg, level) seen[#seen + 1] = { msg = msg, level = level } end
  local okk, err = xpcall(fn, debug.traceback)
  vim.notify = orig
  if not okk then error(err, 0) end
  return seen
end

local function floats()
  return vim.tbl_filter(function(w) return api.nvim_win_get_config(w).relative ~= "" end,
    api.nvim_tabpage_list_wins(0))
end

local function close_floats()
  for _, w in ipairs(floats()) do pcall(api.nvim_win_close, w, true) end
end

describe("explorer.with_search_dirs", function()
  it("extracts in a job and does not block the caller", function()
    if vim.fn.executable("zip") == 0 or vim.fn.executable("unzip") == 0 then return end
    local root = vim.fn.tempname()
    local stage = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.alpackages", "p")
    vim.fn.mkdir(stage .. "/src", "p")
    vim.fn.writefile({ 'table 18 "Customer"', "{", "}" }, stage .. "/src/Customer.Table.al")
    local app = root .. "/.alpackages/Pub_Review" .. vim.fn.getpid() .. "_1.0.0.0.app"
    vim.fn.system({ "sh", "-c", "cd " .. vim.fn.shellescape(stage) .. " && zip -q -r "
      .. vim.fn.shellescape(app) .. " src" })
    eq(1, vim.fn.filereadable(app))

    -- No synchronous shell call may run: that is the freeze.
    local orig_system, sync_calls = vim.fn.system, 0
    vim.fn.system = function(...) sync_calls = sync_calls + 1; return orig_system(...) end
    local got, returned_first
    local okk, err = xpcall(function()
      quiet(function()
        explorer.with_search_dirs(root, function(dirs, _, count) got = { dirs = dirs, count = count } end)
        returned_first = (got == nil)
        vim.wait(5000, function() return got ~= nil end, 20)
      end)
    end, debug.traceback)
    vim.fn.system = orig_system
    if not okk then error(err, 0) end

    eq(true, returned_first)
    eq(0, sync_calls)
    eq(1, got and got.count)
    eq(1, vim.fn.filereadable(got.dirs[2] .. "/src/Customer.Table.al"))
    eq(0, explorer.pending_extracts(root))
    vim.fn.delete(got.dirs[2], "rf")
  end)
end)

describe("host.edit from a view opened over a float", function()
  it("opens the file in an edit window instead of only warning", function()
    with_catnip(true, function()
      close_floats()
      local file = vim.fn.tempname() .. ".al"
      vim.fn.writefile({ "one", "two", "three" }, file)
      local edit_win = api.nvim_get_current_win()
      -- Another float has focus when the view opens (palette, tool output…).
      local other = api.nvim_open_win(api.nvim_create_buf(false, true), true,
        { relative = "editor", width = 10, height = 2, row = 1, col = 1 })
      local sink = host.output({ id = "test.views2.edit" })
      sink:open({ focus = true })
      quiet(function() host.edit(file, 2, 1, { from = sink }) end)
      eq(0, #FAKE_UI._calls("edit_file", "test.views2.edit"))
      eq(file, api.nvim_buf_get_name(api.nvim_win_get_buf(edit_win)))
      eq(2, api.nvim_win_get_cursor(edit_win)[1])
      eq(false, sink:is_open())
      pcall(api.nvim_win_close, other, true)
      vim.cmd("enew!")
    end)
  end)
end)

describe("gd into a symbol stub", function()
  local function stub_file()
    local f = vim.fn.tempname() .. ".al"
    vim.fn.writefile({ 'table 18 "Customer"', "{", "}" }, f)
    return f
  end

  it("under Catnip opens a float and leaves the edit window alone", function()
    with_catnip(true, function()
      close_floats()
      vim.cmd("enew!")
      local edit_win, edit_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
      local f = stub_file()
      basedef._test.open_at(f, 1, "/some/project")
      eq(edit_buf, api.nvim_win_get_buf(edit_win))
      local fl = floats()
      eq(1, #fl)
      eq(f, api.nvim_buf_get_name(api.nvim_win_get_buf(fl[1])))
      eq(false, vim.bo[api.nvim_win_get_buf(fl[1])].modifiable)
      -- A second gd from inside the float reuses it.
      local f2 = stub_file()
      basedef._test.open_at(f2, 1, "/some/project")
      eq(1, #floats())
      eq(f2, api.nvim_buf_get_name(api.nvim_win_get_buf(floats()[1])))
      close_floats()
    end)
  end)

  it("natively opens in the current window, as before", function()
    with_catnip(false, function()
      close_floats()
      vim.cmd("enew!")
      local f = stub_file()
      basedef._test.open_at(f, 1, "/some/project")
      eq(0, #floats())
      eq(f, api.nvim_buf_get_name(0))
      vim.cmd("enew!")
    end)
  end)
end)

describe("quickfix and buffer diagnostics on the host", function()
  local function qf_windows()
    return vim.tbl_filter(function(w) return vim.bo[api.nvim_win_get_buf(w)].buftype == "quickfix" end,
      api.nvim_tabpage_list_wins(0))
  end

  it("show_quickfix uses the navigator under Catnip and leaves the list alone", function()
    with_catnip(true, function()
      local f = vim.fn.tempname() .. ".al"
      vim.fn.writefile({ "x", "y" }, f)
      vim.fn.setqflist({}, " ", { title = "T", items = {
        { filename = f, lnum = 2, col = 1, type = "E", text = "AL0001: boom" } } })
      local nr = vim.fn.getqflist({ nr = 0 }).nr
      host.show_quickfix()
      eq(0, #qf_windows())
      eq(1, #FAKE_NAV.calls)
      eq("T", FAKE_NAV.calls[1].title)
      eq({ file = f, line = 2, col = 1, severity = "E", message = "AL0001: boom" }, FAKE_NAV.calls[1].items[1])
      eq(nr, vim.fn.getqflist({ nr = 0 }).nr)
    end)
  end)

  it("show_quickfix is :copen natively", function()
    with_catnip(false, function()
      host.show_quickfix()
      eq(1, #qf_windows())
      vim.cmd("cclose")
    end)
  end)

  it("buffer_diagnostics lists the buffer under Catnip, and declines natively", function()
    local f = vim.fn.tempname() .. ".al"
    vim.fn.writefile({ "x", "y", "z" }, f)
    vim.cmd("edit " .. vim.fn.fnameescape(f))
    local b = api.nvim_get_current_buf()
    local ns = api.nvim_create_namespace("al_views2_test")
    vim.diagnostic.set(ns, b, {
      { lnum = 2, col = 0, message = "late", severity = vim.diagnostic.severity.WARN },
      { lnum = 0, col = 3, message = "early", severity = vim.diagnostic.severity.ERROR },
    })
    with_catnip(true, function()
      eq(true, host.buffer_diagnostics(0))
      eq(1, #FAKE_NAV.calls)
      eq({ file = f, line = 1, col = 4, severity = "E", message = "early" }, FAKE_NAV.calls[1].items[1])
      eq(3, FAKE_NAV.calls[1].items[2].line)
    end)
    with_catnip(false, function() eq(false, host.buffer_diagnostics(0)) end)
    vim.diagnostic.reset(ns, b)
    api.nvim_buf_delete(b, { force = true })
  end)
end)

describe(":ALInfo", function()
  it("fills an owned view under Catnip", function()
    with_catnip(true, function()
      close_floats()
      quiet(function() vim.cmd("ALInfo") end)
      local opened = FAKE_UI._calls("output", "alnvim.info")
      ok(#opened >= 1, "no alnvim.info view opened")
      local view = FAKE_UI.get("alnvim.info")
      eq("ALNvim info", api.nvim_buf_get_lines(view.buf, 0, 1, false)[1])
      close_floats()
    end)
  end)
end)
