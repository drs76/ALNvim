-- explorer.lua — the return-on-close watcher.
--
-- The picker itself needs Telescope, which this suite deliberately does not
-- load (it runs with -u NONE and only the repo on the runtimepath), so the
-- picker-building path is exercised manually rather than here. What is covered
-- is the watcher: whether an autocmd is armed, that the config gate is honoured,
-- and that only one file is ever watched at a time.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local E = require("al.explorer")

local function scratch_buf()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x" })
  return b
end

-- Autocmds armed by arm_return, for a given buffer.
local function watchers(buf)
  local out = {}
  for _, ev in ipairs({ "BufDelete", "BufWipeout" }) do
    vim.list_extend(out, vim.api.nvim_get_autocmds({ event = ev, buffer = buf }))
  end
  return out
end

describe("explorer return watcher", function()
  local cfg = require("al").config

  it("arms a watcher on the opened buffer", function()
    cfg.explorer_return = true
    local b = scratch_buf()
    E._test.arm_return(b)
    ok(#watchers(b) > 0, "expected a BufDelete/BufWipeout autocmd on the buffer")
    E._test.disarm_return()
  end)

  it("arms nothing when explorer_return is false", function()
    cfg.explorer_return = false
    local b = scratch_buf()
    E._test.arm_return(b)
    eq(0, #watchers(b))
    cfg.explorer_return = true
  end)

  it("watches only the most recent file", function()
    -- Opening a second file from the picker must not leave the first one armed,
    -- or closing an old buffer would pop the explorer up unexpectedly.
    cfg.explorer_return = true
    local first, second = scratch_buf(), scratch_buf()
    E._test.arm_return(first)
    E._test.arm_return(second)
    eq(0, #watchers(first), "first buffer should have been disarmed")
    ok(#watchers(second) > 0, "second buffer should be armed")
    E._test.disarm_return()
  end)

  it("disarm_return is safe to call twice", function()
    E._test.disarm_return()
    E._test.disarm_return()
  end)

  it("reopen without a cached list warns rather than erroring", function()
    -- _last is nil on a fresh module; M.reopen must not raise.
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
    local okc = pcall(E.reopen)
    vim.notify = orig
    ok(okc, "reopen should not raise")
    if not E._test.last() then
      ok(#msgs > 0 and msgs[1]:find("reopen", 1, true), "expected a notify, got: " .. vim.inspect(msgs))
    end
  end)
end)

describe("explorer cache invalidation", function()
  it("exposes invalidate(), and it clears the cached list", function()
    -- Regression: _last was never invalidated, so return-on-close always
    -- reopened a stale object list — a newly added object was missing, and a
    -- moved declaration sent <CR> to the wrong line.
    eq("function", type(E.invalidate))
    -- Seed a cache first; asserting nil on an already-nil _last passes even
    -- when invalidate() does nothing.
    E._test.set_last({ root = "/tmp/x", entries = { 1 }, sym_count = 0, sort_idx = 1 })
    ok(E._test.last() ~= nil, "precondition: cache seeded")
    E.invalidate()
    eq(nil, E._test.last())
  end)
end)
