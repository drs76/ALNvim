-- codeactions.lua — registry filtering and the picker's LSP merge.
--
-- The agentic LSP has no codeActionProvider; the picker must not send
-- textDocument/codeAction to such a client (the request would sit pending
-- forever and the Lua actions would never show).

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local CA = require("al.codeactions")
local H  = require("al.refactor").helpers

local function ctx_for(lines, row, col0, visual, s, e)
  return {
    bufnr = 0, root = "/tmp", lines = lines, row = row, col0 = col0 or 0,
    line = lines[row] or "", visual = visual or false,
    sel_start = s or row, sel_end = e or row,
    bounds = H.find_proc_bounds(lines, row), diagnostics = {},
  }
end

local function ids(list)
  local out = {}
  for _, a in ipairs(list) do out[#out + 1] = a.id end
  table.sort(out)
  return out
end

describe("codeactions.applicable_for", function()
  local src = {
    'codeunit 1 "X"',                              -- 1
    '{',                                           -- 2
    '    procedure Post(var H: Record "Sales Header")',  -- 3
    '    var',                                     -- 4
    '        Cust: Record Customer;',              -- 5
    '    begin',                                   -- 6
    "        Message('hi');",                      -- 7
    '        H."No." := Cust."No.";',              -- 8
    '    end;',                                    -- 9
    '}',                                           -- 10
  }

  it("offers label extraction only with the cursor inside a string", function()
    local col = src[7]:find("hi") - 1
    local a = ids(CA._test.applicable_for(ctx_for(src, 7, col)))
    ok(vim.tbl_contains(a, "extract_label"), vim.inspect(a))
    ok(vim.tbl_contains(a, "extract_locked_label"), vim.inspect(a))
    local b = ids(CA._test.applicable_for(ctx_for(src, 7, 2)))
    eq(false, vim.tbl_contains(b, "extract_label"), vim.inspect(b))
  end)

  it("offers Validate/Evaluate on an assignment line, not on a call", function()
    local a = ids(CA._test.applicable_for(ctx_for(src, 8, 0)))
    ok(vim.tbl_contains(a, "to_validate") and vim.tbl_contains(a, "to_evaluate"), vim.inspect(a))
    local b = ids(CA._test.applicable_for(ctx_for(src, 7, 2)))
    eq(false, vim.tbl_contains(b, "to_validate"), vim.inspect(b))
  end)

  it("offers make-var-global only inside the local var block", function()
    ok(vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 5, 0))), "make_var_global"))
    eq(false, vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 8, 0))), "make_var_global"))
  end)

  it("offers publishers anywhere in a procedure, not outside", function()
    ok(vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 3, 0))), "add_publishers"))
    ok(vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 8, 0))), "add_publishers"))
    eq(false, vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 1, 0))), "add_publishers"))
  end)

  it("offers extract-procedure only for a visual selection inside the body", function()
    eq(false, vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 8, 0))), "extract_procedure"))
    ok(vim.tbl_contains(ids(CA._test.applicable_for(ctx_for(src, 7, 0, true, 7, 8))), "extract_procedure"))
  end)

  it("filters by kind, matching sub-kinds", function()
    local col = src[7]:find("hi") - 1
    local ctx = ctx_for(src, 7, col)
    local r = ids(CA._test.applicable_for(ctx, "refactor"))
    ok(vim.tbl_contains(r, "extract_label"), vim.inspect(r))
    eq({}, ids(CA._test.applicable_for(ctx, "quickfix")))
    -- the one source action: add missing usings (server-independent)
    eq({ "add_usings" }, ids(CA._test.applicable_for(ctx, "source")))
  end)

  it("register replaces an action with the same id", function()
    local n = #CA._test.registry
    local orig
    for _, a in ipairs(CA._test.registry) do if a.id == "extract_label" then orig = a end end
    CA.register({ id = "extract_label", title = "x", run = function() end })
    eq(n, #CA._test.registry)
    CA.register(orig)
  end)
end)

-- Drive M.pick with a fake AL client; record every request it makes.
local function run_pick(capabilities, opts, server_result)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'codeunit 1 "X"', '{', '    procedure P()', '    begin', "        Message('hi');", '    end;', '}',
  })
  vim.api.nvim_win_set_cursor(0, { 5, 17 })

  local calls, shown = {}, nil
  local fake = {
    offset_encoding = "utf-16",
    server_capabilities = capabilities,
    request = function(_, method, _, cb) calls[#calls + 1] = method; if cb then cb(nil, server_result) end end,
  }
  local lsp = require("al.lsp")
  local o_client, o_root, o_select = lsp.client, lsp.get_root, vim.ui.select
  lsp.client   = function() return fake end
  lsp.get_root = function() return "/tmp" end
  vim.ui.select = function(items, sopts)
    shown = vim.tbl_map(sopts.format_item, items)
    shown.kind = sopts.kind
  end
  local okk, err = pcall(CA.pick, opts)
  lsp.client, lsp.get_root, vim.ui.select = o_client, o_root, o_select
  assert(okk, err)
  return calls, shown
end

describe("codeactions.pick", function()
  it("does not request textDocument/codeAction from a client without codeActionProvider", function()
    local calls, shown = run_pick({}, nil)
    eq({}, calls)
    ok(shown and vim.tbl_contains(shown, "Extract to Label"), vim.inspect(shown))
  end)

  it("merges server actions with an [LSP] prefix when the client has one", function()
    local calls, shown = run_pick({ codeActionProvider = true }, nil,
      { { title = "Fix it", edit = {} } })
    eq({ "textDocument/codeAction" }, calls)
    ok(vim.tbl_contains(shown, "[LSP] Fix it"), vim.inspect(shown))
    ok(vim.tbl_contains(shown, "Extract to Label"), vim.inspect(shown))
  end)

  it("does not call vim.ui.select with kind \"codeaction\"", function()
    -- snacks.nvim's ui_select formats that kind as LSP items and indexes
    -- item.ctx, so the picker crashed with "attempt to index local 'ctx'"
    -- on any config using snacks (found 2026-11-16 under Catnip).
    local _, shown = run_pick({}, nil)
    ok(shown.kind ~= "codeaction", "kind must not be the LSP-reserved one")
  end)

  it("server_supported reflects codeActionProvider", function()
    local lsp = require("al.lsp")
    local o = lsp.client
    lsp.client = function() return { server_capabilities = {} } end
    eq(false, CA.server_supported(0))
    lsp.client = function() return { server_capabilities = { codeActionProvider = true } } end
    eq(true, CA.server_supported(0))
    lsp.client = o
  end)
end)

-- ── Phase 4: diagnostic quick fixes, enum refactor, navigation ───────────────

local F = CA._test.fixes

describe("fixes.parse_call_args", function()
  it("splits arguments on top-level commas only", function()
    local c = F.parse_call_args("Foo(Cust, 'a,b', Qty + 1)")
    eq("Foo", c.name)
    eq(nil, c.qualifier)
    eq({ "Cust", "'a,b'", "Qty + 1" }, vim.tbl_map(function(a) return a.text end, c.args))
  end)

  it("keeps nested calls together and records the qualifier", function()
    local c = F.parse_call_args('    Mgt.Post(Rec, Format(Today(), 0), "Sales Header");', 9)
    eq("Post", c.name)
    eq("Mgt", c.qualifier)
    eq({ "Rec", "Format(Today(), 0)", '"Sales Header"' }, vim.tbl_map(function(a) return a.text end, c.args))
    eq(14, c.args[1].s)  -- 1-based column of the first argument
  end)

  it("picks the call under the column, not the first one", function()
    local line = "    A(1); B(2, 3);"
    local col = line:find("B%(")
    local c = F.parse_call_args(line, col)
    eq("B", c.name)
    eq(2, #c.args)
  end)

  it("returns an empty list for a parameterless call", function()
    eq({}, F.parse_call_args("Foo()").args)
  end)
end)

describe("fixes.create_procedure_text", function()
  it("uses hovered types, var for records, Variant when unknown", function()
    local call = F.parse_call_args("Foo(Cust, 'a,b', Qty + 1, Amount)")
    local params = F.params_from(call, { "Record Customer", nil, nil, "Decimal" })
    eq({
      "    local procedure Foo(var Cust: Record Customer; Arg2: Text; Arg3: Variant; Amount: Decimal)",
      "    begin",
      "        ",
      "    end;",
    }, F.create_procedure_text("Foo", params, "    ", true))
  end)

  it("reads the type out of a hover and drops the namespace", function()
    eq("Record Customer", F.hover_type("```al\n(local) Cust: Record Customer\n```"))
    eq('Record "Sales Header"', F.hover_type('```al\n(parameter) SH: Record Microsoft.Sales.Document."Sales Header" temporary\n```'))
    eq("Code[20]", F.hover_type("```al\n(field) \"No.\": Code[20]\n```"))
    eq(nil, F.hover_type("```al\nTable Customer\n```"))
  end)

  it("inserts after the enclosing procedure", function()
    local src = {
      'codeunit 1 "X"', '{', '    procedure P()', '    begin', '        Foo(1);', '    end;', '}',
    }
    local out = F.insert_procedure(src, 5, { "    local procedure Foo(Arg1: Integer)", "    begin", "        ", "    end;" })
    eq({
      'codeunit 1 "X"', '{', '    procedure P()', '    begin', '        Foo(1);', '    end;',
      '', '    local procedure Foo(Arg1: Integer)', '    begin', '        ', '    end;', '}',
    }, out)
  end)
end)

describe("fixes.cop quick fixes", function()
  local src = {
    'codeunit 1 "X"',            -- 1
    '{',                         -- 2
    '    procedure P()',         -- 3
    '    var',                   -- 4
    '        Unused: Integer;',  -- 5
    '    begin',                 -- 6
    '        Rec.Reset;',        -- 7
    '        Unused := 1;',      -- 8
    '    end;',                  -- 9
    '}',                         -- 10
  }

  it("AA0137 removes the variable and collapses an emptied var block", function()
    local out = F.remove_unused_var(src, 5, "Unused")
    eq({ 'codeunit 1 "X"', '{', '    procedure P()', '    begin', '        Rec.Reset;',
         '        Unused := 1;', '    end;', '}' }, out)
  end)

  it("AA0137 keeps var when other declarations remain", function()
    local s2 = vim.deepcopy(src)
    table.insert(s2, 6, '        Other: Text;')
    local out = F.remove_unused_var(s2, 5, "Unused")
    eq('    var', out[4])
    eq('        Other: Text;', out[5])
  end)

  it("AA0137 drops one name from a comma list", function()
    local s2 = vim.deepcopy(src)
    s2[5] = '        Unused, Kept: Integer;'
    eq('        Kept: Integer;', F.remove_unused_var(s2, 5, "Unused")[5])
  end)

  it("AA0137 refuses a line that is not a declaration", function()
    local out, why = F.remove_unused_var(src, 8, "Unused")
    eq(nil, out)
    ok(why:match("declaration"))
  end)

  it("AA0206 removes the assignment line", function()
    eq('    end;', F.remove_assignment(src, 8)[8])
    local out = F.remove_assignment(src, 7)
    eq(nil, out)
  end)

  it("AA0008 inserts () after the identifier at the column", function()
    local col = src[7]:find("Reset")
    eq('        Rec.Reset();', F.add_parens(src, 7, col, "Reset")[7])
    local out, why = F.add_parens({ "    Rec.Reset();" }, 1, 9, "Reset")
    eq(nil, out)
    ok(why:match("already"))
  end)

  it("apply_cop_fix dispatches on diagnostic.code", function()
    local d = { code = "AA0137", lnum = 4, col = 8, message = "The variable 'Unused' is declared but never used." }
    eq(8, #F.apply_cop_fix(src, d))
  end)
end)

describe("fixes.option_to_enum", function()
  local src = {
    'table 50100 "Doc"',                                            -- 1
    '{',                                                            -- 2
    '    fields',                                                   -- 3
    '    {',                                                        -- 4
    '        field(1; Status; Option)',                             -- 5
    '        {',                                                    -- 6
    "            Caption = 'Status';",                              -- 7
    '            OptionMembers = " ",Open,Released,"Pending Approval";',  -- 8
    "            OptionCaption = ' ,Open,Released,Pending Approval';",    -- 9
    '        }',                                                    -- 10
    '    }',                                                        -- 11
    '}',                                                            -- 12
  }

  it("retypes the field, drops the Option properties and builds the enum", function()
    local out, etext, values = F.option_to_enum(src, 8, { name = "Doc Status", id = 50100, extensible = false })
    eq('        field(1; Status; Enum "Doc Status")', out[5])
    eq("            Caption = 'Status';", out[7])
    eq('        }', out[8])
    eq(4, #values)
    eq({ ord = 3, name = "Pending Approval", caption = "Pending Approval" }, values[4])
    ok(etext:find('enum 50100 "Doc Status"', 1, true), etext)
    ok(etext:find("Extensible = false;", 1, true), etext)
    ok(etext:find('value(0; " ")', 1, true), etext)
    ok(etext:find('value(3; "Pending Approval")', 1, true), etext)
    ok(etext:find("Caption = 'Released';", 1, true), etext)
  end)

  it("refuses a non-Option field", function()
    local s2 = vim.deepcopy(src)
    s2[5] = '        field(1; Status; Code[10])'
    local out, why = F.option_to_enum(s2, 7, { name = "X", id = 1 })
    eq(nil, out)
    ok(why:match("Option"))
  end)

  it("field_block spans header to closing brace", function()
    eq({ s = 5, e = 10, name = "Status" }, F.field_block(src, 9))
    eq(nil, F.field_block(src, 3))
  end)
end)

describe("fixes.navigation patterns", function()
  it("parses subscriber and handler attributes", function()
    eq({ event = "OnAfterPostSalesDoc", element = "" },
       F.parse_subscriber("    [EventSubscriber(ObjectType::Codeunit, Codeunit::\"Sales-Post\", 'OnAfterPostSalesDoc', '', false, false)]"))
    eq({ "MsgHandler", "ConfirmHandler" }, F.parse_handlers("    [HandlerFunctions('MsgHandler,ConfirmHandler')]"))
    eq(nil, F.parse_handlers("    [Test]"))
  end)

  it("finds the record method under the cursor", function()
    local line = "        if Cust.Insert(true) then"
    local rc = F.record_call_at(line, line:find("Insert") - 1)
    eq("Cust", rc.qualifier)
    eq("OnInsert", rc.trigger)
    eq(nil, F.record_call_at("        Cust.Get(No);", 10))
  end)

  it("publisher pattern matches a two-line attribute + procedure, not OnXY", function()
    if vim.fn.executable("rg") ~= 1 then return end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
      'codeunit 80 "Sales-Post"',
      '{',
      '    [IntegrationEvent(false, false)]',
      '    local procedure OnAfterPostSalesDoc(var SalesHeader: Record "Sales Header")',
      '    begin',
      '    end;',
      '',
      '    [IntegrationEvent(false, false)]',
      '    local procedure OnAfterPostSalesDocXY()',
      '    begin',
      '    end;',
      '',
      '    [BusinessEvent(false)]',
      '    procedure OnAfterPostSalesDocDropShipment(SalesHeader: Record "Sales Header")',
      '    begin',
      '    end;',
      '',
      '    procedure OnAfterPostSalesDoc()',   -- no attribute: not a publisher
      '    begin',
      '    end;',
      '}',
    }, dir .. "/SalesPost.Codeunit.al")
    local out = vim.fn.systemlist({ "rg", "-n", "-i", "--multiline", "--no-heading",
      "-e", F.publisher_pattern("OnAfterPostSalesDoc"), dir })
    local procs = vim.tbl_filter(function(l) return l:find("procedure", 1, true) end, out)
    eq(1, #procs, vim.inspect(out))
    ok(procs[1]:match("^.-:4:"), procs[1])
    vim.fn.delete(dir, "rf")
  end)
end)

describe("codeactions quickfix applicability", function()
  it("offers fixes by diagnostic code on the cursor line", function()
    local src = { 'codeunit 1 "X"', '{', '    procedure P()', '    var', '        U: Integer;',
                  '    begin', '        Foo(1);', '    end;', '}' }
    local ctx = ctx_for(src, 7, 8)
    ctx.diagnostics = { { code = "AL0118", lnum = 6, col = 8, message = "The name 'Foo' does not exist" } }
    eq({ "create_procedure" }, ids(CA._test.applicable_for(ctx, "quickfix")))
    ctx.diagnostics = { { code = "AA0137", lnum = 4, col = 8, message = "x" } }
    eq({ "remove_unused_var" }, ids(CA._test.applicable_for(ctx, "quickfix")))
    ctx.diagnostics = {}
    eq({}, ids(CA._test.applicable_for(ctx, "quickfix")))
  end)

  it("offers navigation on subscriber lines and option-to-enum in Option fields", function()
    local sub = { 'codeunit 1 "X"', '{', "    [EventSubscriber(ObjectType::Table, Database::Customer, 'OnAfterInsertEvent', '', false, false)]",
                  '    local procedure H()', '    begin', '    end;', '}' }
    eq({ "find_publisher" }, ids(CA._test.applicable_for(ctx_for(sub, 3, 0), "navigate")))
    local tbl = { 'table 1 T', '{', '    fields', '    {', '        field(1; S; Option)', '        {',
                  '            OptionMembers = A,B;', '        }', '    }', '}' }
    local r = ids(CA._test.applicable_for(ctx_for(tbl, 7, 0), "refactor"))
    ok(vim.tbl_contains(r, "option_to_enum") and vim.tbl_contains(r, "option_to_extensible_enum"), vim.inspect(r))
  end)
end)
