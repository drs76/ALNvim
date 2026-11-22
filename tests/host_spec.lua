-- Host adapter (lua/al/host.lua) and the compile path on it.
--
-- Catnip is one user's front end; tests/run.sh runs -u NONE, so it is not
-- here. tests/fakes/catnip/{ui,navigator}.lua stand in for it: real floats,
-- every call recorded, and the real View:open behaviour behind D1 kept.
-- One fake instance for the file, like the one real module in a session.
--
-- The rows of docs/catnip-handover.md section 8 covered here: W1, D1–D4 and
-- the window-hook contract.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

if not vim.g.alnvim_loaded then vim.cmd("runtime plugin/al.lua") end

local host    = require("al.host")
local compile = require("al.compile")
local altool  = require("al.altool")
local conn    = require("al.connection")
local al      = require("al")

local FAKE_UI  = require("tests.fakes.catnip.ui")
local FAKE_NAV = require("tests.fakes.catnip.navigator")

local api = vim.api

-- ── Environment helpers ──────────────────────────────────────────────────────

-- Absent means absent even on a machine whose ~/.config/nvim holds the real
-- Catnip: -u NONE still has the config dir on the runtimepath, so require
-- would find it. A failing preload makes require fail first.
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

-- Capture every vim.notify.
local function with_notify(fn)
  local seen, orig = {}, vim.notify
  vim.notify = function(msg, level) seen[#seen + 1] = { msg = msg, level = level } end
  local okc, err = xpcall(fn, debug.traceback)
  vim.notify = orig
  if not okc then error(err, 0) end
  return seen
end

-- The compiler is "found" and jobstart only records: nothing is spawned.
-- Returns the list of started jobs { id, cmd, opts } and stopped job ids.
local function with_fake_jobs(fn)
  local jobs, stopped = {}, {}
  local saved = {
    available = altool.available, binary = altool.binary, has = altool.has,
    jobstart = vim.fn.jobstart, jobstop = vim.fn.jobstop,
  }
  altool.available = function() return true end
  altool.binary    = function() return "/fake/al" end
  altool.has       = function() return true end
  vim.fn.jobstart  = function(cmd, opts)
    local id = 9000 + #jobs + 1
    jobs[#jobs + 1] = { id = id, cmd = cmd, opts = opts }
    return id
  end
  vim.fn.jobstop = function(id) stopped[#stopped + 1] = id; return 1 end
  local okc, err = xpcall(function() fn(jobs, stopped) end, debug.traceback)
  altool.available, altool.binary, altool.has = saved.available, saved.binary, saved.has
  vim.fn.jobstart, vim.fn.jobstop = saved.jobstart, saved.jobstop
  if not okc then error(err, 0) end
end

local function project(name)
  local root = vim.fn.tempname() .. "/" .. (name or "proj")
  vim.fn.mkdir(root .. "/.vscode", "p")
  vim.fn.writefile({ vim.fn.json_encode({ name = name or "proj", publisher = "P",
    version = "1.0.0.0" }) }, root .. "/app.json")
  return root
end

-- Non-floating windows in the current tab.
local function tiled()
  local n = 0
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(w).relative == "" then n = n + 1 end
  end
  return n
end

-- Back to one tab, one window, between tests.
local function clean_layout()
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then pcall(api.nvim_win_close, w, true) end
  end
end

local function wait_scheduled() vim.wait(50, function() return false end) end

-- ── W1: detection ────────────────────────────────────────────────────────────

describe("host detection", function()
  it('ui="auto" without Catnip is native and says nothing (D3)', function()
    with_catnip(false, function()
      local saved = al.config.ui
      local seen = with_notify(function()
        al.setup({ ui = "auto" })
        eq("native", host.name())
        eq("native", host.output({ id = "t.auto" }).host)
      end)
      al.config.ui = saved
      eq({}, seen)
    end)
  end)

  it('ui="auto" with Catnip is catnip', function()
    with_catnip(true, function()
      al.config.ui = "auto"
      eq("catnip", host.name())
    end)
  end)

  it('ui="native" ignores a loaded Catnip', function()
    with_catnip(true, function()
      al.config.ui = "native"
      eq("native", host.name())
      al.config.ui = "auto"
    end)
  end)

  it('ui="catnip" without Catnip warns exactly once, at setup', function()
    with_catnip(false, function()
      local seen = with_notify(function()
        al.setup({ ui = "catnip" })
        host.name()
        host.output({ id = "t.forced" })
        host.name()
      end)
      al.setup({})
      eq(1, #seen, vim.inspect(seen))
      eq(vim.log.levels.WARN, seen[1].level)
      eq("native", (function() host._test.reset(); return host.name() end)())
    end)
  end)
end)

-- ── D3: :ALCompile without Catnip ────────────────────────────────────────────

describe(":ALCompile without Catnip (D3)", function()
  it("opens the native bottom split and notifies nothing", function()
    clean_layout()
    local root = project("d3")
    with_catnip(false, function()
      with_fake_jobs(function(jobs)
        local before = tiled()
        local seen = with_notify(function() vim.cmd("ALCompile " .. root) end)
        wait_scheduled()
        eq({}, seen)
        eq(1, #jobs)
        eq(before + 1, tiled(), "the native build panel is a split")
      end)
    end)
    clean_layout()
  end)
end)

-- ── D1: never switch the user's tab ──────────────────────────────────────────

describe("compile under Catnip (D1)", function()
  it("compiling from tab B while the view is open in tab A stays in tab B", function()
    clean_layout()
    local root = project("d1")
    with_catnip(true, function()
      with_fake_jobs(function()
        vim.cmd("ALCompile " .. root)
        wait_scheduled()
        local tab_a = api.nvim_get_current_tabpage()
        vim.cmd("tabnew")
        local tab_b = api.nvim_get_current_tabpage()
        ok(tab_a ~= tab_b)
        vim.cmd("ALCompile " .. root)
        wait_scheduled()
        eq(tab_b, api.nvim_get_current_tabpage(), "compile switched the user's tab")
        local view = FAKE_UI.get("alnvim.build:" .. root)
        ok(view and view:is_open(), "view not open")
        eq(tab_b, api.nvim_win_get_tabpage(view.win), "view opened in the wrong tab")
      end)
    end)
    clean_layout()
  end)
end)

-- ── D2: one view per project root ────────────────────────────────────────────

describe("compile under Catnip (D2)", function()
  it("two roots compile into two views; neither clear hits the other", function()
    clean_layout()
    local a, b = project("d2a"), project("d2b")
    with_catnip(true, function()
      with_fake_jobs(function(jobs)
        vim.cmd("ALCompile " .. a)
        local after_a = #FAKE_UI.calls
        vim.cmd("ALCompile " .. b)
        wait_scheduled()
        local ida, idb = "alnvim.build:" .. a, "alnvim.build:" .. b
        ok(ida ~= idb)
        ok(#FAKE_UI._calls("output", ida) > 0, "no view for root a")
        ok(#FAKE_UI._calls("output", idb) > 0, "no view for root b")
        -- Nothing root b's compile did touched root a's view.
        for i = after_a + 1, #FAKE_UI.calls do
          local c = FAKE_UI.calls[i]
          ok(not (c.id == ida and (c.fn == "set_lines" or c.fn == "append")),
            "root b's compile wrote to root a's view: " .. vim.inspect(c))
        end
        -- Root a's output still arrives in root a's view while b runs.
        jobs[1].opts.on_stdout(nil, { "a.al(1,1): error AL0118: x", "" })
        wait_scheduled()
        local lines = FAKE_UI.get(ida):lines()
        ok(vim.tbl_contains(lines, "a.al(1,1): error AL0118: x"), vim.inspect(lines))
        ok(not vim.tbl_contains(FAKE_UI.get(idb):lines(), "a.al(1,1): error AL0118: x"))
      end)
    end)
    clean_layout()
  end)

  it("a second compile of the same root stops the first job and drops its output", function()
    clean_layout()
    local root = project("d2c")
    with_catnip(true, function()
      with_fake_jobs(function(jobs, stopped)
        local done = 0
        compile.compile(root, nil, function() done = done + 1 end)
        compile.compile(root, nil, function() done = done + 1 end)
        eq({ jobs[1].id }, stopped)
        -- The stopped job's late output and exit must not reach the new build.
        jobs[1].opts.on_stdout(nil, { "STALE LINE", "" })
        jobs[1].opts.on_exit(nil, 0)
        wait_scheduled()
        local lines = FAKE_UI.get("alnvim.build:" .. root):lines()
        ok(not vim.tbl_contains(lines, "STALE LINE"), vim.inspect(lines))
        eq(0, done, "the stopped build ran on_success")
        jobs[2].opts.on_exit(nil, 0)
        wait_scheduled()
        eq(1, done)
      end)
    end)
    clean_layout()
  end)
end)

-- ── W2: failed build → `d` opens the navigator ───────────────────────────────

describe("compile under Catnip (W2)", function()
  it("a failed build offers d: browse and d opens the navigator on its diagnostics", function()
    clean_layout()
    local root = project("w2")
    with_catnip(true, function()
      with_fake_jobs(function(jobs)
        compile.compile(root)
        jobs[1].opts.on_stdout(nil, { root .. "/a.al(3,4): error AL0118: nope", "" })
        jobs[1].opts.on_exit(nil, 1)
        wait_scheduled()
        local view = FAKE_UI.get("alnvim.build:" .. root)
        local lines = view:lines()
        ok(lines[#lines]:find("d: browse", 1, true), vim.inspect(lines))
        local map = vim.fn.maparg("d", "n", false, true)
        api.nvim_buf_call(view.buf, function() map = vim.fn.maparg("d", "n", false, true) end)
        ok(map.callback, "no buffer-local d")
        map.callback()
        eq(1, #FAKE_NAV.calls)
        eq({ { file = root .. "/a.al", line = 3, col = 4, severity = "E",
               message = "AL0118: nope" } }, FAKE_NAV.calls[1].items)
        -- <CR> on the diagnostic line goes to a managed child tab.
        local cr
        api.nvim_buf_call(view.buf, function() cr = vim.fn.maparg("<CR>", "n", false, true) end)
        local orig = api.nvim_get_current_line
        api.nvim_get_current_line = function() return root .. "/a.al(3,4): error AL0118: nope" end
        local okc, err = pcall(cr.callback)
        api.nvim_get_current_line = orig
        ok(okc, err)
        eq({ file = root .. "/a.al", line = 3, col = 4 }, FAKE_UI._calls("edit_file")[1].args)
      end)
    end)
    clean_layout()
  end)
end)

-- ── D4: every compile path uses the host ─────────────────────────────────────

-- Run fn under the fake host and fake jobs; returns the tiled-window delta and
-- whether the build view for root was created.
local function compile_path_under_catnip(root, fn)
  local delta, made
  clean_layout()
  with_catnip(true, function()
    with_fake_jobs(function(jobs)
      local before = tiled()
      with_notify(fn)
      wait_scheduled()
      delta = tiled() - before
      made = #FAKE_UI._calls("output", "alnvim.build:" .. root) > 0
      ok(#jobs >= 1, "no compile job was started")
    end)
  end)
  clean_layout()
  return delta, made
end

describe("compile paths under Catnip (D4)", function()
  it(":ALPublish builds in the Catnip view, no split", function()
    local root = project("d4pub")
    local saved = conn.pick_launch
    conn.pick_launch = function(_, cb) cb({ name = "x" }) end
    local okc, delta, made = pcall(compile_path_under_catnip, root, function()
      require("al.publish").publish(root)
    end)
    conn.pick_launch = saved
    ok(okc, delta)
    eq(0, delta, "publish opened a split")
    ok(made, "publish did not use the host's build view")
  end)

  it(":ALRunTests' compile-first builds in the Catnip view, no split", function()
    local root = project("d4tests")
    local delta, made = compile_path_under_catnip(root, function()
      require("al.tests").list(root, function() end)
    end)
    eq(0, delta, "tests opened a split")
    ok(made, "tests did not use the host's build view")
  end)

  it(":ALLaunch builds in the Catnip view, no split", function()
    local root = project("d4dbg")
    vim.fn.writefile({ vim.fn.json_encode({ version = "0.2.0", configurations = {
      { name = "cloud", type = "al", request = "launch", environmentType = "Sandbox",
        environmentName = "x", tenant = "t" } } }) }, root .. "/.vscode/launch.json")
    local function auto() return setmetatable({}, { __index = function(t, k)
      local v = {}; rawset(t, k, v); return v end }) end
    local fake_dap = package.loaded["dap"] or {
      listeners = { before = auto(), after = auto() },
      session = function() return nil end,
      adapters = {}, configurations = {},
    }
    fake_dap.run = function() end
    local saved = { dap = package.loaded["dap"], pick = conn.pick_launch,
                    host = require("al.ext").host_cmd }
    package.loaded["dap"] = fake_dap
    conn.pick_launch = function(_, cb) cb({ name = "cloud", type = "al", request = "launch",
      environmentType = "Sandbox", environmentName = "x", tenant = "t" }) end
    require("al.ext").host_cmd = function() return { "dotnet", "/x/Host.dll" } end
    local okc, delta, made = pcall(compile_path_under_catnip, root, function()
      require("al.debug").launch(root)
    end)
    package.loaded["dap"], conn.pick_launch = saved.dap, saved.pick
    require("al.ext").host_cmd = saved.host
    ok(okc, delta)
    eq(0, delta, "debug.launch opened a split")
    ok(made, "debug.launch did not use the host's build view")
  end)
end)

-- ── Locations ────────────────────────────────────────────────────────────────

describe("host.locations", function()
  it("maps quickfix entries to navigator items; project-level ones are counted", function()
    local items, omitted = host.to_items({
      { filename = "/repo/a.al", lnum = 12, col = 3, type = "E", text = "AL0118: unknown" },
      { filename = "/repo/b.al", lnum = 0, col = 0, type = "W", text = "AA0137: unused" },
      { type = "E", text = "AL1022: package not found" },
    })
    eq(1, omitted)
    eq({
      { file = "/repo/a.al", line = 12, col = 3, severity = "E", message = "AL0118: unknown" },
      { file = "/repo/b.al", line = 1, col = 1, severity = "W", message = "AA0137: unused" },
    }, items)
  end)

  it("natively fills quickfix and opens it; never touches Catnip", function()
    clean_layout()
    with_catnip(false, function()
      host.locations({ id = "t.loc", title = "T", items = {
        { filename = "/repo/a.al", lnum = 1, col = 1, type = "E", text = "x" } } })
      eq(1, #vim.fn.getqflist())
      eq(1, vim.fn.getqflist({ winid = 0 }).winid ~= 0 and 1 or 0)
    end)
    clean_layout()
  end)
end)

-- ── Contract: scoped window hooks only ───────────────────────────────────────

describe("window-hook contract", function()
  it("nothing in lua/al registers an unscoped BufDelete/WinClosed/QuitPre", function()
    local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
    local files = vim.fn.glob(repo .. "/lua/al/**/*.lua", false, true)
    vim.list_extend(files, vim.fn.glob(repo .. "/plugin/*.lua", false, true))
    vim.list_extend(files, vim.fn.glob(repo .. "/ftplugin/*.lua", false, true))
    local bad = {}
    for _, f in ipairs(files) do
      local src = table.concat(vim.fn.readfile(f), "\n")
      local pos = 1
      while true do
        local s, e = src:find("nvim_create_autocmd%s*%(", pos)
        if not s then break end
        -- The call's text, up to its matching parenthesis.
        local depth, i = 1, e + 1
        while depth > 0 and i <= #src do
          local ch = src:sub(i, i)
          if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = depth - 1 end
          i = i + 1
        end
        local call = src:sub(s, i - 1)
        for _, ev in ipairs({ "BufDelete", "WinClosed", "QuitPre" }) do
          if call:find('"' .. ev .. '"', 1, true) or call:find("'" .. ev .. "'", 1, true) then
            if not (call:find("buffer%s*=") or call:find("pattern%s*=")) then
              bad[#bad + 1] = vim.fn.fnamemodify(f, ":t") .. ": " .. ev
            end
          end
        end
        pos = i
      end
    end
    eq({}, bad)
  end)
end)
