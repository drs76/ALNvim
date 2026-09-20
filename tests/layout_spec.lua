-- layout.lua — finding the rendering section in a report.
--
-- Both scanners here used to test brace depth without first checking a brace
-- had actually been seen, so a blank or comment line between `rendering` and
-- its `{` read as the section's closing brace.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local layout = require("al.layout")

local function buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

describe("layout._inject_rendering", function()
  -- A report whose `rendering` keyword is separated from its brace by a blank
  -- line. Legal AL formatting, and what broke the depth scan.
  local function report_with_gap()
    return {
      "report 50000 Test",                    -- 1
      "{",                                    -- 2
      "    dataset",                          -- 3
      "    {",                                -- 4
      "    }",                                -- 5
      "",                                     -- 6
      "    rendering",                        -- 7
      "",                                     -- 8  <- blank before the brace
      "    {",                                -- 9
      "        layout(Existing)",             -- 10
      "        {",                            -- 11
      "            Type = Word;",             -- 12
      "            LayoutFile = 'a.docx';",   -- 13
      "        }",                            -- 14
      "    }",                                -- 15
      "}",                                    -- 16
    }
  end

  it("inserts the layout inside the rendering section, not above it", function()
    local b = buf(report_with_gap())
    layout._inject_rendering(b, "TestExcel",
      { { id = "TestExcel", type_str = "Excel", layout_file = "layouts/TestExcel.xlsx" } })
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)

    -- Locate the new layout and the braces of the rendering section.
    local new_layout, rend_open, rend_close
    for i, l in ipairs(lines) do
      if l:match("layout%(TestExcel%)")        then new_layout = i end
      if l:match("^%s*rendering")              then rend_open  = i end
      if new_layout and l:match("^    }%s*$")  then rend_close = rend_close or i end
    end
    ok(new_layout, "the layout block was not inserted at all")
    ok(new_layout > rend_open,
      ("inserted at line %d, above `rendering` at %d"):format(new_layout or -1, rend_open or -1))
    ok(rend_close and new_layout < rend_close,
      "the layout landed outside the rendering section's closing brace")
  end)

  it("still injects into a normally-formatted rendering section", function()
    local src = report_with_gap()
    table.remove(src, 8)  -- drop the blank line
    local b = buf(src)
    layout._inject_rendering(b, "TestExcel",
      { { id = "TestExcel", type_str = "Excel", layout_file = "layouts/TestExcel.xlsx" } })
    local joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    ok(joined:find("layout(TestExcel)", 1, true), "layout not injected")
    ok(joined:find("DefaultRenderingLayout = TestExcel;", 1, true),
      "DefaultRenderingLayout not added")
  end)

  it("skips a layout whose Type already exists", function()
    local b = buf(report_with_gap())
    layout._inject_rendering(b, "TestWord",
      { { id = "TestWord", type_str = "Word", layout_file = "layouts/TestWord.docx" } })
    local joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    eq(nil, joined:find("layout(TestWord)", 1, true))
  end)
end)

describe("layout.existing_layout_types", function()
  local existing = layout._test.existing_layout_types

  it("reads the types declared in the rendering section", function()
    local b = buf({
      "report 50000 T", "{",
      "    rendering", "    {",
      "        layout(A) { Type = Excel; }",
      "    }",
      "}",
    })
    eq(true, existing(b).excel)
  end)

  it("does not read a Type from beyond the rendering section", function()
    -- Regression: the scan ran to end-of-buffer, so this requestpage Type
    -- registered as an existing Word layout and the wizard refused to add one.
    local b = buf({
      "report 50000 T", "{",
      "    rendering", "    {",
      "        layout(A) { Type = Excel; }",
      "    }",
      "    requestpage",
      "    {",
      "        Type = Word;",
      "    }",
      "}",
    })
    local t = existing(b)
    eq(true, t.excel)
    eq(nil, t.word)
  end)

  it("handles a blank line before the section brace", function()
    local b = buf({
      "report 50000 T", "{",
      "    rendering",
      "",
      "    {",
      "        layout(A) { Type = Excel; }",
      "    }",
      "}",
    })
    eq(true, existing(b).excel)
  end)
end)
