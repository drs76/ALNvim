-- Diagnostic-driven quick fixes, the Option→enum refactor and related-code
-- navigation. lua/al/codeactions.lua registers these as actions; this module
-- holds the logic so the pure parts can be tested without a buffer.
--
-- Pure functions take and return string arrays (or nil, reason) in the same
-- style as lua/al/refactor.lua. Anything that talks to the language server
-- goes through lua/al/basedef.lua's hover_text / find_object.
--
-- Diagnostic codes come from `diagnostic.code`: compile.push_diagnostics sets
-- it from alc's output ("AA0137"), and the LSP client sets it from the server.

local M = {}
local H = require("al.refactor").helpers

local HOVER_TIMEOUT_MS = 1500

-- ── Small scanners ───────────────────────────────────────────────────────────

-- Split `s` on top-level commas: commas inside '...' / "..." or any bracket
-- nesting do not count. Doubled quotes are escapes. Returns trimmed pieces.
local function split_top_level(s)
  local parts, depth, buf = {}, 0, {}
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "'" or c == '"' then
      local j = i + 1
      while j <= n do
        if s:sub(j, j) == c then
          if s:sub(j + 1, j + 1) == c then j = j + 2 else break end
        else
          j = j + 1
        end
      end
      buf[#buf + 1] = s:sub(i, j)
      i = j + 1
    elseif c == "(" or c == "[" or c == "{" then
      depth = depth + 1; buf[#buf + 1] = c; i = i + 1
    elseif c == ")" or c == "]" or c == "}" then
      depth = depth - 1; buf[#buf + 1] = c; i = i + 1
    elseif c == "," and depth == 0 then
      parts[#parts + 1] = vim.trim(table.concat(buf)); buf = {}; i = i + 1
    else
      buf[#buf + 1] = c; i = i + 1
    end
  end
  local last = vim.trim(table.concat(buf))
  if last ~= "" or #parts > 0 then parts[#parts + 1] = last end
  return parts
end

-- Column of the ")" closing the "(" at `open` (1-based), or nil.
local function matching_paren(line, open)
  local depth, i, n = 0, open, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == "'" or c == '"' then
      local j = i + 1
      while j <= n do
        if line:sub(j, j) == c then
          if line:sub(j + 1, j + 1) == c then j = j + 2 else break end
        else j = j + 1 end
      end
      i = j + 1
    else
      if c == "(" then depth = depth + 1
      elseif c == ")" then
        depth = depth - 1
        if depth == 0 then return i end
      end
      i = i + 1
    end
  end
  return nil
end

-- Parse `Name(args)` in `text` (a line or statement). Returns
-- { name, qualifier, args = { { text, s, e } }, name_s, name_e } with 1-based
-- columns into `text`, or nil. `at` (1-based column, optional) picks the call
-- whose name covers that column; otherwise the first call is taken.
local function parse_call_args(text, at)
  local masked = H.mask_strings(text)
  local search = 1
  while true do
    local ns, ne, name = masked:find("([%w_]+)%s*%(", search)
    if not ns then return nil end
    local name_e = ns + #name - 1
    if not at or (at >= ns and at <= name_e) then
      local open = masked:find("%(", name_e + 1)
      local close = matching_paren(text, open)
      local inner = text:sub(open + 1, (close or (#text + 1)) - 1)
      local args = {}
      if vim.trim(inner) ~= "" then
        local pos = open + 1
        for _, a in ipairs(split_top_level(inner)) do
          local s = text:find(a, pos, true) or pos
          args[#args + 1] = { text = a, s = s, e = s + #a - 1 }
          pos = s + #a
        end
      end
      local qualifier
      local before = text:sub(1, ns - 1)
      if before:sub(-1) == "." then
        qualifier = before:match('"([^"]*)"%.$') or before:match("([%w_]+)%.$")
      end
      return { name = name, qualifier = qualifier, args = args, name_s = ns, name_e = name_e }
    end
    search = ne
  end
end

-- Type of a literal argument, or nil when `arg` is an expression / identifier.
local function literal_type(arg)
  if arg:match("^'") then return "Text" end
  if arg:match("^%-?%d+$") then return "Integer" end
  if arg:match("^%-?%d+%.%d+$") then return "Decimal" end
  local low = arg:lower()
  if low == "true" or low == "false" then return "Boolean" end
  return nil
end

-- Parameter name for an argument expression: the last identifier segment,
-- quotes and dots stripped; `ArgN` for literals and compound expressions.
local function param_name(arg, n)
  if literal_type(arg) then return "Arg" .. n end
  local id = arg:match('"([^"]+)"%s*$') or arg:match("([%w_]+)%s*$")
  if not id or arg:find("[%+%-%*/%(]") then return "Arg" .. n end
  id = id:gsub("[^%w_]", "")
  if id == "" or id:match("^%d") then return "Arg" .. n end
  return id
end

-- The type named in a hover of a variable/field: "(local) Cust: Record Customer"
-- → "Record Customer"; nil when the hover is not a typed symbol.
local function hover_type(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("\r", "")
  local code = text:match("```al%s*\n([^\n]+)") or text:match("^%s*([^\n]+)")
  if not code then return nil end
  local t = code:match("^%([%a%s]+%)%s*[^:]+:%s*(.+)$")
  if not t then return nil end
  t = vim.trim(t):gsub("%s+temporary$", "")
  -- Drop a namespace: Record Microsoft.Sales.Customer."Customer" → Record "Customer"
  t = t:gsub("(%a+)%s+[%w_]+%.[%w_%.]*%.(\"[^\"]+\")", "%1 %2")
  t = t:gsub("(%a+)%s+[%w_]+%.[%w_%.]*%.([%w_]+)$", "%1 %2")
  return t
end

-- Lines of a new procedure. params = { { name, type } }; `local_` adds the
-- `local` modifier; Record parameters are passed by var, as AL convention has
-- it. No return type — the diagnostic does not tell us one.
local function create_procedure_text(name, params, indent, local_)
  indent = indent or "    "
  local plist = {}
  for _, p in ipairs(params) do
    local prefix = (p.type or ""):lower():match("^record") and "var " or ""
    plist[#plist + 1] = ("%s%s: %s"):format(prefix, p.name, p.type or "Variant")
  end
  local qn = name:match("^[%a_][%w_]*$") and name or ('"' .. name .. '"')
  return {
    ("%s%sprocedure %s(%s)"):format(indent, local_ and "local " or "", qn, table.concat(plist, "; ")),
    indent .. "begin",
    indent .. "    ",
    indent .. "end;",
  }
end

-- ── Diagnostic helpers ───────────────────────────────────────────────────────

local function first_quoted(msg)
  return (msg or ""):match("'([^']+)'")
end

-- Identifier (quoted or bare) covering 1-based column `col` of `line`:
-- returns name, s, e. Falls back to the first identifier at/after col.
local function ident_at(line, col)
  local t = require("al.basedef").target_at_cursor(line, col - 1)
  if t then return t.name, t.s, t.e end
  local s, e = line:find("[%w_]+", col)
  if s then return line:sub(s, e), s, e end
  return nil
end

-- ── AA0137: remove unused variable ───────────────────────────────────────────

local function is_var_decl(line)
  local m = H.mask_strings(line or "")
  return m:match("^%s*\"?[%w_][%w_ %.,\"]*\"?%s*:") ~= nil and not m:match(":=")
end

-- Remove variable `name` declared at `lnum`. A `name, other: Type;` list
-- loses just the name; otherwise the whole line goes, and a `var` keyword
-- left with nothing under it goes too. Returns new lines, or nil + reason.
local function remove_unused_var(lines, lnum, name)
  local line = lines[lnum]
  if not line or not is_var_decl(line) then return nil, "not a variable declaration" end
  local out = vim.deepcopy(lines)
  local head, typ = line:match("^(.-):(.*)$")
  local names = split_top_level(head)
  if #names > 1 and name then
    local kept = {}
    for _, n in ipairs(names) do
      if n:gsub('"', ""):lower() ~= name:lower() then kept[#kept + 1] = n end
    end
    if #kept == #names then return nil, ("%s is not declared on this line"):format(name) end
    local indent = line:match("^(%s*)")
    out[lnum] = indent .. table.concat(kept, ", ") .. ":" .. typ
    return out
  end
  table.remove(out, lnum)
  -- Collapse `var` with nothing left beneath it: the previous non-blank line
  -- is `var` and the next non-blank one is not a declaration.
  local above = lnum - 1
  while above >= 1 and vim.trim(out[above]) == "" do above = above - 1 end
  if above >= 1 and vim.trim(out[above]):lower() == "var" then
    local below = lnum
    while below <= #out and vim.trim(out[below]) == "" do below = below + 1 end
    if below > #out or not is_var_decl(out[below]) then
      table.remove(out, above)
    end
  end
  return out
end

-- ── AA0206: remove unused assignment ─────────────────────────────────────────

local function remove_assignment(lines, lnum)
  local line = lines[lnum]
  if not line then return nil, "no such line" end
  local m = H.mask_strings(line)
  if not (m:find(":=", 1, true) and m:match(";%s*$")) then
    return nil, "not a single-line assignment statement"
  end
  local out = vim.deepcopy(lines)
  table.remove(out, lnum)
  return out
end

-- ── AA0008: add () after a parameterless call ────────────────────────────────

local function add_parens(lines, lnum, col, name)
  local line = lines[lnum]
  if not line then return nil, "no such line" end
  local id, _, e = ident_at(line, col)
  if name and (not id or id:lower() ~= name:lower()) then
    -- The column may be off (another diagnostic edited the line): find by name.
    local pat = '"?' .. vim.pesc(name) .. '"?'
    local s, ee = line:find(pat, 1)
    if not s then return nil, ("%s not found on line"):format(name) end
    e = ee
  elseif not id then
    return nil, "no identifier at column"
  end
  if line:sub(e + 1):match("^%s*%(") then return nil, "already has parentheses" end
  local out = vim.deepcopy(lines)
  out[lnum] = line:sub(1, e) .. "()" .. line:sub(e + 1)
  return out
end

-- ── Option field → enum ──────────────────────────────────────────────────────

-- Find the `field(...)` block enclosing `row`: returns { s, e, name } (1-based
-- lines; e is the closing brace) or nil.
local function field_block(lines, row)
  -- Nearest field header at or above the cursor; the block it opens must
  -- reach down to `row` (fields never nest, so one candidate is enough).
  local s
  for i = row, 1, -1 do
    if (lines[i] or ""):match("^%s*field%s*%(") then s = i break end
  end
  if not s then return nil end
  local depth, e = 0, nil
  for i = s, #lines do
    local m = H.mask_strings(lines[i])
    for c in m:gmatch("[{}]") do
      if c == "{" then depth = depth + 1 else depth = depth - 1 end
    end
    if i > s and depth == 0 then e = i break end
  end
  if not e or e < row then return nil end
  local name = lines[s]:match("^%s*field%s*%(%s*%d+%s*;%s*\"([^\"]+)\"")
            or lines[s]:match("^%s*field%s*%(%s*%d+%s*;%s*([%w_]+)")
  return { s = s, e = e, name = name }
end

-- Unquote an AL identifier: `"Pending Approval"` → Pending Approval.
local function unquote(s)
  s = vim.trim(s)
  return s:match('^"(.*)"$') or s
end

-- Caption pieces from `OptionCaption = 'a,b,c'` (comma-separated, '' escape).
local function split_caption(cap)
  local out = {}
  for _, p in ipairs(split_top_level(cap)) do out[#out + 1] = p end
  return out
end

-- Pure Option→enum: returns new_lines (field edited), enum_text, enum_values
-- or nil + reason. opts = { name, id, extensible }.
local function option_to_enum(lines, row, opts)
  local blk = field_block(lines, row)
  if not blk then return nil, "cursor is not inside a field block" end
  local hdr = lines[blk.s]
  local hm = H.mask_strings(hdr)
  if not hm:match(";%s*[Oo]ption%s*%)") then return nil, "field is not of type Option" end

  local members, caption, mem_l, cap_l
  for i = blk.s + 1, blk.e - 1 do
    local l = lines[i]
    local mm = l:match("^%s*[Oo]ption[Mm]embers%s*=%s*(.-)%s*;%s*$")
    if mm then members, mem_l = mm, i end
    local cc = l:match("^%s*[Oo]ption[Cc]aption%s*=%s*'(.*)'%s*;%s*$")
    if cc then caption, cap_l = cc, i end
  end
  if not members then return nil, "field has no OptionMembers" end

  local names = split_top_level(members)
  local caps = caption and split_caption(caption) or {}
  if #caps ~= #names then caps = {} end

  local values = {}
  for i, n in ipairs(names) do
    local nm = unquote(n)
    local cap = caps[i] and caps[i] or nm
    values[#values + 1] = { ord = i - 1, name = nm, caption = cap }
  end

  local ename = opts.name or blk.name or "NewEnum"
  local etext = {
    ('enum %d "%s"'):format(opts.id or 50000, ename),
    "{",
    ("    Extensible = %s;"):format(opts.extensible and "true" or "false"),
    "",
  }
  for _, v in ipairs(values) do
    local vname = v.name:match("^[%a_][%w_]*$") and v.name or ('"' .. v.name .. '"')
    if v.name == "" then vname = '" "' end
    etext[#etext + 1] = ("    value(%d; %s)"):format(v.ord, vname)
    etext[#etext + 1] = "    {"
    etext[#etext + 1] = ("        Caption = '%s';"):format(v.caption == "" and " " or v.caption)
    etext[#etext + 1] = "    }"
  end
  etext[#etext + 1] = "}"

  local out = vim.deepcopy(lines)
  -- Bottom-up: property lines first, then the header.
  local drop = {}
  if mem_l then drop[#drop + 1] = mem_l end
  if cap_l then drop[#drop + 1] = cap_l end
  table.sort(drop, function(a, b) return a > b end)
  for _, l in ipairs(drop) do table.remove(out, l) end
  out[blk.s] = hdr:gsub("(;%s*)[Oo]ption(%s*%))", ('%%1Enum "%s"%%2'):format(ename), 1)
  return out, table.concat(etext, "\n"), values
end

-- ── Navigation patterns ──────────────────────────────────────────────────────

-- rg (Rust regex) pattern for the publisher of event `name`: an
-- [IntegrationEvent(...)] / [BusinessEvent(...)] attribute, then on the next
-- line the procedure declaring exactly that name. Needs `--multiline`.
-- `"?name"?\s*\(` — the "(" boundary is what keeps OnX from matching OnXY.
local function publisher_pattern(name)
  local n = name:gsub("([%^%$%.%|%?%*%+%(%)%[%]%{%}\\/-])", "\\%1")
  return ('\\[(IntegrationEvent|BusinessEvent)\\([^\\]]*\\)\\]\\s*\\r?\\n'
    .. '\\s*((local|internal|protected)\\s+)?procedure\\s+"?%s"?\\s*\\('):format(n)
end

local function procedure_pattern(name)
  local n = name:gsub("([%^%$%.%|%?%*%+%(%)%[%]%{%}\\/-])", "\\%1")
  return ('^\\s*((local|internal|protected)\\s+)?procedure\\s+"?%s"?\\s*\\('):format(n)
end

-- Record methods whose table trigger a navigation can land on.
local RECORD_TRIGGERS = {
  insert = "OnInsert", modify = "OnModify", delete = "OnDelete", rename = "OnRename",
}

-- Parse `[EventSubscriber(ObjectType::X, Y::"Z", 'Event', 'Element', a, b)]`:
-- returns { event, element } or nil.
local function parse_subscriber(line)
  local inner = line:match("%[%s*[Ee]vent[Ss]ubscriber%s*%((.*)%)%s*%]")
  if not inner then return nil end
  local args = split_top_level(inner)
  local ev = args[3] and args[3]:match("^'(.*)'$")
  if not ev or ev == "" then return nil end
  local el = args[4] and args[4]:match("^'(.*)'$") or ""
  return { event = ev, element = el }
end

-- `[HandlerFunctions('A,B')]` → { "A", "B" } or nil.
local function parse_handlers(line)
  local inner = line:match("%[%s*[Hh]andler[Ff]unctions%s*%(%s*'(.-)'%s*%)%s*%]")
  if not inner then return nil end
  local out = {}
  for n in inner:gmatch("[^,%s]+") do out[#out + 1] = n end
  return #out > 0 and out or nil
end

-- `Rec.Insert(` on the line at/after col → { qualifier, method, qcol } or nil.
local function record_call_at(line, col0)
  local masked = H.mask_strings(line)
  for qs, q, m in masked:gmatch('()([%w_]+)%.(%a+)%s*%(') do
    local trig = RECORD_TRIGGERS[m:lower()]
    local e = qs + #q + 1 + #m
    if trig and col0 + 1 >= qs and col0 + 1 <= e then
      return { qualifier = q, method = m, trigger = trig, qcol = qs }
    end
  end
  for qs, q, m in masked:gmatch('()([%w_]+)%.(%a+)%s*%(') do
    local trig = RECORD_TRIGGERS[m:lower()]
    if trig then return { qualifier = q, method = m, trigger = trig, qcol = qs } end
  end
  return nil
end

-- ── Buffer glue ──────────────────────────────────────────────────────────────

local function set_lines(bufnr, new_lines)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

local function diag_with_code(ctx, codes)
  for _, d in ipairs(ctx.diagnostics or {}) do
    if d.code and codes[tostring(d.code)] then return d end
  end
  return nil
end
M.diag_with_code = diag_with_code

-- Apply one AA-fix to `lines` for diagnostic `d` (vim.diagnostic shape,
-- 0-based lnum/col). Returns new lines or nil + reason.
local function apply_cop_fix(lines, d)
  local code = tostring(d.code)
  local lnum = d.lnum + 1
  if code == "AA0137" then
    return remove_unused_var(lines, lnum, first_quoted(d.message))
  elseif code == "AA0206" then
    return remove_assignment(lines, lnum)
  elseif code == "AA0008" then
    return add_parens(lines, lnum, d.col + 1, first_quoted(d.message))
  end
  return nil, "no fix for " .. code
end
M.COP_FIXES = { AA0137 = true, AA0206 = true, AA0008 = true }

function M.fix_cop_at_cursor(ctx, code)
  local d = diag_with_code(ctx, { [code] = true })
  if not d then return end
  local new, err = apply_cop_fix(ctx.lines, d)
  if not new then
    vim.notify("AL: " .. err, vim.log.levels.WARN)
    return
  end
  set_lines(ctx.bufnr, new)
end

-- :ALFixCops — analyze, then apply every AA0137/AA0206/AA0008 bottom-up per
-- file. Buffers are edited, not written; the quickfix lists what changed.
function M.fix_cops(root)
  root = root or require("al.lsp").get_root()
  if not root then
    vim.notify("AL: no AL project found", vim.log.levels.WARN)
    return
  end
  local compile = require("al.compile")
  vim.notify("AL: analyzing for fixable cop warnings…", vim.log.levels.INFO)
  compile.analyze_diagnostics(root, function(qf)
    local by_file = {}
    for _, item in ipairs(qf) do
      local code = (item.text or ""):match("^(%u%u%d%d%d%d)")
      if item.filename and M.COP_FIXES[code] then
        by_file[item.filename] = by_file[item.filename] or {}
        table.insert(by_file[item.filename], {
          code = code, lnum = (item.lnum or 1) - 1, col = (item.col or 1) - 1,
          message = item.text,
        })
      end
    end
    local changed = {}
    for file, diags in pairs(by_file) do
      -- Bottom-up so earlier fixes do not move later ones.
      table.sort(diags, function(a, b)
        if a.lnum ~= b.lnum then return a.lnum > b.lnum end
        return a.col > b.col
      end)
      local bufnr = vim.fn.bufadd(file)
      vim.fn.bufload(bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local n = 0
      for _, d in ipairs(diags) do
        local new = apply_cop_fix(lines, d)
        if new then
          lines = new
          n = n + 1
          changed[#changed + 1] = { filename = file, lnum = d.lnum + 1, col = d.col + 1,
                                    text = d.message }
        end
      end
      if n > 0 then set_lines(bufnr, lines) end
    end
    table.sort(changed, function(a, b)
      if a.filename ~= b.filename then return a.filename < b.filename end
      return a.lnum < b.lnum
    end)
    if #changed == 0 then
      vim.notify("AL: no fixable cop warnings (AA0137/AA0206/AA0008)", vim.log.levels.INFO)
      return
    end
    require("al.host").locations({ id = "alnvim.copfixes:" .. root,
      title = "AL: cop fixes applied", items = changed })
    vim.notify(("AL: applied %d cop fix(es) in %d file(s) — review and :wa"):format(
      #changed, vim.tbl_count(by_file)), vim.log.levels.INFO)
  end)
end

-- Option field under the cursor → new enum object, field retyped.
function M.refactor_to_enum(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local root  = require("al.lsp").get_root(bufnr)
  if not root then
    vim.notify("AL: no AL project found", vim.log.levels.WARN)
    return
  end
  local row   = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blk   = field_block(lines, row)
  if not blk then
    vim.notify("AL: cursor is not inside a field block", vim.log.levels.WARN)
    return
  end
  local default = blk.name or "NewEnum"
  vim.ui.input({ prompt = "Enum name: ", default = default }, function(name)
    if not name or vim.trim(name) == "" then return end
    name = vim.trim(name)
    local id = require("al.ids").next_id(root, "enum")
    if not id then
      vim.notify("AL: no free enum ID in app.json idRanges", vim.log.levels.ERROR)
      return
    end
    local new, etext = option_to_enum(lines, row, { name = name, id = id, extensible = opts.extensible })
    if not new then
      vim.notify("AL: " .. etext, vim.log.levels.WARN)
      return
    end
    local wizard = require("al.wizard")
    local dir, path = wizard.build_path(root, { key = "enum", file_type = "Enum" }, name)
    if vim.fn.filereadable(path) == 1 then
      vim.notify("AL: " .. path .. " already exists", vim.log.levels.ERROR)
      return
    end
    -- Edit the field first: write_and_open switches to the new file.
    set_lines(bufnr, new)
    vim.fn.mkdir(dir, "p")
    wizard.write_and_open(path, etext .. "\n")
  end)
end

-- ── Create procedure (AL0118 / AL0132) ──────────────────────────────────────

-- Hover each argument in parallel; cb(types) after all answer or the timeout.
local function arg_types(client, bufnr, row0, call, cb)
  local types, pending, done = {}, 0, false
  local timer = vim.uv.new_timer()
  local function finish()
    if done then return end
    done = true
    if not timer:is_closing() then timer:stop(); timer:close() end
    cb(types)
  end
  for i, a in ipairs(call.args) do
    local lit = literal_type(a.text)
    if lit then
      types[i] = lit
    elseif client and a.text:match("^[%w_\"%.]+$") then
      pending = pending + 1
      -- Hover the last segment (Cust."No." → the field), 0-based column.
      local seg_s = a.text:match('.*()"[^"]*"$') or a.text:match(".*()[%w_]+$") or 1
      local col0 = a.s - 1 + seg_s - 1 + (a.text:sub(seg_s, seg_s) == '"' and 1 or 0)
      require("al.basedef").hover_text(client, bufnr, row0, col0, function(text)
        types[i] = hover_type(text) or "Variant"
        pending = pending - 1
        if pending == 0 then finish() end
      end)
    else
      types[i] = "Variant"
    end
  end
  if pending == 0 then return finish() end
  timer:start(HOVER_TIMEOUT_MS, 0, vim.schedule_wrap(finish))
end

local function params_from(call, types)
  local params, seen = {}, {}
  for i, a in ipairs(call.args) do
    local name = param_name(a.text, i)
    local base, k = name, 1
    while seen[name:lower()] do k = k + 1; name = base .. k end
    seen[name:lower()] = true
    params[#params + 1] = { name = name, type = types[i] or literal_type(a.text) or "Variant" }
  end
  return params
end

-- Insert `proc_lines` after the procedure enclosing `row` (or before the
-- object's closing brace when outside one). Returns new lines and the line
-- the body cursor should land on.
local function insert_procedure(lines, row, proc_lines)
  local b = H.find_proc_bounds(lines, row)
  local at
  if b then
    at = b.fin
  else
    at = #lines
    while at > 1 and not lines[at]:match("^}") do at = at - 1 end
    at = at - 1
  end
  local out = vim.deepcopy(lines)
  local ins = { "" }
  vim.list_extend(ins, proc_lines)
  for i = #ins, 1, -1 do table.insert(out, at + 1, ins[i]) end
  return out, at + 1 + 3
end

function M.create_procedure(ctx)
  local d = diag_with_code(ctx, { AL0118 = true, AL0132 = true })
  local col = d and (d.col + 1) or (ctx.col0 + 1)
  local call = parse_call_args(ctx.line, col)
  if not call then
    -- The range may point at the qualifier; take the first call on the line.
    call = parse_call_args(ctx.line)
  end
  if not call then
    vim.notify("AL: no procedure call on this line", vim.log.levels.WARN)
    return
  end
  local client = require("al.lsp").client(ctx.bufnr)
  local row0   = ctx.row - 1
  local indent = (ctx.bounds and ctx.lines[ctx.bounds.hdr]:match("^(%s*)")) or "    "

  arg_types(client, ctx.bufnr, row0, call, function(types)
    local params = params_from(call, types)

    if not call.qualifier then
      local new, cursor = insert_procedure(ctx.lines, ctx.row,
        create_procedure_text(call.name, params, indent, true))
      set_lines(ctx.bufnr, new)
      pcall(vim.api.nvim_win_set_cursor, 0, { cursor, #indent + 4 })
      vim.cmd("startinsert!")
      return
    end

    -- Qualified: hover the qualifier to learn the object, then open it if it
    -- is project source. Symbol-package stubs are read-only copies.
    if not client then
      vim.notify("AL: no language server attached — cannot resolve " .. call.qualifier, vim.log.levels.WARN)
      return
    end
    local qs = H.mask_strings(ctx.line):find(vim.pesc(call.qualifier) .. '"?%.', 1) or call.name_s
    local basedef = require("al.basedef")
    basedef.hover_text(client, ctx.bufnr, row0, qs - 1, function(text)
      local obj = basedef.parse_hover(text)
      if not obj then
        vim.notify("AL: cannot resolve the type of " .. call.qualifier, vim.log.levels.WARN)
        return
      end
      if not ctx.root then
        vim.notify("AL: no project root", vim.log.levels.WARN)
        return
      end
      basedef.find_object(ctx.root, obj, function(file, _)
        if not file then
          vim.notify(("AL: %s \"%s\" has no source"):format(obj.kind, obj.name), vim.log.levels.WARN)
          return
        end
        local nf = vim.fs.normalize(file)
        if nf:sub(1, #ctx.root) ~= ctx.root then
          vim.notify(("AL: %s \"%s\" is a symbol package object, not project source — "
            .. "cannot add a procedure there"):format(obj.kind, obj.name), vim.log.levels.WARN)
          return
        end
        vim.cmd("normal! m'")
        vim.cmd("edit " .. vim.fn.fnameescape(file))
        local tb    = vim.api.nvim_get_current_buf()
        local tl    = vim.api.nvim_buf_get_lines(tb, 0, -1, false)
        local new, cursor = insert_procedure(tl, #tl, create_procedure_text(call.name, params, "    ", false))
        set_lines(tb, new)
        pcall(vim.api.nvim_win_set_cursor, 0, { cursor, 8 })
        vim.cmd("startinsert!")
      end)
    end)
  end)
end

-- ── Navigation ───────────────────────────────────────────────────────────────

local function rg_to_qf(cmd, label, title, cb)
  local explorer = require("al.explorer")
  explorer.rg_async(cmd, function(out)
    local items = {}
    for _, l in ipairs(out) do
      local file, lnum, text = l:match("^(.-):(%d+):(.*)$")
      if file then items[#items + 1] = { filename = file, lnum = tonumber(lnum), col = 1, text = vim.trim(text) } end
    end
    if cb then return cb(items) end
    if #items == 0 then
      vim.notify("AL: no " .. title .. " found for " .. label, vim.log.levels.INFO)
      return
    end
    if #items == 1 then
      vim.fn.setqflist({}, "r", { title = "AL: " .. title .. " — " .. label, items = items })
      vim.cmd("normal! m'")
      vim.cmd("cfirst")
    else
      require("al.host").locations({ id = "alnvim.related", items = items,
        title = "AL: " .. title .. " — " .. label })
    end
  end, label)
end

function M.find_publisher(ctx)
  local sub = parse_subscriber(ctx.line)
  if not sub then return end
  if not ctx.root then
    vim.notify("AL: no project root", vim.log.levels.WARN)
    return
  end
  local explorer = require("al.explorer")
  explorer.with_search_dirs(ctx.root, function(dirs)
  local cmd = { "rg", "-n", "-i", "--multiline", "--no-heading", "--glob", "*.{al,AL}",
                "-e", publisher_pattern(sub.event) }
  vim.list_extend(cmd, dirs)
  -- Multiline matches print every matched line; keep the procedure line.
  rg_to_qf(cmd, sub.event, "publisher", function(items)
    local procs = vim.tbl_filter(function(it) return it.text:lower():find("procedure", 1, true) ~= nil end, items)
    if #procs == 0 then
      vim.notify("AL: no publisher found for " .. sub.event, vim.log.levels.INFO)
      return
    end
    if #procs == 1 then
      vim.fn.setqflist({}, "r", { title = "AL: publisher — " .. sub.event, items = procs })
      vim.cmd("normal! m'"); vim.cmd("cfirst")
    else
      require("al.host").locations({ id = "alnvim.related", items = procs,
        title = "AL: publisher — " .. sub.event })
    end
  end)
  end)
end

function M.find_handlers(ctx)
  local names = parse_handlers(ctx.line)
  if not names or not ctx.root then return end
  local cmd = { "rg", "-n", "-i", "--no-heading", "--glob", "*.{al,AL}" }
  for _, n in ipairs(names) do vim.list_extend(cmd, { "-e", procedure_pattern(n) }) end
  cmd[#cmd + 1] = ctx.root
  rg_to_qf(cmd, table.concat(names, ", "), "handler")
end

function M.find_trigger(ctx)
  local rc = record_call_at(ctx.line, ctx.col0)
  if not rc then return end
  local client = require("al.lsp").client(ctx.bufnr)
  if not client or not ctx.root then
    vim.notify("AL: no language server attached — cannot resolve " .. rc.qualifier, vim.log.levels.WARN)
    return
  end
  local basedef = require("al.basedef")
  basedef.hover_text(client, ctx.bufnr, ctx.row - 1, rc.qcol - 1, function(text)
    local obj = basedef.parse_hover(text)
    if not obj or obj.kind ~= "table" then
      vim.notify("AL: " .. rc.qualifier .. " is not a record", vim.log.levels.WARN)
      return
    end
    basedef.find_object(ctx.root, obj, function(file, lnum)
      if not file then
        vim.notify(("AL: table \"%s\" has no source in its symbol package"):format(obj.name), vim.log.levels.INFO)
        return
      end
      local ok, flines = pcall(vim.fn.readfile, file)
      local tl = ok and basedef.member_line(flines, rc.trigger)
      if not tl then
        vim.notify(("AL: table \"%s\" has no %s trigger"):format(obj.name, rc.trigger), vim.log.levels.INFO)
        return
      end
      vim.fn.setqflist({}, "r", { title = "AL: " .. rc.trigger .. " — " .. obj.name,
        items = { { filename = file, lnum = tl, col = 1, text = vim.trim(flines[tl]) } } })
      vim.cmd("normal! m'")
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      if vim.fs.normalize(file):sub(1, #ctx.root) ~= ctx.root then
        vim.bo.readonly, vim.bo.modifiable = true, false
      end
      pcall(vim.api.nvim_win_set_cursor, 0, { tl, 0 })
      vim.cmd("normal! ^zz")
      _ = lnum
    end)
  end)
end

-- Applicability predicates for codeactions.lua.
M.has_subscriber = function(ctx) return parse_subscriber(ctx.line) ~= nil end
M.has_handlers   = function(ctx) return parse_handlers(ctx.line) ~= nil end
M.has_record_call = function(ctx) return record_call_at(ctx.line, ctx.col0) ~= nil end
M.in_option_field = function(ctx)
  local blk = field_block(ctx.lines, ctx.row)
  return blk ~= nil and H.mask_strings(ctx.lines[blk.s]):match(";%s*[Oo]ption%s*%)") ~= nil
end

-- Pure internals for tests/ only. Not API.
M._test = {
  parse_call_args = parse_call_args, split_top_level = split_top_level,
  create_procedure_text = create_procedure_text, hover_type = hover_type,
  remove_unused_var = remove_unused_var, remove_assignment = remove_assignment,
  add_parens = add_parens, option_to_enum = option_to_enum, field_block = field_block,
  publisher_pattern = publisher_pattern, procedure_pattern = procedure_pattern,
  parse_subscriber = parse_subscriber, parse_handlers = parse_handlers,
  record_call_at = record_call_at, insert_procedure = insert_procedure,
  params_from = params_from, apply_cop_fix = apply_cop_fix,
}

return M
