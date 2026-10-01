-- The agentic LSP (al launchlspserver) as the default backend: go-to-definition
-- into base-app objects (al.basedef), and the features that used to be keyed
-- to the EditorServices client name.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local B = require("al.basedef")._test

describe("basedef.parse_hover", function()
  it("reads a namespaced, quoted object", function()
    eq({ kind = "table", name = "Sales Header" },
      B.parse_hover('\r\n```al\r\nTable Microsoft.Sales.Document."Sales Header"\n"Document Type"  Enum'))
  end)

  it("keeps a dot that is inside the quotes", function()
    eq({ kind = "table", name = "Purch. Header" },
      B.parse_hover('```al\nTable Microsoft.Purchases.Document."Purch. Header"\n'))
  end)

  it("reads a variable's type, Record meaning table", function()
    eq({ kind = "table", name = "Sales Header" },
      B.parse_hover('```al\n(local) SH: Record "Sales Header"\n"No."  Code[20]'))
    eq({ kind = "codeunit", name = "Sales-Post" },
      B.parse_hover('```al\n(local) Mgt: Codeunit "Sales-Post"\n```'))
  end)

  it("ignores `temporary` and bare names", function()
    eq({ kind = "table", name = "Customer" },
      B.parse_hover("```al\n(parameter) C: Record Customer temporary\n```"))
  end)

  it("returns nil for things that are not objects", function()
    eq(nil, B.parse_hover("```al\n(field) Name: Text[100]\n```"))
    eq(nil, B.parse_hover("```al\nprocedure InitInsert()\n```"))
    eq(nil, B.parse_hover(nil))
  end)
end)

describe("basedef.target_at_cursor", function()
  local function at(line, needle, off)
    return B.target_at_cursor(line, line:find(needle, 1, true) - 1 + off)
  end

  it("finds a member and its bare qualifier", function()
    local line = "        SH.InitInsert();"
    local t = at(line, "InitInsert", 2)
    eq("InitInsert", t.name)
    eq(line:find("SH", 1, true), t.qual)
  end)

  it("finds a quoted member", function()
    local line = '        Cust."No." := X;'
    local t = at(line, '"No."', 2)
    eq("No.", t.name)
    eq(line:find("Cust", 1, true), t.qual)
  end)

  it("treats Page::\"X\" as an object reference, not a member", function()
    local t = at('Page.Run(Page::"Customer List");', '"Customer List"', 3)
    eq("Customer List", t.name)
    eq(nil, t.qual)
  end)

  it("reads a quoted name containing spaces", function()
    eq("Sales Header", at('SH: Record "Sales Header";', '"Sales Header"', 4).name)
  end)
end)

describe("basedef.object_pattern", function()
  -- Run the pattern through rg itself, the way find_object does.
  local file = vim.fn.tempname() .. ".al"
  vim.fn.writefile({
    'table 36 "Sales Header"',
    'table 5107 "Sales Header Archive"',
    "table 18 Customer",
    'table 9260 "Customer Experience Survey"',
    'codeunit 80 "Sales-Post"',
    'codeunit 81 "Sales-Post (Yes/No)"',
  }, file)
  local function matches(obj)
    return vim.fn.systemlist({ "rg", "-n", "-i", "-e", B.object_pattern(obj), file })
  end

  it("matches the exact quoted name, not a longer one that starts with it", function()
    -- Regression: with both quotes optional, "Sales Header" also matched
    -- "Sales Header Archive", and gd landed on whichever rg listed first.
    eq({ '1:table 36 "Sales Header"' }, matches({ kind = "table", name = "Sales Header" }))
    eq({ '5:codeunit 80 "Sales-Post"' }, matches({ kind = "codeunit", name = "Sales-Post" }))
  end)

  it("matches a bare name without catching a quoted longer one", function()
    eq({ "3:table 18 Customer" }, matches({ kind = "table", name = "Customer" }))
  end)
end)

describe("basedef.member_line", function()
  local lines = {
    'table 36 "Sales Header"', "{",
    '    field(3; "No."; Code[20])',
    "    procedure InitInsert()",
    "    local procedure Helper(X: Integer)",
    '    value(1; "Order") { }',
  }
  it("finds fields, procedures and enum values", function()
    eq(3, B.member_line(lines, "No."))
    eq(4, B.member_line(lines, "initinsert"))
    eq(5, B.member_line(lines, "Helper"))
    eq(6, B.member_line(lines, "Order"))
  end)

  it("returns nil for a built-in it does not declare", function()
    eq(nil, B.member_line(lines, "Count"))
  end)
end)

describe("basedef.declaration_line", function()
  local lines = {
    "codeunit 50101 Probe",                        -- 1
    "{",                                           -- 2
    "    procedure DoIt(var Cust: Record Customer; Qty: Decimal)",  -- 3
    "    var",                                     -- 4
    '        Mgt: Codeunit "Sales-Post";',         -- 5
    "        a, b: Integer;",                      -- 6
    "    begin",                                   -- 7
    "        Mgt.Run(Cust);",                      -- 8
    "        G := a + b + Qty;",                   -- 9
    "    end;",                                    -- 10
    "    var",                                     -- 11
    "        G: Integer;",                         -- 12
    "}",
  }
  it("finds locals, var and value parameters, and comma lists", function()
    eq(5, B.declaration_line(lines, 8, "Mgt"))
    eq(3, B.declaration_line(lines, 8, "Cust"))
    eq(3, B.declaration_line(lines, 9, "Qty"))
    eq(6, B.declaration_line(lines, 9, "b"))
  end)

  it("finds a global declared below the code", function()
    eq(12, B.declaration_line(lines, 9, "G"))
  end)

  it("recognises a variable hover", function()
    eq("local", B.hover_scope('```al\n(local) Mgt: Codeunit "Sales-Post"\n```'))
    eq(nil, B.hover_scope('```al\nTable Customer\n```'))
  end)
end)

describe("lsp.client", function()
  it("returns the agentic client when that is what is attached", function()
    local orig = vim.lsp.get_clients
    vim.lsp.get_clients = function(f)
      return f.name == "al_agentic_lsp" and { { name = "al_agentic_lsp", id = 7 } } or {}
    end
    local c = require("al.lsp").client(0)
    vim.lsp.get_clients = orig
    eq("al_agentic_lsp", c and c.name)
  end)
end)

describe("format on save", function()
  it("formats with the agentic client", function()
    -- Regression: the BufWritePre hook looked up "al_language_server" only, so
    -- switching backends silently stopped formatting — though the dotnet
    -- tool's server formats as well.
    local lsp = require("al.lsp")
    local al  = require("al")
    local orig_client, orig_format, orig_cs = lsp.client, vim.lsp.buf.format, al.config.colorscheme
    al.config.colorscheme = false
    lsp.client = function()
      return { id = 42, name = "al_agentic_lsp",
               server_capabilities = { documentFormattingProvider = true } }
    end
    local formatted_with
    vim.lsp.buf.format = function(o) formatted_with = o.id end

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".al")
    vim.api.nvim_set_current_buf(buf)
    local okc, err = pcall(function()
      vim.cmd("source " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/ftplugin/al.lua"))
      vim.api.nvim_exec_autocmds("BufWritePre", { buffer = buf })
    end)

    lsp.client, vim.lsp.buf.format, al.config.colorscheme = orig_client, orig_format, orig_cs
    if not okc then error(err, 0) end
    eq(42, formatted_with)
  end)
end)

describe("language server root", function()
  it("does not start a server for a stray app.json far above the file", function()
    -- The FileType handler used vim.fs.root(), which walks to the filesystem
    -- root. For al launchlspserver that root is the workspace it indexes, so a
    -- stray app.json at a mount point would have pointed it at the whole share.
    local top = vim.fn.tempname()
    vim.fn.mkdir(top, "p")
    vim.fn.writefile({ "{}" }, top .. "/app.json")
    local deep = top .. "/a/b/c/d/e/f/g/h/i/j"
    vim.fn.mkdir(deep, "p")

    local al = require("al")
    local agentic = require("al.agentic_lsp")
    local orig_start, orig_flag = agentic.start, al.config.experimental_lsp
    local started = {}
    agentic.start = function(_, root) started[#started + 1] = root end
    al.config.experimental_lsp = true
    local okc, err = pcall(function()
      if not vim.g.alnvim_loaded then vim.cmd("runtime plugin/al.lua") end
      vim.cmd("edit " .. vim.fn.fnameescape(deep .. "/X.al"))
      vim.cmd("doautocmd FileType al")
      -- And a normal project still starts one.
      vim.cmd("edit " .. vim.fn.fnameescape(top .. "/Near.al"))
      vim.cmd("doautocmd FileType al")
    end)
    agentic.start, al.config.experimental_lsp = orig_start, orig_flag
    if not okc then error(err, 0) end
    -- Exactly one start, from Near.al. Recording only the last root hid the
    -- bug: the deep file also resolved to `top`, so the final value matched.
    eq({ top }, started)
  end)
end)
