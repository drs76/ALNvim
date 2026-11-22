-- Completion integration (docs/catnip-handover.md C3, C4, C5, C7), against a
-- fake nvim-cmp (tests/fakes/cmp.lua). One fake instance for the file.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local al       = require("al")
local ids      = require("al.ids")
local cmp_ids  = require("al.cmp_ids")
local lsp      = require("al.lsp")
local explorer = require("al.explorer")
local api      = vim.api

local FAKE_CMP = require("tests.fakes.cmp")

local function absent() error("not installed (test)") end

-- Run fn with nvim-cmp present (the fake) or absent.
local function with_cmp(present, fn)
  local saved, pre = package.loaded["cmp"], package.preload["cmp"]
  FAKE_CMP._reset()
  cmp_ids._test.reset()
  if present then package.loaded["cmp"] = FAKE_CMP
  else package.loaded["cmp"] = nil; package.preload["cmp"] = absent end
  local okc, err = xpcall(fn, debug.traceback)
  package.loaded["cmp"], package.preload["cmp"] = saved, pre
  cmp_ids._test.reset()
  if not okc then error(err, 0) end
end

local function project(name, ranges)
  local root = vim.fn.tempname() .. "/" .. name
  vim.fn.mkdir(root .. "/src", "p")
  vim.fn.writefile({ vim.fn.json_encode({ name = name, publisher = "P", version = "1.0.0.0",
    idRanges = ranges or { { from = 50100, to = 50149 } } }) }, root .. "/app.json")
  return root
end

-- A named AL buffer in the current window, ftplugin sourced.
local function al_buffer(path, lines)
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  api.nvim_buf_set_name(0, path)
  if lines then api.nvim_buf_set_lines(0, 0, -1, false, lines) end
  local saved = al.config.colorscheme
  al.config.colorscheme = false
  vim.cmd("runtime! ftplugin/al.lua")
  al.config.colorscheme = saved
  return api.nvim_get_current_buf()
end

local function has_imap(lhs)
  local m = vim.fn.maparg(lhs, "i", false, true)
  return m and m.buffer == 1
end

-- ── C3: al_ids source ────────────────────────────────────────────────────────

describe("al_ids cmp source (C3)", function()
  local function complete(before, bufnr)
    local got
    cmp_ids.new():complete({ context = { cursor_before_line = before, bufnr = bufnr } },
      function(r) got = r end)
    vim.wait(100, function() return got ~= nil end)
    return got
  end

  it("offers free IDs on an object header, nothing elsewhere, and never runs rg synchronously", function()
    ids.invalidate()
    local root = project("c3")
    vim.fn.writefile({ "table 50100 \"Used\"", "{", "}" }, root .. "/src/Used.Table.al")
    local buf = al_buffer(root .. "/src/New.Table.al")
    local saved_sys, saved_rg = vim.fn.systemlist, explorer.rg_async
    local rg_calls = 0
    vim.fn.systemlist = function() error("synchronous rg from the cmp source") end
    explorer.rg_async = function(cmd, cb)
      rg_calls = rg_calls + 1
      cb(vim.fn.readfile(root .. "/src/Used.Table.al"))
    end
    local okc, err = pcall(function()
      local r = complete("table ", buf)
      ok(#r.items > 0, "no IDs offered")
      eq("50101", r.items[1].label, "the used 50100 must be skipped")
      eq(0, #complete("    Cust.", buf).items)
      eq(0, #complete("procedure Foo", buf).items)
      eq("5012", complete("codeunit 5012", buf).items[1].label:sub(1, 4))
      eq(2, rg_calls, "one async scan per object type, then the cache")
      vim.o.eventignore = "all"
      vim.bo[buf].filetype = "al"
      vim.o.eventignore = ""
      eq(true, cmp_ids.new():is_available())
    end)
    vim.fn.systemlist, explorer.rg_async = saved_sys, saved_rg
    ids.invalidate()
    ok(okc, err)
  end)

  it("the ftplugin drops its <C-Space> map only when al_ids is in this buffer's sources", function()
    local root = project("c3map")
    with_cmp(false, function()
      al_buffer(root .. "/src/A.al")
      ok(has_imap("<C-Space>"), "no cmp: completefunc map expected")
    end)
    with_cmp(true, function()
      FAKE_CMP.sources_for_buffer = { { name = "nvim_lsp" }, { name = "luasnip" } }
      al_buffer(root .. "/src/B.al")
      ok(has_imap("<C-Space>"), "cmp without al_ids: the map must stay")
    end)
    with_cmp(true, function()
      FAKE_CMP.sources_for_buffer = { { name = "nvim_lsp" }, { name = "al_ids" } }
      al_buffer(root .. "/src/C.al")
      ok(not has_imap("<C-Space>"), "cmp with al_ids: <C-Space> belongs to cmp")
      ok(not has_imap("<Nul>"))
      eq(1, #FAKE_CMP._calls("register_source"))
    end)
  end)
end)

-- ── C4: cmp configured once, in setup() ──────────────────────────────────────

describe("cmp configuration (C4)", function()
  it("the ftplugin never calls cmp.setup.buffer", function()
    local root = project("c4")
    with_cmp(true, function()
      al_buffer(root .. "/src/A.al")
      vim.cmd("edit!")   -- the ftplugin re-runs on :e
      eq(0, #FAKE_CMP._calls("setup.buffer"))
    end)
  end)

  it("setup() sets the AL sources once, with al_ids; configure_cmp = false leaves them", function()
    with_cmp(true, function()
      local saved = vim.deepcopy(al.config)
      al.setup({})
      local ft = FAKE_CMP._calls("setup.filetype")
      eq(1, #ft)
      eq("al", ft[1].args.ft)
      local names = vim.tbl_map(function(s) return s.name end, ft[1].args.conf.sources)
      eq({ "nvim_lsp", "al_ids", "luasnip" }, names)
      FAKE_CMP._reset(); cmp_ids._test.reset()
      al.setup({ completion = { configure_cmp = false } })
      eq(0, #FAKE_CMP._calls("setup.filetype"))
      eq(1, #FAKE_CMP._calls("register_source"), "al_ids is registered either way")
      al.config = saved
      require("al.host")._test.reset()
    end)
  end)
end)

-- ── C5: capabilities ─────────────────────────────────────────────────────────

describe("client capabilities (C5)", function()
  local function with_mod(name, mod, fn)
    local saved, pre = package.loaded[name], package.preload[name]
    if mod then package.loaded[name] = mod else package.loaded[name] = nil; package.preload[name] = absent end
    local okc, err = xpcall(fn, debug.traceback)
    package.loaded[name], package.preload[name] = saved, pre
    if not okc then error(err, 0) end
  end

  it("setup value, else cmp_nvim_lsp, else blink.cmp, else Neovim's", function()
    with_mod("cmp_nvim_lsp", nil, function()
      with_mod("blink.cmp", nil, function()
        eq(vim.lsp.protocol.make_client_capabilities(), lsp.capabilities())
        with_mod("blink.cmp", { get_lsp_capabilities = function() return { from = "blink" } end }, function()
          eq({ from = "blink" }, lsp.capabilities())
        end)
      end)
      with_mod("cmp_nvim_lsp", { default_capabilities = function() return { from = "cmp" } end }, function()
        eq({ from = "cmp" }, lsp.capabilities())
        al.config.capabilities = { from = "user" }
        eq({ from = "user" }, lsp.capabilities())
        al.config.capabilities = nil
      end)
    end)
  end)

  it("the tool's language server is started with them", function()
    local A = require("al.agentic_lsp")
    local root = project("c5")
    local saved = { start = vim.lsp.start, bin = A.binary, watch = A.watch_packages, caps = lsp.capabilities }
    local seen
    vim.lsp.start = function(conf) seen = conf; return nil end
    A.binary = function() return "/bin/sh" end
    A.watch_packages = function() end
    lsp.capabilities = function() return { marker = true } end
    local okc, err = pcall(A.start, 0, root)
    vim.lsp.start, A.binary, A.watch_packages, lsp.capabilities = saved.start, saved.bin, saved.watch, saved.caps
    ok(okc, err)
    ok(seen, "vim.lsp.start not called")
    eq({ marker = true }, seen.capabilities)
  end)

  it("the EditorServices start passes them too", function()
    local src = table.concat(vim.fn.readfile("plugin/al.lua"), "\n")
    local call = src:match('vim%.lsp%.start%(%{%s*name%s*=%s*"al_language_server".-%}%)')
    ok(call and call:find("capabilities%s*=%s*require%(\"al%.lsp\"%)%.capabilities%(%)"),
      "plugin/al.lua's vim.lsp.start passes no capabilities")
  end)
end)

-- ── C7: ghost text ───────────────────────────────────────────────────────────

describe("ghost text (C7)", function()
  local ghost = require("al.ghost")

  it("clears when the cmp menu opens", function()
    with_cmp(true, function()
      ghost._test.reset()
      vim.cmd("enew!")
      api.nvim_buf_set_lines(0, 0, -1, false, { "begin", "" })
      ghost._test.hook_cmp()
      ghost._test.show(api.nvim_get_current_buf(), 1, 0, "Rec.Insert();")
      eq(true, ghost._test.visible())
      for _, fn in ipairs(FAKE_CMP.handlers.menu_opened or {}) do fn() end
      eq(false, ghost._test.visible(), "the ghost stayed under the cmp menu")
      ghost._test.reset()
    end)
  end)

  it("sends at most PREFIX_LINES lines above the cursor", function()
    vim.cmd("enew!")
    local lines = {}
    for i = 1, 400 do lines[i] = "    Line" .. i .. " := " .. i .. ";" end
    api.nvim_buf_set_lines(0, 0, -1, false, lines)
    api.nvim_win_set_cursor(0, { 400, 4 })
    local saved = { js = vim.fn.jobstart, mode = vim.fn.mode }
    local payload
    vim.fn.jobstart = function(args)
      for i, a in ipairs(args) do if a == "-d" then payload = args[i + 1] end end
      return 4321
    end
    vim.fn.mode = function() return "i" end
    ghost._test.set_enabled(true)
    local okc, err = pcall(ghost._test.request, api.nvim_get_current_buf())
    ghost._test.set_enabled(false)
    vim.fn.jobstart, vim.fn.mode = saved.js, saved.mode
    ok(okc, err)
    ok(payload, "no request sent")
    local prompt = vim.fn.json_decode(payload).prompt
    local n = #vim.split(prompt, "\n", { plain = true })
    ok(n <= ghost.PREFIX_LINES, ("prompt has %d lines"):format(n))
    ok(not prompt:find("Line1 :=", 1, true), "the top of the file was sent")
  end)
end)
