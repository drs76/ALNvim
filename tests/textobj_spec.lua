-- textobj.lua — begin/end block bounds.
--
-- The block scanner used to count every `begin` on a line before every `end`,
-- which gets `end else begin` wrong: the two cancel out, depth never reaches
-- zero at the `else`, and aF/iF swallow the else-branch too. That line is the
-- most common multi-token line in AL.

local T = require("tests.harness")
local describe, it, eq = T.describe, T.it, T.eq
local textobj = require("al.textobj")

local FIXTURE = {
  'codeunit 50000 "T"',          -- 1
  "{",                           -- 2
  "    procedure P()",           -- 3
  "    begin",                   -- 4
  "        if x then begin",     -- 5
  "            A();",            -- 6
  "        end else begin",      -- 7
  "            B();",            -- 8
  "        end;",                -- 9
  "        case v of",           -- 10
  "            1: C();",         -- 11
  "        end;",                -- 12
  "        while q do begin",    -- 13
  "            D();",            -- 14
  "        end;",                -- 15
  "    end;",                    -- 16
  "}",                           -- 17
}

-- Put the fixture in the current buffer, place the cursor, run the text object,
-- and report the linewise selection it produced.
local function around_block_from(line)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, FIXTURE)
  vim.fn.cursor(line, 1)
  textobj.around_block()
  vim.cmd("normal! \27")   -- leave visual so the marks settle
  return vim.fn.line("'<"), vim.fn.line("'>")
end

describe("textobj.around_block", function()
  it("stops at 'end else begin' from inside the if-branch", function()
    -- Regression: used to return 5..9, swallowing the else-branch.
    eq({ 5, 7 }, { around_block_from(6) })
  end)

  it("selects the else-branch from inside it", function()
    -- The opener is the `begin` at the end of line 7, so the forward scan must
    -- start after it — restarting at the line's first token re-consumes the
    -- `end` that closed the if-branch and closes the block immediately.
    eq({ 7, 9 }, { around_block_from(8) })
  end)

  it("handles case…of, which has no matching begin", function()
    eq({ 10, 12 }, { around_block_from(11) })
  end)

  it("handles a while…do begin block", function()
    eq({ 13, 15 }, { around_block_from(14) })
  end)

  it("selects the whole procedure body from its begin", function()
    eq({ 4, 16 }, { around_block_from(4) })
  end)
end)

describe("textobj.inside_block", function()
  it("excludes the begin and end lines", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, FIXTURE)
    vim.fn.cursor(6, 1)
    textobj.inside_block()
    vim.cmd("normal! \27")
    eq({ 6, 6 }, { vim.fn.line("'<"), vim.fn.line("'>") })
  end)
end)
