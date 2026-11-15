-- update.lua — :ALUpdate: fast-forward the running ALNvim checkout.
--
-- The command used to run `git fetch`, `git checkout master`, `git merge
-- --ff-only` blind and report only the last shell error. That could switch a
-- user's branch, run a merge on a dirty tree, and claim success after a failed
-- fetch. This module refuses to change branches at all: it fast-forwards the
-- branch that is checked out, and only when that branch is master/main, the
-- tree is clean, and nothing points at a development checkout.
--
-- Pure: git goes through `opts.run(args) -> out, code` and the environment
-- through `opts.getenv(name)`, so the whole decision table is testable without
-- a repository (tests/update_spec.lua).

local M = {}

local DEFAULT_BRANCHES = { master = true, main = true }

local function default_run(args)
  local out = vim.fn.system(args)
  return out, vim.v.shell_error
end

local function git(run, dir, ...)
  local out, code = run({ "git", "-C", dir, ... })
  return vim.trim(out or ""), code
end

--- Fast-forward `dir`.
--- @param dir string checkout to update
--- @param opts table|nil { run = fn(args)->out,code, getenv = fn(name)->string|nil }
--- @return table { ok = boolean, msg = string, steps = { {name, code, out}... } }
function M.update(dir, opts)
  opts = opts or {}
  local run    = opts.run or default_run
  local getenv = opts.getenv or os.getenv
  local steps  = {}

  local function step(name, ...)
    local out, code = git(run, dir, ...)
    table.insert(steps, { name = name, code = code, out = out })
    return out, code
  end
  local function fail(msg)
    return { ok = false, msg = msg, steps = steps }
  end

  local dev = getenv("ALNVIM_DEV")
  if dev and dev ~= "" then
    return fail(("ALNVIM_DEV is set (%s): this is a development checkout. "
      .. "Update it manually with git; :ALUpdate changes nothing."):format(dev))
  end

  local status, code = step("status", "status", "--porcelain")
  if code ~= 0 then
    return fail("git status failed in " .. dir .. ":\n" .. status)
  end
  if status ~= "" then
    return fail("worktree is not clean in " .. dir
      .. " — commit or stash first; nothing fetched or merged:\n" .. status)
  end

  local branch
  branch, code = step("branch", "rev-parse", "--abbrev-ref", "HEAD")
  if code ~= 0 then
    return fail("could not read the current branch in " .. dir .. ":\n" .. branch)
  end
  if not DEFAULT_BRANCHES[branch] then
    return fail(("checkout is on branch '%s', not master/main; :ALUpdate does not "
      .. "switch branches. Check out master and run it again."):format(branch))
  end

  local fetch
  fetch, code = step("fetch", "fetch", "origin")
  if code ~= 0 then
    return fail("git fetch origin failed; nothing merged:\n" .. fetch)
  end

  local merge
  merge, code = step("merge", "merge", "--ff-only", "origin/" .. branch)
  if code ~= 0 then
    return fail("fast-forward merge of origin/" .. branch .. " failed:\n" .. merge)
  end

  return { ok = true, msg = "updated " .. branch .. ":\n" .. merge, steps = steps }
end

--- The :ALUpdate command body: run and notify.
function M.run_command(dir)
  local res = M.update(dir)
  vim.notify("ALNvim :ALUpdate — " .. res.msg,
    res.ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  return res
end

M._test = { update = M.update, DEFAULT_BRANCHES = DEFAULT_BRANCHES }

return M
