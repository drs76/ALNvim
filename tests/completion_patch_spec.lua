-- lsp.patch_completion: the one client.request wrapper both AL clients use.
-- Label objects become strings; a quoted filterText on a bare label loses its
-- quotes (cmp scored `Ab` against `"Abs"` at 13.2, against `Abs` at 21.6); a
-- quoted label keeps its quoted filterText.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local lsp = require("al.lsp")

-- Recorded from tool 30.0.42 (shape trimmed): label objects, quoted filterText.
local function recorded()
  return {
    { label = { label = "Abs" }, filterText = '"Abs"', kind = 3 },
    { label = { label = '"Sales Header"' }, filterText = '"Sales Header"', kind = 7 },
    { label = { label = "Count" }, filterText = "Count", kind = 2 },
    { label = { label = "Name" }, filterText = '"Name 2"', kind = 5 },
  }
end

-- Fake client whose request answers synchronously with `response`.
local function fake_client(response)
  local c = { calls = 0 }
  function c.request(self, method, params, cb, bufnr)
    self.calls = self.calls + 1
    cb(nil, vim.deepcopy(response), { method = method })
    return true, 1
  end
  return c
end

local function complete(c)
  local got
  c:request("textDocument/completion", {}, function(err, result) got = result end, 0)
  return got
end

local function check(items)
  eq("Abs", items[1].label)
  eq("Abs", items[1].filterText, "quoted filterText on a bare label")
  eq('"Sales Header"', items[2].label)
  eq('"Sales Header"', items[2].filterText, "quoted label keeps its filterText")
  eq("Count", items[3].filterText)
  eq('"Name 2"', items[4].filterText, "a different quoted name is not the label")
end

describe("lsp.patch_completion", function()
  it("normalises a bare CompletionItem[]", function()
    local c = fake_client(recorded())
    lsp.patch_completion(c)
    check(complete(c))
  end)

  it("normalises a CompletionList { items = ... }", function()
    local c = fake_client({ isIncomplete = false, items = recorded() })
    lsp.patch_completion(c)
    local r = complete(c)
    eq(false, r.isIncomplete)
    check(r.items)
  end)

  it("patches once per client", function()
    local c = fake_client(recorded())
    lsp.patch_completion(c)
    local first = c.request
    lsp.patch_completion(c)
    eq(first, c.request)
    complete(c)
    eq(1, c.calls)
  end)

  it("leaves other methods and errors alone", function()
    local c = fake_client({ contents = "x" })
    lsp.patch_completion(c)
    local got
    c:request("textDocument/hover", {}, function(_, r) got = r end, 0)
    eq({ contents = "x" }, got)
  end)
end)

describe("both AL clients share the patch", function()
  it("agentic_lsp and plugin/al.lua call lsp.patch_completion, no inline copy", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
    for _, f in ipairs({ "lua/al/agentic_lsp.lua", "plugin/al.lua" }) do
      local src = table.concat(vim.fn.readfile(root .. "/" .. f), "\n")
      ok(src:find("patch_completion(client)", 1, true), f .. " calls patch_completion")
      ok(not src:find("item.label.label", 1, true), f .. " has no inline label patch")
    end
  end)
end)
