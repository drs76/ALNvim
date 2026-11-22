-- agentic_lsp.warm: the tool's server loads symbols on the first semantic
-- request (6–9s). on_attach used to set "ready" at once, so the first `.`
-- waited the whole load. Now ready follows the warm-up's second answer, or a
-- 30s cap, exactly once.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local A = require("al.agentic_lsp")
local status = require("al.status")

-- Fake client: records requests, answers only when the test says so.
local function fake_client()
  local c = { sent = {}, pending = {}, params = {}, notes = {} }
  function c.notify(self, method, params) self.notes[#self.notes + 1] = { method, params } end
  function c.request(self, method, params, cb, bufnr)
    self.sent[#self.sent + 1] = method
    self.params[#self.params + 1] = params
    self.pending[#self.pending + 1] = cb
    return true, #self.sent
  end
  function c:answer()
    local cb = table.remove(self.pending, 1)
    cb(nil, {}, {})
  end
  return c
end

-- Run fn with vim.defer_fn captured (timers fire only on demand) and
-- status.set_lsp_ready counted.
local function with_fakes(fn)
  local orig_defer, orig_ready = vim.defer_fn, status.set_lsp_ready
  local timers, readies = {}, 0
  -- status' own redraw also defers (<= 100ms); only the cap is captured.
  vim.defer_fn = function(f, ms)
    if ms >= 1000 then timers[#timers + 1] = { f = f, ms = ms } end
  end
  status.set_lsp_ready = function() readies = readies + 1; orig_ready() end
  status.set_lsp_off()
  local okk, err = pcall(fn, timers, function() return readies end)
  vim.defer_fn, status.set_lsp_ready = orig_defer, orig_ready
  if not okk then error(err, 0) end
end

-- A project on disk: warm-up targets need a real file (the server answers a
-- document that is not on disk with nothing and loads nothing).
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
local member_file = root .. "/src/A.Codeunit.al"
vim.fn.writefile({
  'codeunit 50100 "A"', "{", "    procedure Run()", "    var", "        Cust: Record Customer;",
  "    begin", "        Cust.Get('1.5');", "    end;", "}" }, member_file)
local function load(path)
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  return b
end
local buf = load(member_file)

describe("agentic_lsp.warm_position", function()
  it("finds the first member access, skipping namespaces, numbers, strings, comments", function()
    eq({ line = 4, character = 7 }, A.warm_position({
      "namespace Demo.Sales;", "using System.Utilities;", "    X := 1.5 + 2; // Rec.Get",
      "    Y := 'a.b'; for I := 1..9 do", '    SH."No." := 1;' }))
    eq({ line = 0, character = 11 }, A.warm_position({ "        SH." }))
    eq(nil, A.warm_position({ "codeunit 50100 X", "{", "}" }))
  end)
end)

describe("agentic_lsp.warm", function()
  it("is not ready until the second warm-up answer", function()
    with_fakes(function(timers, readies)
      local c = fake_client()
      A.warm(c, buf, root)
      eq(false, status.is_ready())
      eq(true, status.is_loading())
      eq({ "textDocument/hover" }, c.sent)
      c:answer()                                   -- hover
      eq(false, status.is_ready())
      eq({ "textDocument/hover", "textDocument/completion" }, c.sent)
      c:answer()                                   -- completion
      eq(true, status.is_ready())
      eq(1, readies())
      timers[1].f()                                -- cap fires later: no second ready
      eq(1, readies())
    end)
  end)

  it("is ready after the 30s cap when the server never answers", function()
    with_fakes(function(timers, readies)
      local c = fake_client()
      A.warm(c, buf, root)
      eq(1, #timers)
      eq(30000, timers[1].ms)
      eq(false, status.is_ready())
      timers[1].f()
      eq(true, status.is_ready())
      c:answer(); c:answer()                       -- late answers: no second ready
      eq(1, readies())
    end)
  end)

  it("warms once per client", function()
    with_fakes(function(timers)
      local c = fake_client()
      A.warm(c, buf, root)
      A.warm(c, buf, root)
      eq(1, #c.sent)
      eq(1, #timers)
    end)
  end)

  it("hovers the qualifier, then completes just after the member dot", function()
    with_fakes(function()
      local c = fake_client()
      A.warm(c, buf, root)
      c:answer()
      eq({ line = 6, character = 11 }, c.params[1].position)   -- on "Cust"
      eq({ line = 6, character = 13 }, c.params[2].position)   -- after "Cust."
      eq(vim.uri_from_bufnr(buf), c.params[2].textDocument.uri)
      eq(0, #c.notes, "attached buffer: no extra didOpen")
    end)
  end)

  it("warms from a project file when the buffer is not on disk (VimEnter anchor)", function()
    with_fakes(function()
      local anchor = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(anchor, root .. "/_al_startup_.al")
      vim.api.nvim_buf_delete(buf, { force = true })       -- file not loaded in Neovim
      local c = fake_client()
      A.warm(c, anchor, root)
      eq("textDocument/didOpen", c.notes[1][1])
      eq(vim.uri_from_fname(member_file), c.notes[1][2].textDocument.uri)
      ok(c.notes[1][2].textDocument.text:find("Cust.Get", 1, true))
      eq(vim.uri_from_fname(member_file), c.params[1].textDocument.uri)
      c:answer(); c:answer()
      eq("textDocument/didClose", c.notes[2][1])
      eq(true, status.is_ready())
      vim.api.nvim_buf_delete(anchor, { force = true })
      buf = load(member_file)
    end)
  end)

  it("on_attach warms instead of marking ready at once", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
    local src = table.concat(vim.fn.readfile(root .. "/lua/al/agentic_lsp.lua"), "\n")
    local body = src:match("on_attach = function%(client, buf%)(.-)\n    end,")
    ok(body, "on_attach found")
    ok(body:find("M.warm(client, buf, root)", 1, true), "on_attach calls M.warm")
    ok(not body:find("set_lsp_ready", 1, true), "on_attach does not set ready itself")
  end)
end)
