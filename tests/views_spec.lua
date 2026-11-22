-- Output views, location lists and the agent terminal on the host adapter
-- (docs/catnip-handover.md W3, W4, W5). Same fake Catnip as host_spec.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

if not vim.g.alnvim_loaded then vim.cmd("runtime plugin/al.lua") end

local host   = require("al.host")
local altool = require("al.altool")
local api    = vim.api

local FAKE_UI  = require("tests.fakes.catnip.ui")
local FAKE_NAV = require("tests.fakes.catnip.navigator")

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
  local orig = vim.notify
  vim.notify = function() end
  local okc, err = xpcall(fn, debug.traceback)
  vim.notify = orig
  if not okc then error(err, 0) end
end

local function clean_layout()
  pcall(vim.cmd, "silent! tabonly!")
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then pcall(api.nvim_win_close, w, true) end
  end
  pcall(vim.cmd, "silent! only!")
  vim.cmd("enew!")
end

local function tiled()
  local n = 0
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == "" then n = n + 1 end
  end
  return n
end

local function project(name)
  local root = vim.fn.tempname() .. "/" .. name
  vim.fn.mkdir(root .. "/src", "p")
  vim.fn.writefile({ vim.fn.json_encode({ name = name, publisher = "P", version = "1.0.0.0" }) },
    root .. "/app.json")
  return root
end

-- `al <args>` never runs: jobstart records and returns an id.
local function with_fake_tool(fn)
  local saved = { a = altool.available, b = altool.binary, h = altool.has,
                  js = vim.fn.jobstart }
  local jobs = {}
  altool.available = function() return true end
  altool.binary    = function() return "/fake/al" end
  altool.has       = function() return true end
  vim.fn.jobstart  = function(cmd, o) jobs[#jobs + 1] = { cmd = cmd, opts = o }; return 7000 + #jobs end
  local okc, err = xpcall(function() fn(jobs) end, debug.traceback)
  altool.available, altool.binary, altool.has = saved.a, saved.b, saved.h
  vim.fn.jobstart = saved.js
  if not okc then error(err, 0) end
end

-- ── W3: tool output ──────────────────────────────────────────────────────────

describe("tool output view (W3)", function()
  it("under Catnip: one view per root, opened without focus, no split", function()
    clean_layout()
    local root = project("w3c")
    with_catnip(true, function()
      with_fake_tool(function(jobs)
        local cur, before = api.nvim_get_current_win(), tiled()
        altool.run({ "publishapp" }, { title = "Publish", cwd = root }, function() end)
        eq(1, #jobs)
        local opens = FAKE_UI._calls("output", "alnvim.tool:" .. root)
        eq(1, #opens, vim.inspect(FAKE_UI.calls))
        eq(false, opens[1].args.focus)
        eq(cur, api.nvim_get_current_win(), "the tool view took focus")
        eq(before, tiled())
        jobs[1].opts.on_stdout(nil, { "Publishing…", "" })
        vim.wait(30, function() return false end)
        ok(vim.tbl_contains(FAKE_UI.get("alnvim.tool:" .. root):lines(), "Publishing…"))
      end)
    end)
    clean_layout()
  end)

  it("natively: centred float, focus kept, output survives close, :ALToolOutput reopens", function()
    clean_layout()
    local root = project("w3n")
    with_catnip(false, function()
      with_fake_tool(function(jobs)
        local cur = api.nvim_get_current_win()
        local sink_seen
        altool.run({ "doc" }, { title = "Doc", cwd = root }, function(_, _, _, sink) sink_seen = sink end)
        eq(cur, api.nvim_get_current_win())
        local sink = host._test.sinks()["alnvim.tool:" .. root]
        ok(sink and sink:is_open(), "no native tool float")
        ok(api.nvim_win_get_config(sink.win).relative ~= "", "not a float")
        jobs[1].opts.on_stdout(nil, { "built", "" })
        jobs[1].opts.on_exit(nil, 0)
        vim.wait(30, function() return false end)
        eq(sink, sink_seen, "on_exit gets the sink")
        sink:close()
        ok(vim.tbl_contains(api.nvim_buf_get_lines(sink.buf, 0, -1, false), "built"),
          "closing the window lost the output")
        quiet(function() vim.cmd("ALToolOutput " ) end)
      end)
    end)
    clean_layout()
  end)

  it("close_later closes a sink after the delay", function()
    local closed = 0
    local sink = setmetatable({ close_later = function(_, ms) closed = ms end }, {})
    altool.close_later(sink, 1234)
    eq(1234, closed)
  end)

  it(":ALInstallDotnetTool logs without entering the window, and the log survives close", function()
    clean_layout()
    with_catnip(false, function()
      local cur = api.nvim_get_current_win()
      local saved = vim.fn.executable
      vim.fn.executable = function(x) if x == "dotnet" then return 0 end return saved(x) end
      local okc, err = pcall(function()
        quiet(function() require("al.install").install_dotnet_tool() end)
      end)
      vim.fn.executable = saved
      ok(okc, err)
      vim.wait(50, function() return false end)
      eq(cur, api.nvim_get_current_win(), "the installer float took focus")
      local sink = host._test.sinks()["alnvim.install"]
      ok(sink, "installer did not use the host view")
      sink:close()
      local text = table.concat(api.nvim_buf_get_lines(sink.buf, 0, -1, false), "\n")
      ok(text:find("'dotnet' not found", 1, true), text)
    end)
    clean_layout()
  end)
end)

-- ── W4: location lists ───────────────────────────────────────────────────────

describe("location lists (W4)", function()
  it("failed tests fill quickfix and open the navigator under Catnip", function()
    clean_layout()
    local root = project("w4")
    local file = root .. "/src/MyTests.Codeunit.al"
    vim.fn.writefile({
      "codeunit 50130 \"My Tests\"", "{", "    Subtype = Test;", "",
      "    [Test]", "    procedure TestX()", "    begin", "    end;", "}",
    }, file)
    with_catnip(true, function()
      with_fake_tool(function(jobs)
        local conn = require("al.connection")
        local saved = { pick = conn.pick_launch, find = require("al.publish").find_app }
        -- Cloud config: no credential prompt (UserPassword would ask for a user).
        conn.pick_launch = function(_, cb) cb({ name = "x", environmentType = "Sandbox",
          environmentName = "x", tenant = "t" }) end
        require("al.publish").find_app = function() return root .. "/P_w4_1.0.0.0.app" end
        local okc, err = pcall(function()
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          api.nvim_win_set_cursor(0, { 6, 4 })
          quiet(function() require("al.tests").run(root, { cursor = true }) end)
          eq(1, #jobs, "runtests did not start")
          -- :ALRunTests! regression: the codeunit id from the buffer reaches the tool.
          eq("50130", jobs[1].cmd[3], vim.inspect(jobs[1].cmd))
          jobs[1].opts.on_stdout(nil, {
            "===== Codeunit 50130 =====", "  FAIL TestX (5ms)", "       boom",
            "Test run completed: 0 passed, 1 failed, 0 skipped.", "" })
          quiet(function()
            jobs[1].opts.on_exit(nil, 1)
            vim.wait(80, function() return #FAKE_NAV.calls > 0 end)
          end)
        end)
        conn.pick_launch, require("al.publish").find_app = saved.pick, saved.find
        ok(okc, err)
        eq(1, #FAKE_NAV.calls, "navigator not opened")
        eq(file, FAKE_NAV.calls[1].items[1].file)
        ok(#vim.fn.getqflist() >= 1, "quickfix not filled")
      end)
    end)
    clean_layout()
  end)

  it("natively the same run opens :copen", function()
    clean_layout()
    local qf_open
    with_catnip(false, function()
      host.locations({ id = "t", title = "T", items = {
        { filename = "/x.al", lnum = 1, col = 1, type = "E", text = "x" } } })
      qf_open = vim.fn.getqflist({ winid = 0 }).winid ~= 0
    end)
    ok(qf_open)
    clean_layout()
  end)
end)

-- ── W5: agent terminal ───────────────────────────────────────────────────────

describe("agent terminal (W5)", function()
  local function with_fake_agent(fn)
    local saved = { ex = vim.fn.executable, js = vim.fn.jobstart, jw = vim.fn.jobwait }
    local starts = 0
    vim.fn.executable = function() return 1 end
    vim.fn.jobstart   = function() starts = starts + 1; return 8800 + starts end
    vim.fn.jobwait    = function(ids) return vim.tbl_map(function() return -1 end, ids) end
    local okc, err = xpcall(function() fn(function() return starts end) end, debug.traceback)
    vim.fn.executable, vim.fn.jobstart, vim.fn.jobwait = saved.ex, saved.js, saved.jw
    vim.cmd("stopinsert")
    if not okc then error(err, 0) end
  end

  it("a second :ALClaude reuses the terminal; window count unchanged", function()
    clean_layout()
    local agent = require("al.agent")
    agent._terms = {}
    with_catnip(false, function()
      with_fake_agent(function(starts)
        local b1 = agent.claude()
        local wins = #api.nvim_tabpage_list_wins(0)
        local b2 = agent.claude()
        eq(b1, b2, "a second terminal was created")
        eq(wins, #api.nvim_tabpage_list_wins(0), "a second window was added")
        eq(1, starts())
        -- Closed window, agent still running: shown again, not restarted.
        api.nvim_win_close(agent._terms[next(agent._terms)].win, true)
        eq(b1, agent.claude())
        eq(1, starts())
        ok(api.nvim_buf_is_valid(b1))
      end)
    end)
    agent._terms = {}
    clean_layout()
  end)

  it("under Catnip the terminal is a float, not a split", function()
    clean_layout()
    local agent = require("al.agent")
    agent._terms = {}
    with_catnip(true, function()
      with_fake_agent(function()
        local before = tiled()
        agent.claude()
        eq(before, tiled())
        ok(api.nvim_win_get_config(0).relative ~= "", "agent window is not a float")
      end)
    end)
    agent._terms = {}
    clean_layout()
  end)
end)
