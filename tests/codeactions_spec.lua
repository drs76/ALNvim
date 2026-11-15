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
    eq({}, ids(CA._test.applicable_for(ctx, "source")))
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
  vim.ui.select = function(items, sopts) shown = vim.tbl_map(sopts.format_item, items) end
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
