-- Minimal test harness for ALNvim.
--
-- Deliberately dependency-free: it runs under `nvim --headless -u NONE`, so the
-- suite works on a bare checkout with no plugin manager, no plenary, and no
-- network. Run it with tests/run.sh.
--
-- Provides describe / it / eq / ok / errors as globals to the spec files, and
-- exits non-zero when anything fails so CI and `make test` behave.

local M = { passed = 0, failed = 0, failures = {} }

local current = "?"

local function fmt(v)
  return type(v) == "string" and string.format("%q", v) or vim.inspect(v)
end

function M.describe(name, fn)
  current = name
  fn()
end

function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
  else
    M.failed = M.failed + 1
    table.insert(M.failures, ("%s > %s\n      %s"):format(current, name, tostring(err)))
  end
end

-- Deep equality, so table results compare by value.
function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "",
      fmt(expected), fmt(actual)), 2)
  end
end

function M.ok(value, msg)
  if not value then
    error(("%sexpected truthy, got %s"):format(msg and (msg .. ": ") or "", fmt(value)), 2)
  end
end

-- Assert fn() raises. Returns the message so callers can assert on it.
function M.errors(fn, msg)
  local raised, err = pcall(fn)
  if raised then
    error((msg or "expected an error") .. ", but the call succeeded", 2)
  end
  return tostring(err)
end

function M.report()
  local out = io.stderr
  for _, f in ipairs(M.failures) do
    out:write("  FAIL  " .. f .. "\n")
  end
  out:write(("\n%d passed, %d failed\n"):format(M.passed, M.failed))
  return M.failed == 0
end

return M
