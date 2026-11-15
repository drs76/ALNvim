-- update.lua — :ALUpdate safety.
--
-- The command used to run fetch / checkout master / merge --ff-only blind and
-- report only the last command's exit code. Every case here must go red on
-- that behaviour: a dirty tree or a feature branch must stop it before any
-- checkout or merge, a failed fetch must stop the merge, and success may only
-- be claimed after the fast-forward merge itself exits 0.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local U = require("al.update")._test

-- A fake git: `answers` maps the first git subcommand to { out, code }.
-- Every invocation is recorded so tests compare the whole call list.
local function fake(answers)
  local calls = {}
  local run = function(args)
    -- args = { "git", "-C", dir, <subcmd>, ... }
    local sub = args[4]
    table.insert(calls, vim.list_slice(args, 4))
    local a = answers[sub] or { "", 0 }
    return a[1], a[2]
  end
  return run, calls
end

local function subcmds(calls)
  local names = {}
  for _, c in ipairs(calls) do table.insert(names, c[1]) end
  return names
end

local function no_env() return nil end

describe("update.update", function()
  it("refuses on a dirty worktree, before fetch/checkout/merge", function()
    local run, calls = fake({ status = { " M lua/al/update.lua\n", 0 } })
    local res = U.update("/repo", { run = run, getenv = no_env })
    eq(false, res.ok)
    ok(res.msg:find("not clean", 1, true), "reason not named: " .. res.msg)
    eq({ "status" }, subcmds(calls))
  end)

  it("refuses on a feature branch and never checks out master", function()
    local run, calls = fake({
      status = { "", 0 },
      ["rev-parse"] = { "feature/test\n", 0 },
    })
    local res = U.update("/repo", { run = run, getenv = no_env })
    eq(false, res.ok)
    ok(res.msg:find("feature/test", 1, true), "branch not named: " .. res.msg)
    eq({ "status", "rev-parse" }, subcmds(calls))
    for _, c in ipairs(calls) do
      ok(c[1] ~= "checkout" and c[1] ~= "merge", "ran " .. c[1])
    end
  end)

  it("stops after a failed fetch; no merge, no success", function()
    local run, calls = fake({
      ["rev-parse"] = { "master\n", 0 },
      fetch = { "fatal: unable to access 'origin'", 128 },
    })
    local res = U.update("/repo", { run = run, getenv = no_env })
    eq(false, res.ok)
    ok(res.msg:find("fetch", 1, true), "fetch failure not surfaced: " .. res.msg)
    ok(res.msg:find("unable to access", 1, true), "git output missing: " .. res.msg)
    eq({ "status", "rev-parse", "fetch" }, subcmds(calls))
  end)

  it("surfaces a failed fast-forward merge as an error", function()
    local run, calls = fake({
      ["rev-parse"] = { "master\n", 0 },
      merge = { "fatal: Not possible to fast-forward, aborting.", 128 },
    })
    local res = U.update("/repo", { run = run, getenv = no_env })
    eq(false, res.ok)
    ok(res.msg:find("Not possible to fast-forward", 1, true), res.msg)
    eq({ "status", "rev-parse", "fetch", "merge" }, subcmds(calls))
  end)

  it("fast-forwards a clean master in order and reports success", function()
    local run, calls = fake({
      ["rev-parse"] = { "master\n", 0 },
      merge = { "Updating 7b026ef..abc1234\nFast-forward", 0 },
    })
    local res = U.update("/repo", { run = run, getenv = no_env })
    eq(true, res.ok)
    ok(res.msg:find("Fast-forward", 1, true), res.msg)
    eq({
      { "status", "--porcelain" },
      { "rev-parse", "--abbrev-ref", "HEAD" },
      { "fetch", "origin" },
      { "merge", "--ff-only", "origin/master" },
    }, calls)
  end)

  it("accepts main as well as master", function()
    local run, calls = fake({ ["rev-parse"] = { "main\n", 0 } })
    local res = U.update("/repo", { run = run, getenv = no_env })
    eq(true, res.ok)
    eq({ "merge", "--ff-only", "origin/main" }, calls[#calls])
  end)

  it("is a no-op warning when ALNVIM_DEV is set", function()
    local run, calls = fake({ ["rev-parse"] = { "feature/test\n", 0 } })
    local res = U.update("/repo", {
      run = run,
      getenv = function(n) if n == "ALNVIM_DEV" then return "/home/x/ALNvim" end end,
    })
    eq(false, res.ok)
    ok(res.msg:find("ALNVIM_DEV", 1, true), res.msg)
    eq({}, calls, "git was invoked on a development checkout")
  end)
end)

-- One real repository: proves the helper's git invocations are the right ones
-- (a stub cannot catch a mistyped flag). file:// remote, temp dirs only.
describe("update.update against a real repo", function()
  local function sh(cwd, ...)
    local out = vim.fn.system({ "git", "-C", cwd, ... })
    assert(vim.v.shell_error == 0, "git " .. table.concat({ ... }, " ") .. ": " .. out)
    return out
  end
  local function make_pair()
    local base = vim.fn.tempname()
    local origin, clone = base .. "/origin", base .. "/clone"
    vim.fn.mkdir(origin, "p")
    sh(origin, "init", "-q", "-b", "master")
    sh(origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
       "--allow-empty", "-m", "one")
    vim.fn.system({ "git", "clone", "-q", "file://" .. origin, clone })
    assert(vim.v.shell_error == 0)
    sh(origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
       "--allow-empty", "-m", "two")
    return origin, clone
  end

  it("fast-forwards a clean master clone", function()
    local origin, clone = make_pair()
    local res = U.update(clone, { getenv = no_env })
    eq(true, res.ok, res.msg)
    eq(vim.trim(sh(origin, "rev-parse", "HEAD")), vim.trim(sh(clone, "rev-parse", "HEAD")))
  end)

  it("leaves a feature branch and its dirty file untouched", function()
    local _, clone = make_pair()
    sh(clone, "checkout", "-q", "-b", "feature/test")
    vim.fn.writefile({ "x" }, clone .. "/dirty.txt")
    local res = U.update(clone, { getenv = no_env })
    eq(false, res.ok)
    eq("feature/test", vim.trim(sh(clone, "rev-parse", "--abbrev-ref", "HEAD")))
    eq(1, vim.fn.filereadable(clone .. "/dirty.txt"))
  end)
end)
