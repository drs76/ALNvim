-- refactor.lua — quote scanning and procedure-boundary detection.
--
-- The double-quote scanner drives a project-wide rename, so getting the wrong
-- span here rewrites the wrong text across every file. It previously scanned
-- leftwards for the nearest quote, which paired a closing quote with the *next*
-- string's opening quote.

local T = require("tests.harness")
local describe, it, eq = T.describe, T.it, T.eq
local R = require("al.refactor")
local RT = R._test

-- Drive the shipped dquoted_id_at_cursor by placing a real cursor, then
-- capturing the name it offers via the rename prompt.
local function id_at(line, col0)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, col0 })

  local captured, fell_back = nil, false
  local o_input, o_rename = vim.ui.input, vim.lsp.buf.rename
  local o_root = require("al.lsp").get_root
  require("al.lsp").get_root = function() return "/tmp" end
  vim.ui.input = function(opts) captured = opts.prompt end
  vim.lsp.buf.rename = function() fell_back = true end
  pcall(R.rename_object)
  vim.ui.input, vim.lsp.buf.rename = o_input, o_rename
  require("al.lsp").get_root = o_root

  if fell_back then return nil end
  return captured and captured:match('^Rename "(.*)" to: $')
end

describe("refactor.dquoted_id_at_cursor", function()
  local L = [[    Cust.Get("Foo Bar"); Other("Baz Qux");]]

  -- Positions are derived, not hard-coded: literal columns silently point at
  -- the wrong character the moment the fixture's indentation changes, which
  -- turns the regression case below into a test of nothing.
  local q = {}
  do
    local i = 0
    while true do
      local p = L:find('"', i + 1, true)
      if not p then break end
      q[#q + 1] = p - 1   -- 0-based cursor column
      i = p
    end
  end
  local open1, close1, open2 = q[1], q[2], q[3]
  eq(4, #q, "fixture must contain exactly two quoted identifiers")

  it("finds the identifier when the cursor is inside it", function()
    eq("Foo Bar", id_at(L, open1 + 1))
  end)

  it("finds it with the cursor on the opening quote", function()
    eq("Foo Bar", id_at(L, open1))
  end)

  it("finds it with the cursor on the closing quote", function()
    -- Regression: scanning leftwards for the nearest quote paired this closing
    -- quote with the *next* string's opening quote and returned '); Other(',
    -- which is then what the project-wide rename offered to replace.
    eq("Foo Bar", id_at(L, close1))
  end)

  it("returns nothing between two strings", function()
    eq(nil, id_at(L, close1 + 2))
  end)

  it("finds the second identifier", function()
    eq("Baz Qux", id_at(L, open2 + 1))
  end)

  it("returns nothing on a line with no quoted identifier", function()
    eq(nil, id_at("    x := 1;", 6))
  end)
end)

describe("refactor.find_quoted_string", function()
  local f = RT.find_quoted_string

  it("returns the string containing the cursor", function()
    eq("hello", f("  Message('hello');", 13))
  end)

  it("returns nil outside any string", function()
    eq(nil, f("  Message('hello');", 2))
  end)

  it("treats '' as an escaped quote, not a terminator", function()
    eq("it''s", f("  Message('it''s');", 14))
  end)

  it("picks the second of two strings", function()
    eq("b", f("  F('a', 'b');", 11))
  end)

  it("returns nil for an unterminated string", function()
    eq(nil, f("  Message('oops;", 13))
  end)
end)

describe("refactor.find_proc_bounds", function()
  local lines = {
    'codeunit 50000 "X"',            -- 1
    '{',                             -- 2
    '    procedure Run()',           -- 3
    '    var',                       -- 4
    '        i: Integer;',           -- 5
    '    begin',                     -- 6
    '        i := 1;',               -- 7
    '    end;',                      -- 8
    '}',                             -- 9
  }

  it("locates header, var, begin and end (all 1-based)", function()
    eq({ hdr = 3, var = 4, beg = 6, fin = 8 }, RT.find_proc_bounds(lines, 7))
  end)

  it("returns nil outside any procedure", function()
    eq(nil, RT.find_proc_bounds(lines, 1))
  end)

  it("handles a procedure with no var block", function()
    local l = { 'codeunit 1 "X"', '{', '    procedure P()', '    begin', '        x();', '    end;', '}' }
    eq({ hdr = 3, var = nil, beg = 4, fin = 6 }, RT.find_proc_bounds(l, 5))
  end)

  it("counts a case/of as an extra begin so its end does not close the proc", function()
    local l = {
      'codeunit 1 "X"', '{', '    procedure P()', '    begin',
      '        case x of', '            1: y();', '        end;',
      '        z();', '    end;', '}',
    }
    eq(9, RT.find_proc_bounds(l, 8).fin)
  end)
end)

describe("refactor.suggest_name", function()
  it("builds a PascalCase Lbl name", function()
    eq("HelloThereLbl", RT.suggest_name("hello there"))
  end)

  it("caps at four words", function()
    eq("OneTwoThreeFourLbl", RT.suggest_name("one two three four five"))
  end)

  it("falls back when there are no word characters", function()
    eq("MyLabelLbl", RT.suggest_name("!!! ???"))
  end)
end)

-- ── Pure refactors ────────────────────────────────────────────────────────────

describe("refactor.to_validate", function()
  it("rewrites a member assignment as Rec.Validate(member, value)", function()
    eq({ '        Cust.Validate("No.", Code);' },
       R.to_validate({ '        Cust."No." := Code;' }))
  end)

  it("rewrites a bare assignment as Validate(field, value)", function()
    eq({ '    Validate("No.", Code);' }, R.to_validate({ '    "No." := Code;' }))
  end)

  it("ignores a `:=` inside a string literal", function()
    -- The only real assignment is Rec.Name := …; the `:=` in the literal must
    -- not be taken as the operator.
    eq({ "    Rec.Validate(Name, 'a := b');" },
       R.to_validate({ "    Rec.Name := 'a := b';" }))
  end)

  it("refuses a compound assignment", function()
    local out, err = R.to_validate({ "    Qty += 1;" })
    eq(nil, out)
    ok(err:match("compound"), err)
  end)

  it("refuses a statement that continues on the next line", function()
    local out, err = R.to_validate({ "    Rec.Name :=" })
    eq(nil, out)
    ok(err:match("multi%-line"), err)
  end)

  it("converts several lines at once", function()
    eq({ "    Validate(A, 1);", "    Validate(B, 2);" },
       R.to_validate({ "    A := 1;", "    B := 2;" }))
  end)
end)

describe("refactor.to_evaluate", function()
  it("rewrites X := Y; as Evaluate(X, Y);", function()
    eq({ "    Evaluate(Amount, Txt);" }, R.to_evaluate({ "    Amount := Txt;" }))
  end)
end)

-- Drive the shipped extract_label with stubbed prompts so the Label text the
-- user actually gets is what is asserted on.
local function run_extract_label(lines, cursor, scope, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, cursor)
  local o_input, o_select = vim.ui.input, vim.ui.select
  vim.ui.input  = function(_, cb) cb("MyLbl") end
  vim.ui.select = function(items, _, cb)
    for _, it in ipairs(items) do if it:match("^" .. scope) then cb(it) end end
  end
  R.extract_label(opts)
  vim.wait(200, function() return false end)   -- flush vim.schedule
  vim.ui.input, vim.ui.select = o_input, o_select
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("refactor.extract_label Locked", function()
  local src = {
    'codeunit 50000 "X"',
    '{',
    '    procedure Run()',
    '    begin',
    "        Message('hello');",
    '    end;',
    '}',
  }
  local col = src[5]:find("hello") - 1

  it("emits a translatable label by default (no Locked)", function()
    -- Regression: `Locked = true` was emitted for every extracted label, so
    -- the default silently removed strings from translation.
    local out = run_extract_label(src, { 5, col }, "Local")
    local decl
    for _, l in ipairs(out) do if l:match("MyLbl: Label") then decl = l end end
    ok(decl, "declaration present: " .. vim.inspect(out))
    eq(nil, decl:match("Locked"), decl)
    eq("        Message(MyLbl);", out[7])
  end)

  it("emits Locked = true only when asked", function()
    local out = run_extract_label(src, { 5, col }, "Local", { locked = true })
    local decl
    for _, l in ipairs(out) do if l:match("MyLbl: Label") then decl = l end end
    ok(decl and decl:match("Locked = true"), vim.inspect(out))
  end)

  it("creates a global var block before the first procedure", function()
    local out = run_extract_label(src, { 5, col }, "Global")
    eq({ 'codeunit 50000 "X"', '{', '', '    var', "        MyLbl: Label 'hello';",
         '    procedure Run()' }, vim.list_slice(out, 1, 6))
  end)
end)

describe("refactor.make_var_global", function()
  it("drops a dangling `var` and creates the global block", function()
    local src = {
      'codeunit 1 "X"', '{',
      '    procedure P()',
      '    var',
      '        Cust: Record Customer;',
      '    begin',
      '        Cust.Get();',
      '    end;',
      '}',
    }
    eq({
      'codeunit 1 "X"', '{',
      '',
      '    var',
      '        Cust: Record Customer;',
      '    procedure P()',
      '    begin',
      '        Cust.Get();',
      '    end;',
      '}',
    }, R.make_var_global(src, 5))
  end)

  it("appends to an existing global block and keeps a non-empty local block", function()
    local src = {
      'codeunit 1 "X"', '{',
      '    var',
      '        G: Integer;',
      '',
      '    procedure P()',
      '    var',
      '        A: Integer;',
      '        B: Integer;',
      '    begin',
      '    end;',
      '}',
    }
    local out = R.make_var_global(src, 9)
    eq('        B: Integer;', out[5])
    eq('    var', out[8])
    eq('        A: Integer;', out[9])
    eq('    begin', out[10])
  end)

  it("refuses a cursor outside the local var block", function()
    local src = { 'codeunit 1 "X"', '{', '    procedure P()', '    var', '        A: Integer;',
                  '    begin', '        A := 1;', '    end;', '}' }
    local out, err = R.make_var_global(src, 7)
    eq(nil, out); ok(err)
  end)
end)

describe("refactor.add_publishers", function()
  local src = {
    'codeunit 1 "X"', '{',
    '    procedure Post(var SalesHeader: Record "Sales Header"; Commit: Boolean)',
    '    begin',
    '        DoIt();',
    '    end;',
    '}',
  }

  it("keeps var params, adds IsHandled, early-exits after begin, publishers after end", function()
    local out = R.add_publishers(src, 3, { publisher_var_params = true, initialize_is_handled = true })
    eq({
      'codeunit 1 "X"', '{',
      '    procedure Post(var SalesHeader: Record "Sales Header"; Commit: Boolean)',
      '    var',
      '        IsHandled: Boolean;',
      '    begin',
      '        IsHandled := false;',
      '        OnBeforePost(SalesHeader, Commit, IsHandled);',
      '        if IsHandled then',
      '            exit;',
      '',
      '        DoIt();',
      '        OnAfterPost(SalesHeader, Commit);',
      '    end;',
      '',
      '    [IntegrationEvent(false, false)]',
      '    local procedure OnBeforePost(var SalesHeader: Record "Sales Header"; var Commit: Boolean; var IsHandled: Boolean)',
      '    begin',
      '    end;',
      '',
      '    [IntegrationEvent(false, false)]',
      '    local procedure OnAfterPost(var SalesHeader: Record "Sales Header"; var Commit: Boolean)',
      '    begin',
      '    end;',
      '}',
    }, out)
  end)

  it("honours publisher_var_params=false and initialize_is_handled=false", function()
    local out = R.add_publishers(src, 3, { publisher_var_params = false, initialize_is_handled = false })
    eq('        OnBeforePost(SalesHeader, Commit, IsHandled);', out[7])
    ok(vim.tbl_contains(out,
      '    local procedure OnBeforePost(var SalesHeader: Record "Sales Header"; Commit: Boolean; var IsHandled: Boolean)'),
      vim.inspect(out))
  end)

  it("refuses when OnBefore<Name> already exists", function()
    local with = vim.deepcopy(src)
    table.insert(with, 7, '    local procedure OnBeforePost(var IsHandled: Boolean) begin end;')
    local out, err = R.add_publishers(with, 3)
    eq(nil, out); ok(err:match("already exists"), err)
  end)
end)

describe("refactor.promote_action", function()
  it("creates area(Promoted) with a group when absent", function()
    local src = {
      'page 1 "X"', '{',
      '    actions',
      '    {',
      '        area(Processing)',
      '        {',
      '            action(Post)',
      '            {',
      '            }',
      '        }',
      '    }',
      '}',
    }
    local out = R.promote_action(src, 7)
    eq({
      '        area(Promoted)',
      '        {',
      '            group(Category_Process)',
      '            {',
      '                actionref(Post_Promoted; Post)',
      '                {',
      '                }',
      '            }',
      '        }',
      '    }',
    }, vim.list_slice(out, 11, 20))
  end)

  it("appends to the first existing group and sanitises quoted names", function()
    local src = {
      'page 1 "X"', '{',
      '    actions',
      '    {',
      '        area(Processing)',
      '        {',
      '            action("Post Now")',
      '            {',
      '            }',
      '        }',
      '        area(Promoted)',
      '        {',
      '            group(Category_Process)',
      '            {',
      '                actionref(Other_Promoted; Other)',
      '                {',
      '                }',
      '            }',
      '        }',
      '    }',
      '}',
    }
    local out = R.promote_action(src, 7)
    eq('                actionref(PostNow_Promoted; "Post Now")', out[18])
    eq('            }', out[21])
  end)

  it("refuses an already promoted action", function()
    local src = {
      'page 1 "X"', '{', '    actions', '    {',
      '        area(Processing)', '        {', '            action(Post)', '            {', '            }', '        }',
      '        area(Promoted)', '        {', '            group(G)', '            {',
      '                actionref(Post_Promoted; Post)', '                {', '                }',
      '            }', '        }', '    }', '}',
    }
    local out, err = R.promote_action(src, 7)
    eq(nil, out); ok(err:match("already promoted"), err)
  end)
end)

describe("refactor.handlers", function()
  local src = {
    'codeunit 1 "T"', '{',
    "    [Test]",
    "    [HandlerFunctions('MsgHandler,ConfirmYes')]",
    '    procedure Run()',
    '    begin',
    '    end;',
    '',
    '    [MessageHandler]',
    '    procedure MsgHandler(Message: Text[1024])',
    '    begin',
    '    end;',
    '}',
  }

  it("lists only the handlers that do not exist yet", function()
    local info = R.missing_handlers(src, 4)
    eq({ "ConfirmYes" }, info.missing)
    eq(7, info.proc_fin)
  end)

  it("stubs a handler with the fixed signature after the test", function()
    local out = R.create_handler_function(src, "ConfirmYes", "ConfirmHandler", 7, "    ")
    eq({ '', '    [ConfirmHandler]',
         '    procedure ConfirmYes(Question: Text[1024]; var Reply: Boolean)',
         '    begin', '    end;' }, vim.list_slice(out, 8, 12))
  end)
end)

describe("refactor.insert_var_decl", function()
  it("appends after the last declaration of an existing local block", function()
    local l = { 'codeunit 1 "X"', '{', '    procedure P()', '    var', '        A: Integer;',
                '    begin', '    end;', '}' }
    local out = RT.insert_var_decl(l, "local", "B: Integer;", RT.find_proc_bounds(l, 6))
    eq('        B: Integer;', out[6])
  end)
end)
