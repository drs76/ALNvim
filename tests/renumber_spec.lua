-- renumber.lua — move object IDs into app.json idRanges, rewrite references.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local R = require("al.renumber")._test

local function obj(typ, id, lnum, path)
  return { type = typ, id = id, lnum = lnum or 1, path = path or ("f" .. id .. typ) }
end

describe("renumber.parse_headers", function()
  it("reads column-1 headers only", function()
    local h = R.parse_headers({
      'table 50100 "My Table"',
      "{",
      "    Permissions = tabledata 50100 = RIMD,",
      "        table 50101 = X;",
      "}",
      'pageextension 70000 "Cust Ext" extends "Customer List"',
      'interface "Not Numbered"',
    })
    eq(#h, 2)
    eq({ h[1].lnum, h[1].type, h[1].id }, { 1, "table", 50100 })
    eq({ h[2].lnum, h[2].type, h[2].id }, { 6, "pageextension", 70000 })
  end)
end)

describe("renumber.plan_ids", function()
  local ranges = { { from = 50100, to = 50102 }, { from = 60000, to = 60009 } }

  it("keeps in-range IDs, moves the rest to the next free ID per type", function()
    local list = { obj("table", 50101), obj("table", 70000), obj("table", 70001),
                   obj("page", 70000) }
    eq(R.plan_ids(list, ranges, false), 4 - 1)
    eq(list[1].new, nil)
    eq(list[2].new, 50100)
    eq(list[3].new, 50102)
    eq(list[4].new, 50100)  -- pages number separately
  end)

  it("continues into the next range when the first is full", function()
    local list = { obj("codeunit", 1), obj("codeunit", 2), obj("codeunit", 3), obj("codeunit", 4) }
    eq(R.plan_ids(list, ranges, false), 4)
    eq({ list[1].new, list[2].new, list[3].new, list[4].new }, { 50100, 50101, 50102, 60000 })
  end)

  it("moves the second object on a duplicated in-range ID", function()
    local list = { obj("table", 50100, 1, "a.al"), obj("table", 50100, 1, "b.al") }
    eq(R.plan_ids(list, ranges, false), 1)
    eq(list[1].new, nil)
    eq(list[2].new, 50101)
  end)

  it("all = true renumbers every object from the start, keeping order", function()
    local list = { obj("table", 60005), obj("table", 50102), obj("table", 90000) }
    R.plan_ids(list, ranges, true)
    eq({ list[2].new, list[1].new, list[3].new }, { 50100, 50101, 50102 })
  end)

  it("refuses when a type runs out of IDs", function()
    local small = { { from = 50100, to = 50100 } }
    local n, err = R.plan_ids({ obj("table", 1), obj("table", 2) }, small, false)
    eq(n, nil)
    ok(err:find("not enough free IDs"))
  end)
end)

describe("renumber.rewrite_lines", function()
  it("rewrites the header and numeric references, nothing in literals or names", function()
    local refs = { table = { [70000] = 50100 }, page = { [70001] = 50101 } }
    local out, nh, nr = R.rewrite_lines({
      "table 70000 Foo",
      "    RunObject = page 70001;",
      "    if Page.RunModal(70001, Cust) = Action::LookupOK then",
      "    Cust: Record 70000;",
      "    tabledata 70000 = RIMD,",
      "    Message('page 70001'); // page 70001",
      '    X: Record "Page 70001 Setup";',
      "    Qty := 70000;",
      "    Rep: Report 70000;",
    }, { [1] = 50100 }, refs)
    eq(nh, 1)
    eq(nr, 3)
    eq(out, {
      "table 50100 Foo",
      "    RunObject = page 50101;",
      "    if Page.RunModal(50101, Cust) = Action::LookupOK then",
      "    Cust: Record 50100;",
      "    tabledata 70000 = RIMD,",
      "    Message('page 70001'); // page 70001",
      '    X: Record "Page 70001 Setup";',
      "    Qty := 70000;",
      "    Rep: Report 70000;",
    })
  end)

  it("does not chain when IDs swap", function()
    local refs = { page = { [50100] = 50101, [50101] = 50100 } }
    local out = R.rewrite_lines({ "    Page.Run(50100); Page.Run(50101);" }, {}, refs)
    eq(out[1], "    Page.Run(50101); Page.Run(50100);")
  end)

  it("returns nil when nothing changes", function()
    eq(R.rewrite_lines({ "codeunit 50100 X" }, {}, {}), nil)
  end)
end)

describe("renumber.ref_map", function()
  it("leaves out an old ID shared by two objects of one type", function()
    local a, b = obj("table", 70000, 1, "a"), obj("table", 70000, 1, "b")
    a.new, b.new = 50100, 50101
    local c = obj("page", 70000); c.new = 50100
    local m = R.ref_map({ a, b, c })
    eq(m.table, nil)
    eq(m.page[70000], 50100)
  end)
end)

describe("renumber.plan (files)", function()
  it("plans across a project tree and refuses without idRanges", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/src", "p")
    vim.fn.writefile({ '{"name":"x","idRanges":[{"from":50100,"to":50149}]}' }, root .. "/app.json")
    vim.fn.writefile({ "table 70000 Foo", "{", "}" }, root .. "/src/Foo.Table.al")
    vim.fn.writefile({ "page 50100 FooList", "{", "    SourceTable = Foo;",
                       "    RunObject = page 50100;", "}" }, root .. "/src/FooList.Page.al")
    vim.fn.writefile({ "codeunit 50100 C", "{", "    var", "        T: Record 70000;", "}" },
      root .. "/src/C.Codeunit.al")
    local P = require("al.renumber")
    local plan = assert(P.plan(root, {}))
    eq(#plan.moves, 1)
    eq(plan.moves[1].new, 50100)
    eq(plan.headers, 1)
    eq(plan.refs, 1)
    eq(#plan.files, 2)
    P.apply(plan)
    eq(vim.fn.readfile(root .. "/src/Foo.Table.al")[1], "table 50100 Foo")
    eq(vim.fn.readfile(root .. "/src/C.Codeunit.al")[4], "        T: Record 50100;")

    vim.fn.writefile({ '{"name":"x"}' }, root .. "/app.json")
    local none, err = P.plan(root, {})
    eq(none, nil)
    ok(err:find("idRanges"))
  end)
end)
