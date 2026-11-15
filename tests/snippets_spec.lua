-- snippets.lua — merging extension, bundled and user snippets.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local S = require("al.snippets")._test

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

local function put(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

-- An extension dir whose package.json lists two AL snippet files and one
-- JSON-language file that must be ignored.
local function fake_ext()
  local ext = vim.fn.tempname()
  put(ext .. "/package.json", vim.json.encode({ contributes = { snippets = {
    { language = "al",   path = "./snippets/table.json" },
    { language = "al",   path = "./snippets/report.json" },
    { language = "json", path = "./snippets/ruleset.json" },
  } } }))
  put(ext .. "/snippets/table.json", [[{
    // comments are allowed, as in VS Code
    "Table": { "prefix": "ttable", "body": ["table ${1:Id} ${2:MyTable}", "{", "}"] },
    "Error": { "prefix": "terror", "body": "Error('ext');" },
  }]])
  put(ext .. "/snippets/report.json",
    [[{ "RepExt": { "prefix": ["treportext", "trepext"], "body": ["reportextension"] } }]])
  put(ext .. "/snippets/ruleset.json", [[{ "Rule": { "prefix": "truleset", "body": "x" } }]])
  return ext
end

local function json_file(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

describe("snippets.merge", function()
  it("lets a later source replace an earlier one by prefix", function()
    local m = S.merge({
      { A = { prefix = "tx", body = "ext" },  B = { prefix = "ty", body = "ext-only" } },
      { C = { prefix = "tx", body = "bundled" } },
      { D = { prefix = "tx", body = { "user", "line" } } },
    })
    eq("user\nline", m.tx.body)
    eq("D", m.tx.name)
    eq("ext-only", m.ty.body)
  end)

  it("registers each prefix of a prefix list", function()
    local m = S.merge({ { X = { prefix = { "ta", "tb" }, body = "b" } } })
    ok(m.ta and m.tb)
  end)
end)

describe("snippets.collect", function()
  it("reads only the extension's AL snippet files", function()
    local files = S.ext_snippet_files(fake_ext())
    eq(2, #files)
    eq({}, S.ext_snippet_files(nil))
  end)

  it("is the union of extension and bundled snippets, bundled winning", function()
    local m = S.collect(fake_ext())
    ok(m.ttable and m.treportext and m.trepext, "extension snippets missing")
    eq(nil, m.truleset)
    -- snippets/al.json defines terror too; the bundled one wins.
    ok(m.terror.body ~= "Error('ext');", "extension snippet beat the bundled one")

    local bundled = {}
    for _, sn in pairs(json_file(repo .. "/snippets/al.json")) do bundled[sn.prefix] = true end
    for _, sn in pairs(json_file(repo .. "/snippets/al-user.json")) do bundled[sn.prefix] = true end
    bundled.ttable, bundled.treportext, bundled.trepext, bundled.terror = true, true, true, true
    eq(vim.tbl_count(bundled), vim.tbl_count(m))
  end)

  it("works with no extension", function()
    local m = S.collect(false)
    ok(m.terror, "bundled snippet missing")
    eq(nil, m.ttable)
  end)
end)

describe("snippets.register", function()
  it("adds the merged set under one key so a reload replaces it", function()
    local calls = {}
    local fake = {
      parser = { parse_snippet = function(ctx, body) return { trig = ctx.trig, body = body } end },
      add_snippets = function(ft, list, opts) calls[#calls + 1] = { ft, #list, opts.key } end,
    }
    local m = S.merge({ { A = { prefix = "ta", body = "a" }, B = { prefix = "tb", body = "b" } } })
    eq(2, S.register(fake, m))
    S.register(fake, m)
    eq({ { "al", 2, "alnvim" }, { "al", 2, "alnvim" } }, calls)
  end)
end)

describe("snippets/al.json", function()
  it("carries no prefix the extension already ships", function()
    -- After the merge an ALNvim copy of tpage would shadow MS's — and go stale
    -- as MS's evolves. Bundled snippets are ALNvim-only.
    local ms = { "ttable", "ttableext", "tpage", "tpageext", "tcodeunit", "treport",
                 "tquery", "tenum", "tenumext", "tinterface", "tif", "tprocedure" }
    local mine = {}
    for _, sn in pairs(json_file(repo .. "/snippets/al.json")) do mine[sn.prefix] = true end
    for _, p in ipairs(ms) do eq(nil, mine[p], p) end
  end)
end)
