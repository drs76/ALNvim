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
