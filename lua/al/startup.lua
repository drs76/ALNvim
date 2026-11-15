-- Startup readiness poller.
--
-- plugin/al.lua's VimEnter hook starts the AL language server for every
-- project root under the cwd, then polls until the clients are ready and runs
-- one silent alc pass per root. The poll is a repeating libuv timer whose
-- callback goes through vim.schedule_wrap — and that is the trap: the timer
-- ticks in the libuv loop while a synchronous call (an rg over the symbol
-- cache, a package extraction, the user's own config) holds the main loop, so
-- several callbacks queue up and then run back to back. Each one observed
-- "ready", each one closed the timer ("handle 0x… is already closing") and each
-- one started another analyze_diagnostics per root.
--
-- `M.poll` claims completion exactly once: a shared `done` flag, one cleanup
-- function guarded by `is_closing()`, and the on_ready work runs only after the
-- claim succeeded. Queued callbacks that run afterwards return at the top.

local M = {}

--- Poll `opts.ready()` on a repeating timer until it returns true or
--- `opts.max_polls` ticks pass, then call `opts.on_ready()` (once, and only on
--- success — never on timeout).
---
--- @param opts table
---   ready      fun(): boolean       readiness criterion, evaluated per tick
---   on_ready   fun()                run once after the timer is released
---   max_polls  integer|nil          default 60
---   delay_ms   integer|nil          default 2000
---   repeat_ms  integer|nil          default 1000
---   new_timer  fun(): uv_timer|nil  test seam; default vim.uv.new_timer
--- @return table handle { tick = fun(), done = fun(): boolean }
function M.poll(opts)
  local max_polls = opts.max_polls or 60
  local timer     = (opts.new_timer or vim.uv.new_timer)()
  local polls     = 0
  local done      = false

  -- Idempotent: the first caller wins; a closing or closed handle is left alone.
  local function finish()
    if done then return false end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    return true
  end

  local function tick()
    if done then return end          -- a queued callback that lost the race
    polls = polls + 1
    if polls > max_polls then
      finish()
      return
    end
    if opts.ready() and finish() then
      opts.on_ready()
    end
  end

  timer:start(opts.delay_ms or 2000, opts.repeat_ms or 1000, vim.schedule_wrap(tick))
  return { tick = tick, done = function() return done end }
end

return M
