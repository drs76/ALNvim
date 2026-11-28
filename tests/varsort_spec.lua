-- AA0021: sort variable declarations by type (lua/al/fixes.lua).
--
-- The order was checked against CodeCop on tool 30.0.42: the 13 listed types
-- first, in order, then every other type in its original order. An Integer
-- above `array[2] of Record Customer` is flagged, so arrays rank by element.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local CA = require("al.codeactions")
local F = CA._test.fixes

describe("fixes.var_type_rank", function()
  it("ranks the listed types in CodeCop order, the rest after", function()
    local r = F.var_type_rank
    ok(r('    Cust: Record Customer;') < r('    R: Report "Sales Invoice";'))
    ok(r('    R: Report X;') < r('    C: Codeunit "Sales-Post";'))
    ok(r('    P: Page "Customer List";') < r('    Q: Query X;'))
    ok(r('    N: Notification;') < r('    B: BigText;'))
    ok(r('    RR: RecordRef;') < r('    FR: FieldRef;'))
    ok(r('    FR: FieldRef;') < r('    FPB: FilterPageBuilder;'))
    ok(r('    FPB: FilterPageBuilder;') < r('    Qty: Integer;'))
    eq(r('    Qty: Integer;'), r('    Txt: Label \'Record: %1\';'))
  end)

  it("ranks arrays by element type, TestPage as rest, ignores case", function()
    local r = F.var_type_rank
    eq(r('    Custs: array[2] of Record Customer;'), r('    C: Record Customer;'))
    eq(r('    C: RECORD Customer temporary;'), r('    C: Record Customer;'))
    eq(r('    TP: TestPage "Customer Card";'), r('    Qty: Integer;'))
    eq(r('    "Rec: Odd": Integer;'), r('    Qty: Integer;'))
  end)
end)

describe("fixes.sort_var_block", function()
  local src = {
    "codeunit 50100 Probe",                       -- 1
    "{",                                          -- 2
    "    procedure P()",                          -- 3
    "    var",                                    -- 4
    "        Qty: Integer;",                      -- 5
    "        // the customer",                    -- 6
    "        Cust: Record Customer;",             -- 7
    "        Mgt: Codeunit \"Sales-Post\";",      -- 8
    "        Txt: Text;",                         -- 9
    "        Lst: Page \"Customer List\";",       -- 10
    "",                                           -- 11
    "    begin",                                  -- 12
    "    end;",                                   -- 13
    "}",                                          -- 14
  }

  it("moves listed types up, keeps the rest in order, comments attached", function()
    local out = assert(F.sort_var_block(src, 7))
    eq(out, {
      "codeunit 50100 Probe", "{", "    procedure P()", "    var",
      "        // the customer",
      "        Cust: Record Customer;",
      "        Mgt: Codeunit \"Sales-Post\";",
      "        Lst: Page \"Customer List\";",
      "        Qty: Integer;",
      "        Txt: Text;",
      "", "    begin", "    end;", "}",
    })
  end)

  it("refuses a line outside a var block", function()
    local out, err = F.sort_var_block(src, 12)
    eq(out, nil)
    ok(err:find("var block"))
  end)

  it("is the AA0021 cop fix", function()
    local out = F.apply_cop_fix(src, { code = "AA0021", lnum = 6, col = 8, message = "AA0021: x" })
    eq(out and out[6], "        Cust: Record Customer;")
  end)
end)

describe("fixes.sort_var_blocks", function()
  it("sorts every block and leaves compliant ones alone", function()
    local src = {
      "codeunit 50100 Probe",
      "{",
      "    var",
      "        Cust: Record Customer;",
      "        Qty: Integer;",
      "        Mgt: Codeunit \"Sales-Post\";",
      "",
      "    procedure A()",
      "    var",
      "        Cust: Record Customer;",
      "        Qty: Integer;",
      "    begin",
      "    end;",
      "",
      "    procedure B()",
      "    var",
      "        L: List of [Text];",
      "        Custs: array[2] of Record Customer;",
      "    begin",
      "    end;",
      "}",
    }
    local out, changed = F.sort_var_blocks(src)
    eq(changed, 2)
    eq(#out, #src)
    eq({ out[4], out[5], out[6] }, {
      "        Cust: Record Customer;",
      "        Mgt: Codeunit \"Sales-Post\";",
      "        Qty: Integer;",
    })
    eq({ out[10], out[11] }, { src[10], src[11] })
    eq({ out[17], out[18] }, {
      "        Custs: array[2] of Record Customer;",
      "        L: List of [Text];",
    })
    local again, n2 = F.sort_var_blocks(out)
    eq(n2, 0)
    eq(again, out)
  end)

  it("keeps a multi-line declaration together", function()
    local src = {
      "    var",
      "        Txt: Label 'Hello',",
      "            Comment = 'greeting';",
      "        Cust: Record Customer;",
      "    begin",
    }
    local out = F.sort_var_blocks(src)
    eq(out, {
      "    var",
      "        Cust: Record Customer;",
      "        Txt: Label 'Hello',",
      "            Comment = 'greeting';",
      "    begin",
    })
  end)
end)

describe("codeactions: AA0021", function()
  it("offers the sort quick fix on an AA0021 line", function()
    local lines = { "    var", "        Qty: Integer;", "        Cust: Record Customer;", "    begin" }
    local ctx = {
      bufnr = 0, root = "/tmp", lines = lines, row = 3, col0 = 8, line = lines[3],
      visual = false, sel_start = 3, sel_end = 3, bounds = nil,
      diagnostics = { { code = "AA0021", lnum = 2, col = 8, message = "AA0021: x" } },
    }
    local found = {}
    for _, a in ipairs(CA._test.applicable_for(ctx)) do found[a.id] = true end
    ok(found.sort_variables, "sort_variables quick fix")
    ok(found.sort_variables_buffer, "sort_variables_buffer refactor")
  end)
end)
