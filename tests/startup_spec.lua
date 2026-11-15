-- Startup readiness poller (lua/al/startup.lua).
--
-- The VimEnter poll in plugin/al.lua was a repeating uv timer with a
-- vim.schedule_wrap'd callback. While a synchronous call held the main loop the
-- timer kept ticking in libuv and queued one callback per tick; when the loop
-- came back they ran back to back, every one saw "ready", and every one after
-- the first died with "handle 0x… is already closing" — after also starting
-- another background analyze_diagnostics per root.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local startup = require("al.startup")

-- A uv_timer stand-in with luv's semantics: close() on a closing handle raises.
local function fake_timer()
  local t = { starts = 0, stops = 0, closes = 0, closing = false }
  function t:start(delay, rep, cb) self.starts = self.starts + 1; self.delay, self.rep, self.cb = delay, rep, cb end
  function t:stop() self.stops = self.stops + 1 end
  function t:is_closing() return self.closing end
  function t:close()
    if self.closing then error("handle 0xdead is already closing") end
    self.closing = true
    self.closes = self.closes + 1
  end
  return t
end

local function poller(opts)
  local t = fake_timer()
  opts.new_timer = function() return t end
  local h = startup.poll(opts)
  return h, t
end

describe("startup.poll", function()
  it("keeps the original timing", function()
    local _, t = poller({ ready = function() return false end, on_ready = function() end })
    eq(1, t.starts)
    eq({ 2000, 1000 }, { t.delay, t.rep })
  end)

  it("queued ticks after the ready tick neither close again nor re-run on_ready", function()
    local ran = 0
    local h, t = poller({ ready = function() return true end, on_ready = function() ran = ran + 1 end })
    -- Three callbacks queued while the main loop was blocked, now draining.
    for _ = 1, 3 do
      local okay, err = pcall(h.tick)
      ok(okay, err)
    end
    eq(1, ran)
    eq(1, t.closes)
    ok(h.done())
  end)

  it("ready is only consulted while the poll is live", function()
    local asked = 0
    local h = poller({ ready = function() asked = asked + 1; return true end, on_ready = function() end })
    h.tick(); h.tick(); h.tick()
    eq(1, asked)
  end)

  it("times out after max_polls without running on_ready, and stays quiet after", function()
    local ran = 0
    local h, t = poller({ ready = function() return false end, on_ready = function() ran = ran + 1 end, max_polls = 3 })
    for _ = 1, 6 do
      local okay, err = pcall(h.tick)
      ok(okay, err)
    end
    eq(0, ran)
    eq(1, t.closes)
    eq(1, t.stops)
    ok(h.done())
  end)

  it("a tick after the timer was closed elsewhere does not touch the handle", function()
    local h, t = poller({ ready = function() return true end, on_ready = function() end })
    t.closing = true                 -- e.g. closed by shutdown
    local okay, err = pcall(h.tick)
    ok(okay, err)
    eq(0, t.closes)
    eq(0, t.stops)
  end)

  it("with a real uv timer, a blocked main loop drains to exactly one on_ready and no error", function()
    local ran = 0
    startup.poll({ delay_ms = 1, repeat_ms = 1, ready = function() return true end,
                   on_ready = function() ran = ran + 1 end })
    vim.v.errmsg = ""
    -- fast_only: libuv timers tick, scheduled callbacks are not drained.
    vim.wait(60, function() return false end, 5, true)
    -- Now let the queue run (several ticks are waiting).
    vim.wait(30, function() return false end, 5)
    eq(1, ran)
    eq("", vim.v.errmsg)
  end)
end)
