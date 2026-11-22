-- Host-friendly options and per-root state (docs/catnip-handover.md D5, D6, D8).
--
-- D5  setup({ statusline = false }) sets no window-local statusline, and the
--     status string is per project root, not one table for the session.
-- D6  setup({ format_on_save = false }) sends no formatting request on :w.
-- D8  the project picker asks once per working directory, and never without a UI.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local al     = require("al")
local status = require("al.status")
local lsp    = require("al.lsp")
local api    = vim.api

local function project(dir, name)
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ vim.fn.json_encode({ name = name, publisher = "P", version = "1.0.0.0" }) },
    dir .. "/app.json")
  return dir
end

-- Run fn with config keys overridden, restoring them after.
local function with_config(over, fn)
  local saved = {}
  for k, v in pairs(over) do saved[k] = al.config[k]; al.config[k] = v end
  local okc, err = xpcall(fn, debug.traceback)
  for k in pairs(over) do al.config[k] = saved[k] end
  if not okc then error(err, 0) end
end

-- A fresh window on a fresh named .al buffer with the ftplugin sourced in it.
local function al_buffer(path)
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_name(buf, path)
  vim.wo.statusline = ""
  vim.cmd("runtime! ftplugin/al.lua")
  return buf
end

local tmp = vim.fn.tempname()

-- ── D5 ───────────────────────────────────────────────────────────────────────

describe("statusline option (D5)", function()
  it("statusline = false leaves the window-local statusline empty", function()
    with_config({ statusline = false, colorscheme = false }, function()
      al_buffer(tmp .. "/d5off/x.al")
      -- Nothing window-local: the window shows the global (host's) line.
      eq(vim.go.statusline, vim.wo.statusline)
      ok(not vim.wo.statusline:find("al.status", 1, true), vim.wo.statusline)
    end)
  end)

  it("statusline = true (default) sets ALNvim's statusline", function()
    with_config({ statusline = true, colorscheme = false }, function()
      al_buffer(tmp .. "/d5on/x.al")
      ok(vim.wo.statusline:find("al.status", 1, true), vim.wo.statusline)
    end)
  end)
end)

describe("per-root status (D5)", function()
  it("each buffer shows its own project's state", function()
    if status._test then status._test.reset() end
    local a = project(tmp .. "/stA", "Alpha")
    local b = project(tmp .. "/stB", "Bravo")
    status.set_project("Alpha", "1.0", a)
    status.set_compile_result(2, 0, a)
    status.set_project("Bravo", "2.0", b)   -- attached last
    status.set_lsp_ready(b)

    vim.cmd("enew!")
    api.nvim_buf_set_name(0, a .. "/x.al")
    local sa = status.get()
    vim.cmd("enew!")
    api.nvim_buf_set_name(0, b .. "/y.al")
    local sb = status.get()

    ok(sa:find("Alpha", 1, true), "project A buffer shows: " .. sa)
    ok(not sa:find("Bravo", 1, true), "project A buffer shows B: " .. sa)
    ok(sa:find("2 err", 1, true), sa)
    ok(sb:find("Bravo", 1, true) and sb:find("ready", 1, true), sb)
    ok(not sb:find("err", 1, true), "B shows A's build result: " .. sb)
    eq(true, status.is_ready(b))
    eq(false, status.is_ready(a))
    if status._test then status._test.reset() end
  end)

  it("calls without a root keep the single-project behaviour", function()
    if status._test then status._test.reset() end
    local a = project(tmp .. "/stC", "Charlie")
    status.set_project("Charlie", "1.0", a)
    status.set_lsp_ready()             -- no root: the root updated last
    eq(true, status.is_ready())
    eq(true, status.is_ready(a))
    if status._test then status._test.reset() end
  end)
end)

-- ── D6 ───────────────────────────────────────────────────────────────────────

describe("format_on_save option (D6)", function()
  local function writes_format(value)
    local calls = 0
    with_config({ format_on_save = value, colorscheme = false, organize_imports_on_save = false },
      function()
        local saved_client, saved_format = lsp.client, vim.lsp.buf.format
        lsp.client = function()
          return { id = 1, server_capabilities = { documentFormattingProvider = true } }
        end
        vim.lsp.buf.format = function() calls = calls + 1 end
        local okc, err = pcall(function()
          local buf = al_buffer(tmp .. "/d6/" .. tostring(value) .. ".al")
          api.nvim_exec_autocmds("BufWritePre", { buffer = buf })
        end)
        lsp.client, vim.lsp.buf.format = saved_client, saved_format
        if not okc then error(err, 0) end
      end)
    return calls
  end

  it("format_on_save = false sends no formatting request", function()
    eq(0, writes_format(false))
  end)

  it("format_on_save = true (default) formats on write", function()
    eq(1, writes_format(true))
  end)
end)

-- ── D8 ───────────────────────────────────────────────────────────────────────

describe("project picker (D8)", function()
  -- cwd holding two projects, a scratch buffer outside both, inputlist counted.
  local function picker_env(ui, fn)
    local cwd = tmp .. "/d8" .. (ui and "ui" or "headless")
    project(cwd .. "/one", "One")
    project(cwd .. "/two", "Two")
    local saved = { cwd = vim.fn.getcwd(), input = vim.fn.inputlist, uis = api.nvim_list_uis }
    local asked = 0
    vim.fn.inputlist = function() asked = asked + 1; return 2 end
    if ui then api.nvim_list_uis = function() return { {} } end end
    vim.cmd("enew!")
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    lsp._picked = {}
    local okc, err = xpcall(function() fn(function() return asked end) end, debug.traceback)
    vim.cmd("cd " .. vim.fn.fnameescape(saved.cwd))
    vim.fn.inputlist, api.nvim_list_uis = saved.input, saved.uis
    lsp._picked = {}
    if not okc then error(err, 0) end
  end

  it("without a UI returns nil and never prompts", function()
    picker_env(false, function(asked)
      eq(nil, lsp.get_root())
      eq(0, asked())
    end)
  end)

  it("asks once per working directory, then reuses the answer", function()
    picker_env(true, function(asked)
      local first = lsp.get_root()
      local second = lsp.get_root()
      ok(first and first:match("/two$"), tostring(first))
      eq(first, second)
      eq(1, asked())
    end)
  end)
end)
