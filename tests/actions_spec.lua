-- actions.lua — every ACTIONS entry must run a user command that exists.
--
-- The picker's `run` closures call vim.cmd("ALSomething"); when a command is
-- renamed or removed the entry silently becomes "E492: Not an editor command"
-- at pick time. plugin/al.lua is loaded headless so the real command set is
-- the oracle; vim.cmd is stubbed to capture the command instead of running it.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

if not vim.g.alnvim_loaded then vim.cmd("runtime plugin/al.lua") end
-- Agent commands register from their own module on demand.
pcall(require, "al.agent")

local ACTIONS = require("al.actions")._test.ACTIONS

local function captured_command(run)
  local seen
  local orig = vim.cmd
  vim.cmd = setmetatable({}, {
    __call = function(_, c) seen = c end,
    __index = function(_, k) return function() seen = k end end,
  })
  local called, err = pcall(run)
  vim.cmd = orig
  ok(called, err)
  return seen
end

describe("actions.ACTIONS", function()
  it("has a name, desc and run for every entry", function()
    for i, a in ipairs(ACTIONS) do
      ok(type(a.name) == "string" and a.name ~= "", "name #" .. i)
      ok(type(a.desc) == "string" and a.desc ~= "", "desc " .. a.name)
      ok(type(a.run) == "function", "run " .. a.name)
    end
  end)

  it("every run invokes an existing user command", function()
    for _, a in ipairs(ACTIONS) do
      local c = captured_command(a.run)
      ok(type(c) == "string", a.name .. ": run did not call vim.cmd")
      local name = c:match("^%s*([%w]+)")
      eq(2, vim.fn.exists(":" .. name), a.name .. " → :" .. tostring(name))
    end
  end)

  it("names no command twice", function()
    local seen = {}
    for _, a in ipairs(ACTIONS) do
      local c = captured_command(a.run)
      ok(not seen[c], "duplicate action for " .. tostring(c))
      seen[c] = true
    end
  end)

  it("every documented key is bound by ftplugin/al.lua or plugin/al.lua", function()
    local src = table.concat(vim.fn.readfile("ftplugin/al.lua"), "\n")
      .. table.concat(vim.fn.readfile("plugin/al.lua"), "\n")
    for _, a in ipairs(ACTIONS) do
      if a.key and a.key ~= "" then
        ok(src:find('"' .. a.key .. '"', 1, true), a.name .. " key " .. a.key)
      end
    end
  end)
end)

-- The reverse direction: CLAUDE.md's command list is the inventory the docs
-- and the ALActions table are kept against. Commands added without being
-- listed (:ALBuildOutput, :ALCatnipDiagnostics) and aliases left behind after
-- removal (:ALCompileLegacy) both drifted until 2026-11-22.
describe("command inventory", function()
  it("CLAUDE.md lists exactly the registered :AL* commands", function()
    local md = table.concat(vim.fn.readfile("CLAUDE.md"), "\n")
    local line = md:match("\n(`:ALActions`[^\n]+)")
    ok(line, "command list line not found in CLAUDE.md")
    local listed = {}
    for name in line:gmatch("`:(AL%w+)`") do listed[#listed + 1] = name end
    table.sort(listed)
    local registered = {}
    for name in pairs(vim.api.nvim_get_commands({})) do
      if name:match("^AL") then registered[#registered + 1] = name end
    end
    table.sort(registered)
    eq(registered, listed)
  end)

  it("every build command has an ALActions entry", function()
    local seen = {}
    for _, a in ipairs(ACTIONS) do
      local c = captured_command(a.run)
      seen[(c or ""):match("^%s*([%w]+)") or ""] = true
    end
    for _, name in ipairs({ "ALCompile", "ALBuildOutput", "ALCatnipDiagnostics" }) do
      ok(seen[name], name .. " has no ALActions entry")
    end
  end)
end)
