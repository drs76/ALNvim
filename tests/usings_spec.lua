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
