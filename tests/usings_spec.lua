-- :ALAddUsings without a language server.
--
-- The command requested source.organizeImports from the server; the AL tool's
-- server has no code actions, so it only produced "method textDocument/
-- codeAction is not supported". namespace.lua now finds the referenced objects
-- itself and resolves their namespaces from the symbol packages.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local N = require("al.namespace")._test

local function has(list, kind, name)
  for _, r in ipairs(list) do if r.kind == kind and r.name == name then return true end end
  return false
end

describe("namespace.refs_in", function()
  it("finds variable types, scope references, properties and members", function()
    local refs = N.refs_in({
      'codeunit 50190 "Using Probe"',
      "    procedure Go(var SH: Record \"Sales Header\"; P: Page \"Customer List\")",
      "        Cust: Record Customer temporary;",
      '        Post: Codeunit "Sales-Post";',
      '        DocType: Enum "Sales Document Type";',
      '        Page.Run(Page::"Item Card"); X := Database::Vendor;',
      '        SourceTable = "Gen. Journal Line";',
      '        LookupPageId = "Vendor List";',
      '        TableRelation = "G/L Account"."No." where(Blocked = const(false));',
      '            part(Lines; "Sales Order Subform") { }',
      '        dataitem(Header; "Purchase Header") { }',
      "        Permissions = tabledata \"Cust. Ledger Entry\" = R;",
    })
    for _, want in ipairs({
      { "table", "sales header" }, { "page", "customer list" }, { "table", "customer" },
      { "codeunit", "sales-post" }, { "enum", "sales document type" }, { "page", "item card" },
      { "table", "vendor" }, { "table", "gen. journal line" }, { "page", "vendor list" },
      { "table", "g/l account" }, { "page", "sales order subform" }, { "table", "purchase header" },
      { "table", "cust. ledger entry" },
    }) do
      ok(has(refs, want[1], want[2]), "missing " .. want[1] .. " " .. want[2])
    end
  end)

  it("reads extends and implements in object headers", function()
    local refs = N.refs_in({
      'tableextension 50100 "Cust Ext" extends Customer',
      'codeunit 50101 Impl implements "Dashboard Widget Provider", IOther',
    })
    ok(has(refs, "table", "customer"))
    ok(has(refs, "interface", "dashboard widget provider"))
    ok(has(refs, "interface", "iother"))
  end)

  it("ignores string literals, comments and object headers with an id", function()
    local refs = N.refs_in({
      "page 50184 \"Dashboard Demo\"",
      "        Message('Record Customer is missing');  // Codeunit \"Sales-Post\"",
    })
    eq(false, has(refs, "page", "50184"))
    eq(false, has(refs, "table", "customer"))
    eq(false, has(refs, "codeunit", "sales-post"))
  end)
end)

describe("namespace.index_symbolref", function()
  it("walks nested namespaces and keeps the global ones", function()
    local idx = N.index_symbolref({
      Tables = { { Name = "Old Global" } },
      Namespaces = { { Name = "Microsoft", Namespaces = { { Name = "Sales",
        Namespaces = { { Name = "Customer", Tables = { { Name = "Customer" } },
                                            Pages = { { Name = "Customer List" } } } } } } } },
    })
    eq({ "" }, idx.table["old global"])
    eq({ "Microsoft.Sales.Customer" }, idx.table["customer"])
    eq({ "Microsoft.Sales.Customer" }, idx.page["customer list"])
  end)
end)

describe("namespace.missing_usings", function()
  local idx = {
    table = { customer = { "Microsoft.Sales.Customer" }, ["sales header"] = { "Microsoft.Sales.Document" },
              legacy = { "" }, dup = { "A.One", "B.Two" } },
    codeunit = { registry = { "My.App" } },
  }

  it("adds what is missing, skips own namespace, existing usings and globals", function()
    local add, amb = N.missing_usings({
      "namespace My.App;",
      "using Microsoft.Sales.Document;",
      "codeunit 1 X",
      "    var C: Record Customer; H: Record \"Sales Header\"; R: Codeunit Registry; L: Record Legacy;",
    }, idx)
    eq({ "Microsoft.Sales.Customer" }, add)
    eq(0, #amb)
  end)

  it("reports a name found in several namespaces instead of guessing", function()
    local add, amb = N.missing_usings({ "codeunit 1 X", "    var D: Record Dup;" }, idx)
    eq({}, add)
    eq("dup", amb[1].name)
  end)

  it("matches existing usings case-insensitively", function()
    eq({}, (N.missing_usings({ "using microsoft.sales.customer;", "    var C: Record Customer;" }, idx)))
  end)
end)

describe("namespace.insert_usings", function()
  it("puts a new block after the namespace line with one blank line each side", function()
    eq({ "namespace X;", "", "using A;", "using B;", "", "codeunit 1 C" },
      N.insert_usings({ "namespace X;", "", "codeunit 1 C" }, { "A", "B" }))
  end)

  it("merges into a sorted existing block and keeps it sorted", function()
    eq({ "namespace X;", "", "using A;", "using B;", "using C;", "", "codeunit 1 C" },
      N.insert_usings({ "namespace X;", "", "using A;", "using C;", "", "codeunit 1 C" }, { "B" }))
  end)

  it("appends to an unsorted block without reordering it", function()
    eq({ "using C;", "using A;", "using B;", "codeunit 1 C" },
      N.insert_usings({ "using C;", "using A;", "codeunit 1 C" }, { "B" }))
  end)

  it("goes to the top of a file with no namespace", function()
    eq({ "using A;", "", "codeunit 1 C" }, N.insert_usings({ "codeunit 1 C" }, { "A" }))
  end)
end)

describe("Add missing usings in the code-action menu", function()
  it("is registered as a server-independent source action", function()
    local reg = require("al.codeactions")._test.registry
    local found
    for _, a in ipairs(reg) do if a.id == "add_usings" then found = a end end
    ok(found, "add_usings not registered")
    eq("source.organizeImports", found.kind)
    eq(true, found.applicable({ root = "/p" }))
  end)
end)

-- :ALChangeNamespace — POC → PTE. Moves the project's namespaces from one
-- prefix to another without touching a dependency's namespaces.
describe("namespace.change_ns_lines", function()
  local known = { ["demo.sales"] = true, ["demo.sales.posting"] = true, ["demo"] = true }

  it("moves declarations, usings and qualified references under the old prefix", function()
    local out, n = N.change_ns_lines({
      "namespace Demo.Sales.Posting;",
      "",
      "using Demo.Sales;",
      "using Microsoft.Sales.Customer;",
      "codeunit 50100 Post",
      '    var X: Codeunit Demo.Sales."Sales Helper";',
      "        Y := Demo.Sales.Posting.Engine.Run();",
    }, "Demo", "Contoso.Pte", known)
    eq({
      "namespace Contoso.Pte.Sales.Posting;",
      "",
      "using Contoso.Pte.Sales;",
      "using Microsoft.Sales.Customer;",
      "codeunit 50100 Post",
      '    var X: Codeunit Contoso.Pte.Sales."Sales Helper";',
      "        Y := Contoso.Pte.Sales.Posting.Engine.Run();",
    }, out)
    eq({ decl = 1, using = 1, ref = 2 }, n)
  end)

  it("keeps a dependency's using that shares the prefix", function()
    -- Demo.Core is declared by a dependency, not this project
    local out = N.change_ns_lines({ "namespace Demo.Sales;", "using Demo.Core;" }, "Demo", "New", known)
    eq({ "namespace New.Sales;", "using Demo.Core;" }, out)
  end)

  it("matches case-insensitively and keeps the suffix's spelling", function()
    local out = N.change_ns_lines({ "namespace demo.SALES;", "using DEMO.Sales;" }, "Demo", "New", known)
    eq({ "namespace New.SALES;", "using New.Sales;" }, out)
  end)

  it("does not touch a namespace that only starts with the same letters", function()
    eq(nil, (N.change_ns_lines({ "namespace DemoApp.Sales;" }, "Demo", "New", known)))
  end)

  it("leaves strings, comments, single-segment refs and member access alone", function()
    eq(nil, (N.change_ns_lines({
      "        Message('Demo.Sales.X');  // Demo.Sales.Posting.Engine",
      "        Demo.Run();",                       -- variable named Demo
      "        Rec.Demo.Sales.Foo := 1;",          -- member access
      '        "My Rec".Demo.Sales.Foo := 1;',     -- member access after a quoted name
    }, "Demo", "New", known)))
  end)
end)

describe("namespace change helpers", function()
  it("finds the longest shared prefix of the declared namespaces", function()
    eq("Demo", N.common_prefix({ a = "Demo.Sales", b = "Demo.Purch", c = "Demo" }))
    eq("Demo.Sales", N.common_prefix({ a = "Demo.Sales.A", b = "demo.sales.B" }))
    eq("", N.common_prefix({ a = "A.X", b = "B.X" }))
  end)

  it("validates namespace names", function()
    ok(N.valid_ns("Contoso.Pte_1"))
    for _, bad in ipairs({ "", "A..B", "A.", ".A", "A.1B", "A B", '"A"' }) do
      eq(false, N.valid_ns(bad), bad)
    end
  end)

  it("round-trips BOM, CRLF and the final newline", function()
    local p = vim.fn.tempname()
    local raw = "\239\187\191namespace A;\r\n\r\ncodeunit 1 X\r\n{\r\n}\r\n"
    local f = io.open(p, "wb"); f:write(raw); f:close()
    local lines, fmt = N.read_lines(p)
    eq({ "namespace A;", "", "codeunit 1 X", "{", "}" }, lines)
    lines[1] = "namespace B;"
    N.write_lines(p, lines, fmt)
    f = io.open(p, "rb"); local got = f:read("*a"); f:close()
    eq((raw:gsub("namespace A", "namespace B")), got)
  end)
end)

describe("namespace.plan_change", function()
  it("plans across the project and refuses buffers with unsaved changes", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/src", "p")
    local function put(rel, text)
      local f = io.open(root .. "/" .. rel, "wb"); f:write(text); f:close()
    end
    put("app.json", "{}")
    put("src/A.Codeunit.al", "namespace Demo.Sales;\n\ncodeunit 50100 A\n{\n}\n")
    put("src/B.Codeunit.al", "namespace Demo.Purch;\n\nusing Demo.Sales;\n\ncodeunit 50101 B\n{\n}\n")
    put("src/C.Codeunit.al", "namespace Other;\n\ncodeunit 50102 C\n{\n}\n")
    local NS = require("al.namespace")
    local plan = NS.plan_change(root, "Demo", "Contoso")
    eq(2, #plan.files)
    eq({ decl = 2, using = 1, ref = 0 }, plan.totals)
    eq(2, NS.apply_change(plan))
    local f = io.open(root .. "/src/B.Codeunit.al"); local b = f:read("*a"); f:close()
    eq("namespace Contoso.Purch;\n\nusing Contoso.Sales;\n\ncodeunit 50101 B\n{\n}\n", b)

    -- a modified buffer is reported, not written
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/src/A.Codeunit.al"))
    vim.api.nvim_buf_set_lines(0, 3, 3, false, { "    // edit" })
    plan = NS.plan_change(root, "Contoso", "Fabrikam")
    eq(1, #plan.modified)
    eq(1, #plan.files)          -- B only
    vim.cmd("bwipeout!")
  end)
end)
