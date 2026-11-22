-- Pickers and the action list for hosts (docs/catnip-handover.md W6).
--
-- setup({ picker = "select" }) sends the simple pickers to vim.ui.select even
-- when Telescope is installed; actions.list() exports the ALActions table for a
-- host's own command palette.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

if not vim.g.alnvim_loaded then vim.cmd("runtime plugin/al.lua") end

local al      = require("al")
local host    = require("al.host")
local actions = require("al.actions")

local function absent() error("not installed (test)") end

-- A Telescope that records pickers.new and opens nothing.
local TEL_NEW = {}
local FAKE_TEL = {
  ["telescope"]               = {},
  ["telescope.pickers"]       = { new = function(_, o)
    TEL_NEW[#TEL_NEW + 1] = o.prompt_title
    return { find = function() end }
  end },
  ["telescope.finders"]       = { new_table = function(t) return t end },
  ["telescope.config"]        = { values = { generic_sorter = function() return {} end } },
  ["telescope.actions"]       = { select_default = { replace = function() end }, close = function() end },
  ["telescope.actions.state"] = { get_selected_entry = function() end },
}

-- Run fn with Telescope present (the fake) or absent, picker = mode, and
-- vim.ui.select recorded. fn(selects) gets the list of select prompts.
local function with_env(telescope, mode, fn)
  local saved_loaded, saved_pre = {}, {}
  for name, mod in pairs(FAKE_TEL) do
    saved_loaded[name], saved_pre[name] = package.loaded[name], package.preload[name]
    if telescope then package.loaded[name] = mod
    else package.loaded[name] = nil; package.preload[name] = absent end
  end
  local saved_mode, saved_select = al.config.picker, vim.ui.select
  local selects = {}
  al.config.picker = mode
  vim.ui.select = function(_, opts) selects[#selects + 1] = opts.prompt end
  for i = #TEL_NEW, 1, -1 do TEL_NEW[i] = nil end
  local okc, err = xpcall(function() fn(selects) end, debug.traceback)
  for name in pairs(FAKE_TEL) do
    package.loaded[name], package.preload[name] = saved_loaded[name], saved_pre[name]
  end
  al.config.picker, vim.ui.select = saved_mode, saved_select
  if not okc then error(err, 0) end
end

describe("picker option (W6)", function()
  it('picker = "select" uses vim.ui.select even with Telescope installed', function()
    with_env(true, "select", function(selects)
      actions.picker()
      eq({}, TEL_NEW, "Telescope was used")
      eq({ "AL Actions" }, selects)
    end)
  end)

  it('picker = "auto" uses Telescope when it is installed, select when not', function()
    with_env(true, "auto", function(selects)
      actions.picker()
      eq({ "AL Actions" }, TEL_NEW)
      eq({}, selects)
    end)
    with_env(false, "auto", function(selects)
      actions.picker()
      eq({}, TEL_NEW)
      eq({ "AL Actions" }, selects)
    end)
  end)

  it('host.use_telescope follows the option for the other simple pickers', function()
    with_env(true, "select", function() eq(false, host.use_telescope()) end)
    with_env(true, "telescope", function() eq(true, host.use_telescope()) end)
    with_env(false, "telescope", function() eq(false, host.use_telescope()) end)
  end)

  it(':ALSelectCops honours picker = "select"', function()
    local root = vim.fn.tempname() .. "/cops"
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ '{"name":"c","publisher":"P","version":"1.0.0.0"}' }, root .. "/app.json")
    local lsp = require("al.lsp")
    local saved = lsp.get_root
    lsp.get_root = function() return root end
    local okc, err = pcall(with_env, true, "select", function(selects)
      require("al.cops").picker()
      eq({}, TEL_NEW, "cops used Telescope")
      eq(1, #selects)
    end)
    lsp.get_root = saved
    ok(okc, err)
  end)
end)

describe("actions.list (W6)", function()
  it("exports name, command, key and desc for every action, and the commands exist", function()
    local list = actions.list()
    eq(#actions._test.ACTIONS, #list)
    for _, a in ipairs(list) do
      ok(type(a.name) == "string" and a.name ~= "", vim.inspect(a))
      ok(type(a.command) == "string" and a.command ~= "", vim.inspect(a))
      ok(type(a.key) == "string" and type(a.desc) == "string", vim.inspect(a))
      local name = a.command:match("^(%w+)")
      eq(2, vim.fn.exists(":" .. name), a.name .. " → :" .. name)
    end
  end)

  it("gives every entry the group of its section", function()
    local seen, order = {}, {}
    for _, a in ipairs(actions.list()) do
      ok(type(a.group) == "string" and a.group ~= "", a.name .. " has no group")
      if not seen[a.group] then seen[a.group] = true; order[#order + 1] = a.group end
    end
    eq("Build & Deploy", order[1])
    ok(seen["Debug"] and seen["Help"], vim.inspect(order))
  end)

  it("keeps arguments in the command and returns copies", function()
    local list = actions.list()
    local found
    for _, a in ipairs(list) do if a.command == "ALCodeAction refactor" then found = a end end
    ok(found, "ALCodeAction refactor missing")
    list[1].name = "changed"
    ok(actions.list()[1].name ~= "changed", "list() hands out the internal table")
  end)
end)
