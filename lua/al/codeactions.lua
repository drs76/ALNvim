-- AL code actions that do not need a language server.
--
-- The agentic LSP (`al launchlspserver`) advertises no codeActionProvider, so
-- `vim.lsp.buf.code_action` is a no-op on that backend. This module keeps a
-- registry of Lua actions (built on lua/al/refactor.lua) and a picker that
-- merges in the server's own actions only when the attached client has one.
--
--   M.register({ id, title, kind, applicable(ctx), run(ctx) })
--   M.pick({ only = "refactor" | "quickfix" | "source" | "navigate" })
--   M.run_only(kind)  — one applicable action of that kind runs at once, more
--                       go to the picker
--
-- Quick fixes (by diagnostic code), the Option→enum refactor and navigation
-- live in lua/al/fixes.lua; they are registered at the bottom of this file.
--
-- ctx = { bufnr, root, lines, row, col0, line, sel_start, sel_end, visual,
--         bounds = find_proc_bounds(lines, row), diagnostics (cursor line) }

local M = {}
local refactor = require("al.refactor")
local H = refactor.helpers

local registry = {}

function M.register(action)
  assert(type(action.id) == "string" and action.id ~= "", "codeactions.register: id required")
  assert(type(action.run) == "function", "codeactions.register: run required")
  action.kind = action.kind or "refactor"
  action.applicable = action.applicable or function() return true end
  for i, a in ipairs(registry) do
    if a.id == action.id then registry[i] = action; return end
  end
  registry[#registry + 1] = action
end

-- Actions whose applicable(ctx) holds, filtered by kind prefix when `only`
-- is set ("refactor" matches "refactor" and "refactor.extract").
local function applicable_for(ctx, only)
  local out = {}
  for _, a in ipairs(registry) do
    if (not only or a.kind == only or a.kind:sub(1, #only + 1) == only .. ".")
      and a.applicable(ctx) then
      out[#out + 1] = a
    end
  end
  return out
end

function M.context(bufnr, opts)
  opts  = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pos   = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e  = pos[1], pos[1]
  local visual = false
  if opts.range then
    s, e, visual = opts.range[1], opts.range[2], true
  elseif vim.fn.mode():match("^[vV\22]") then
    s, e = vim.fn.line("v"), vim.fn.line(".")
    visual = true
  end
  if s > e then s, e = e, s end
  local row = pos[1]
  return {
    bufnr       = bufnr,
    root        = require("al.lsp").get_root(bufnr),
    lines       = lines,
    row         = row,
    col0        = pos[2],
    line        = lines[row] or "",
    sel_start   = s,
    sel_end     = e,
    visual      = visual,
    bounds      = H.find_proc_bounds(lines, row),
    diagnostics = vim.diagnostic.get(bufnr, { lnum = row - 1 }),
  }
end

local function show(items, ctx)
  if #items == 0 then
    vim.notify("AL: no code actions available here", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt      = "AL code actions:",
    format_item = function(it) return it.title end,
    kind        = "al.codeaction",  -- not "codeaction": snacks.nvim ui_select reads item.ctx for that kind
  }, function(choice)
    if not choice then return end
    choice.run(ctx)
  end)
end

-- Turn an LSP CodeAction/Command into a registry-shaped item.
local function lsp_item(client, action, ctx)
  return {
    id    = "lsp",
    title = "[LSP] " .. (action.title or "?"),
    kind  = action.kind or "lsp",
    run   = function()
      local function apply(a)
        if a.edit then
          vim.lsp.util.apply_workspace_edit(a.edit, client.offset_encoding)
        end
        local cmd = a.command
        if type(cmd) == "table" then
          if client.exec_cmd then client:exec_cmd(cmd, { bufnr = ctx.bufnr })
          else client:request("workspace/executeCommand", cmd, nil, ctx.bufnr) end
        elseif a.command and a.arguments then
          -- A bare Command (not a CodeAction)
          if client.exec_cmd then client:exec_cmd(a, { bufnr = ctx.bufnr })
          else client:request("workspace/executeCommand", a, nil, ctx.bufnr) end
        end
      end
      if not action.edit and not action.command
        and client.server_capabilities.codeActionProvider
        and type(client.server_capabilities.codeActionProvider) == "table"
        and client.server_capabilities.codeActionProvider.resolveProvider then
        client:request("codeAction/resolve", action, function(err, resolved)
          if err or not resolved then
            vim.notify("AL: could not resolve code action", vim.log.levels.WARN)
            return
          end
          apply(resolved)
        end, ctx.bufnr)
      else
        apply(action)
      end
    end,
  }
end

-- opts.only — kind filter; opts.range — { l1, l2 } from a :command range.
function M.pick(opts)
  opts = opts or {}
  local ctx   = M.context(nil, opts)
  local items = applicable_for(ctx, opts.only)

  local client = require("al.lsp").client(ctx.bufnr)
  if not (client and client.server_capabilities and client.server_capabilities.codeActionProvider) then
    return show(items, ctx)
  end

  local params = vim.lsp.util.make_range_params(0, client.offset_encoding)
  if ctx.visual then
    params.range = {
      start   = { line = ctx.sel_start - 1, character = 0 },
      ["end"] = { line = ctx.sel_end - 1, character = #(ctx.lines[ctx.sel_end] or "") },
    }
  end
  params.context = {
    diagnostics = vim.lsp.diagnostic.from(ctx.diagnostics),
    only        = opts.only and { opts.only } or nil,
  }
  client:request("textDocument/codeAction", params, function(err, result)
    if not err and type(result) == "table" then
      for _, a in ipairs(result) do items[#items + 1] = lsp_item(client, a, ctx) end
    end
    show(items, ctx)
  end, ctx.bufnr)
end

-- Run the one applicable Lua action of `kind` at the cursor; with several,
-- show the picker; with none, say so. Used by :ALFindRelated.
function M.run_only(kind)
  local ctx   = M.context()
  local items = applicable_for(ctx, kind)
  if #items == 1 then return items[1].run(ctx) end
  show(items, ctx)
end

-- True when the attached AL client can answer textDocument/codeAction.
function M.server_supported(bufnr)
  local client = require("al.lsp").client(bufnr or vim.api.nvim_get_current_buf())
  return client ~= nil and client.server_capabilities ~= nil
    and client.server_capabilities.codeActionProvider ~= nil
    and client.server_capabilities.codeActionProvider ~= false
end

-- ── Built-in actions ─────────────────────────────────────────────────────────

local function in_body(ctx)
  local b = ctx.bounds
  return b ~= nil and ctx.row > b.beg and ctx.row < b.fin
end

local function has_assignment(ctx)
  for i = ctx.sel_start, ctx.sel_end do
    local m = H.mask_strings(ctx.lines[i] or "")
    if m:find(":=", 1, true) and m:match(";%s*$") then return true end
  end
  return false
end

M.register({
  -- Server-independent: on the AL tool's language server there is no
  -- organizeImports to offer, so this is the only way it appears in the menu.
  id = "add_usings", kind = "source.organizeImports", title = "Add missing using statements",
  applicable = function(ctx) return ctx.root ~= nil end,
  run = function(ctx) require("al.namespace").add_usings(ctx.bufnr) end,
})
M.register({
  id = "extract_label", kind = "refactor.extract", title = "Extract to Label",
  applicable = function(ctx) return in_body(ctx) and H.find_quoted_string(ctx.line, ctx.col0) ~= nil end,
  run = function() refactor.extract_label() end,
})
M.register({
  id = "extract_locked_label", kind = "refactor.extract", title = "Extract to locked Label",
  applicable = function(ctx) return in_body(ctx) and H.find_quoted_string(ctx.line, ctx.col0) ~= nil end,
  run = function() refactor.extract_label({ locked = true }) end,
})
M.register({
  id = "extract_procedure", kind = "refactor.extract", title = "Extract to procedure",
  applicable = function(ctx)
    local b = ctx.bounds
    return ctx.visual and b ~= nil and ctx.sel_start > b.beg and ctx.sel_end < b.fin
  end,
  run = function() refactor.extract_to_procedure() end,
})
M.register({
  id = "to_validate", kind = "refactor.rewrite", title = "Convert assignment to Validate()",
  applicable = function(ctx) return in_body(ctx) and has_assignment(ctx) end,
  run = function(ctx) refactor.convert_to_validate(ctx.sel_start, ctx.sel_end) end,
})
M.register({
  id = "to_evaluate", kind = "refactor.rewrite", title = "Convert assignment to Evaluate()",
  applicable = function(ctx) return in_body(ctx) and has_assignment(ctx) end,
  run = function(ctx) refactor.convert_to_evaluate(ctx.sel_start, ctx.sel_end) end,
})
M.register({
  id = "make_var_global", kind = "refactor.move", title = "Make variable global",
  applicable = function(ctx)
    local b = ctx.bounds
    return b ~= nil and b.var ~= nil and ctx.row > b.var and ctx.row < b.beg
      and vim.trim(ctx.line):match(":") ~= nil
  end,
  run = function() refactor.make_var_global_at_cursor() end,
})
M.register({
  id = "add_publishers", kind = "refactor", title = "Add OnBefore/OnAfter publishers",
  applicable = function(ctx)
    local b = ctx.bounds
    return b ~= nil and ctx.row >= b.hdr and ctx.row <= b.fin
      and H.parse_proc_header(ctx.lines[b.hdr]) ~= nil
  end,
  run = function() refactor.add_publishers_at_cursor() end,
})
M.register({
  id = "create_handler", kind = "source", title = "Create missing handler function",
  applicable = function(ctx) return ctx.line:match("%[HandlerFunctions") ~= nil end,
  run = function() refactor.create_handler() end,
})
M.register({
  id = "promote_action", kind = "refactor", title = "Promote action (add actionref)",
  applicable = function(ctx) return ctx.line:match("^%s*action%s*%(") ~= nil end,
  run = function() refactor.promote_action_at_cursor() end,
})

-- ── Diagnostic quick fixes, enum refactor, navigation (lua/al/fixes.lua) ────

local fixes = require("al.fixes")

local function has_code(codes)
  return function(ctx) return fixes.diag_with_code(ctx, codes) ~= nil end
end

M.register({
  id = "create_procedure", kind = "quickfix", title = "Create procedure",
  applicable = has_code({ AL0118 = true, AL0132 = true }),
  run = function(ctx) fixes.create_procedure(ctx) end,
})
M.register({
  id = "remove_unused_var", kind = "quickfix", title = "Remove unused variable (AA0137)",
  applicable = has_code({ AA0137 = true }),
  run = function(ctx) fixes.fix_cop_at_cursor(ctx, "AA0137") end,
})
M.register({
  id = "remove_unused_assignment", kind = "quickfix", title = "Remove unused assignment (AA0206)",
  applicable = has_code({ AA0206 = true }),
  run = function(ctx) fixes.fix_cop_at_cursor(ctx, "AA0206") end,
})
M.register({
  id = "add_parens", kind = "quickfix", title = "Add () to call (AA0008)",
  applicable = has_code({ AA0008 = true }),
  run = function(ctx) fixes.fix_cop_at_cursor(ctx, "AA0008") end,
})
M.register({
  id = "sort_variables", kind = "quickfix", title = "Sort variables by type (AA0021)",
  applicable = has_code({ AA0021 = true }),
  run = function(ctx) fixes.fix_cop_at_cursor(ctx, "AA0021") end,
})
M.register({
  id = "sort_variables_buffer", kind = "refactor", title = "Sort all var blocks by type (AA0021)",
  applicable = fixes.in_var_block,
  run = function(ctx) fixes.sort_variables(ctx.bufnr) end,
})
M.register({
  id = "option_to_enum", kind = "refactor.rewrite", title = "Convert Option field to enum",
  applicable = fixes.in_option_field,
  run = function() fixes.refactor_to_enum({ extensible = false }) end,
})
M.register({
  id = "option_to_extensible_enum", kind = "refactor.rewrite", title = "Convert Option field to extensible enum",
  applicable = fixes.in_option_field,
  run = function() fixes.refactor_to_enum({ extensible = true }) end,
})
M.register({
  id = "find_publisher", kind = "navigate", title = "Go to event publisher",
  applicable = fixes.has_subscriber,
  run = function(ctx) fixes.find_publisher(ctx) end,
})
M.register({
  id = "find_handlers", kind = "navigate", title = "Go to handler function(s)",
  applicable = fixes.has_handlers,
  run = function(ctx) fixes.find_handlers(ctx) end,
})
M.register({
  id = "find_trigger", kind = "navigate", title = "Go to table trigger (OnInsert/OnModify/…)",
  applicable = fixes.has_record_call,
  run = function(ctx) fixes.find_trigger(ctx) end,
})

-- Pure internals for tests/ only. Not API.
M._test = { registry = registry, applicable_for = applicable_for, fixes = fixes._test }

return M
