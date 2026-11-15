-- AL code refactoring utilities.
--
-- Interactive entry points (M.extract_label, M.extract_to_procedure, …) read
-- the buffer, then call pure string-array functions (M.to_validate,
-- M.make_var_global, M.add_publishers, …) that take `lines` and return new
-- lines or (nil, reason). The pure functions are what tests/refactor_spec.lua
-- exercises; the shared parsers live in M.helpers for lua/al/codeactions.lua.

local M = {}
local lsp_mod = require("al.lsp")

-- ── String detection ──────────────────────────────────────────────────────────

-- Find the single-quoted AL string containing col (0-based).
-- AL uses '' as an escaped single-quote inside strings.
-- Returns text (without quotes), or nil.
local function find_quoted_string(line, col)
  local cursor = col + 1  -- 1-based
  local i = 1
  while i <= #line do
    if line:sub(i, i) == "'" then
      local j = i + 1
      while j <= #line do
        if line:sub(j, j) == "'" then
          if line:sub(j + 1, j + 1) == "'" then
            j = j + 2  -- escaped quote inside string
          else
            break
          end
        else
          j = j + 1
        end
      end
      if j > #line then break end  -- unclosed string, stop scanning
      if cursor >= i and cursor <= j then
        return line:sub(i + 1, j - 1)
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return nil
end

-- ── Procedure boundary detection ──────────────────────────────────────────────

-- Estimate begin/end nesting delta for one line.
-- 'case ... of' contributes +1 because it has an unmatched 'end'.
local function line_depth(line)
  local low = vim.trim(line):lower()
  local d   = 0
  for _ in low:gmatch('%f[%a]begin%f[%A]') do d = d + 1 end
  if low:match('%f[%a]case%f[%A]') and low:match('%f[%a]of%f[%A]') then d = d + 1 end
  for _ in low:gmatch('%f[%a]end%f[%A]')   do d = d - 1 end
  return d
end

local PROC_PATS = {
  '^%s+[Pp]rocedure%s',
  '^%s+[Ll]ocal%s+[Pp]rocedure%s',
  '^%s+[Tt]rigger%s',
}

local function is_proc_line(line)
  for _, p in ipairs(PROC_PATS) do
    if line:match(p) then return true end
  end
  return false
end

-- Find enclosing procedure/trigger for cursor_lnum (1-based).
-- Returns { hdr, var, beg, fin } (all 1-based) or nil.
--   hdr = procedure/trigger header line
--   var = 'var' keyword line (nil if no var block)
--   beg = 'begin' line
--   fin = closing 'end[;]' line
local function find_proc_bounds(lines, cursor_lnum)
  local phdr = nil
  for i = cursor_lnum, 1, -1 do
    if is_proc_line(lines[i]) then phdr = i; break end
  end
  if not phdr then return nil end

  local var_lnum, begin_lnum, end_lnum = nil, nil, nil
  local depth = 0

  for i = phdr + 1, #lines do
    local t = vim.trim(lines[i]):lower()
    if not begin_lnum then
      if is_proc_line(lines[i]) then break end  -- next proc, give up
      if     t == 'var'   then var_lnum   = i
      elseif t == 'begin' then begin_lnum = i; depth = 1
      end
    else
      depth = depth + line_depth(lines[i])
      if depth <= 0 then end_lnum = i; break end
    end
  end

  if not begin_lnum or not end_lnum then return nil end
  return { hdr = phdr, var = var_lnum, beg = begin_lnum, fin = end_lnum }
end

-- Find global (object-level) var block.
-- Returns (var_lnum, first_proc_lnum).
-- var_lnum is nil if no global var block exists.
-- first_proc_lnum is the first procedure/trigger line (or #lines+1 if none).
local function global_var_info(lines)
  local first_proc = #lines + 1
  for i, line in ipairs(lines) do
    if is_proc_line(line) then first_proc = i; break end
  end
  local var_lnum = nil
  for i = 1, first_proc - 1 do
    if vim.trim(lines[i]):lower() == 'var' then var_lnum = i; break end
  end
  return var_lnum, first_proc
end

-- ── Name suggestion ───────────────────────────────────────────────────────────

local function suggest_name(text)
  local parts = {}
  for word in text:gmatch('[%a%d]+') do
    table.insert(parts, word:sub(1, 1):upper() .. word:sub(2):lower())
    if #parts >= 4 then break end
  end
  local base = table.concat(parts)
  return (base ~= '' and base or 'MyLabel') .. 'Lbl'
end

-- ── Extract-to-procedure helpers ─────────────────────────────────────────────

-- Parse the local var block (lines var_lnum+1 .. beg_lnum-1, 1-based) into a
-- map keyed on lower-case name.  Skips Label/TextConst (can't be parameters).
local function parse_var_map(lines, var_lnum, beg_lnum)
  local vars = {}
  if not var_lnum then return vars end
  for i = var_lnum + 1, beg_lnum - 1 do
    local line = (lines[i] or ""):gsub("\r$", "")
    -- Greedy (.+) to handle Label 'text; with semicolons', Locked = true;
    local name, type_str = line:match("^%s*([%a_][%w_]*)%s*:%s*(.+)%s*;%s*$")
    if name and type_str then
      type_str = vim.trim(type_str)
      local tl = type_str:lower()
      -- Labels and TextConst are compile-time constants, not passable as params
      if not (tl:match("^label[%s']") or tl:match("^textconst%s")) then
        vars[name:lower()] = { name = name, type_str = type_str }
      end
    end
  end
  return vars
end

-- True when a variable should become a 'var' (by-reference) parameter.
-- Records, arrays, lists, dictionaries always pass by reference (AL convention).
-- Any type that is assigned inside the selection also needs var.
local function needs_var_param(var_info, sel_lines)
  local tl = var_info.type_str:lower()
  if tl:match("^record%s") or tl:match("^temporary%s") then return true end
  if tl:match("^list%s")   or tl:match("^dictionary%s")  then return true end
  if tl:match("^array%s*%[")                              then return true end
  local nl = vim.pesc(var_info.name:lower())
  for _, line in ipairs(sel_lines) do
    if line:lower():match(nl .. "%s*:=") then return true end
  end
  return false
end

-- Collect variables from var_map that are referenced in sel_lines (in order).
local function collect_params(sel_lines, var_map)
  local seen, params = {}, {}
  for _, line in ipairs(sel_lines) do
    line = line:gsub("\r$", "")
    if vim.trim(line):sub(1, 2) ~= "//" then  -- skip comment lines
      for word in line:gmatch("[%a_][%w_]*") do
        local lower = word:lower()
        if var_map[lower] and not seen[lower] then
          seen[lower] = true
          local v = var_map[lower]
          table.insert(params, {
            name     = v.name,
            type_str = v.type_str,
            is_var   = needs_var_param(v, sel_lines),
          })
        end
      end
    end
  end
  return params
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Extract the current visual selection into a new local procedure.
-- Uses '< / '> marks so call via <cmd> from a { "n", "v" } keymap.
function M.extract_to_procedure()
  local bufnr = vim.api.nvim_get_current_buf()

  local sel_start = vim.api.nvim_buf_get_mark(bufnr, "<")[1]  -- 1-based
  local sel_end   = vim.api.nvim_buf_get_mark(bufnr, ">")[1]  -- 1-based
  if sel_start == 0 then
    vim.notify("AL: select code lines first (visual mode), then run ALExtractProcedure",
      vim.log.levels.WARN)
    return
  end
  if sel_start > sel_end then sel_start, sel_end = sel_end, sel_start end

  local lines     = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sel_lines = vim.list_slice(lines, sel_start, sel_end)  -- 1-indexed, inclusive

  local bounds = find_proc_bounds(lines, sel_start)
  if not bounds then
    vim.notify("AL: selection is not inside a procedure or trigger", vim.log.levels.WARN)
    return
  end
  if sel_start <= bounds.beg or sel_end >= bounds.fin then
    vim.notify("AL: selection must be inside the procedure body (between begin and end)",
      vim.log.levels.WARN)
    return
  end

  local var_map   = parse_var_map(lines, bounds.var, bounds.beg)
  local params    = collect_params(sel_lines, var_map)
  local proc_indent = lines[bounds.hdr]:match("^(%s*)") or "    "
  local body_indent = proc_indent .. "    "

  -- Minimum indentation across non-blank selection lines (for re-indenting body)
  local min_ind = math.huge
  for _, ln in ipairs(sel_lines) do
    if vim.trim(ln) ~= "" then
      local sp = #(ln:match("^(%s*)"))
      if sp < min_ind then min_ind = sp end
    end
  end
  if min_ind == math.huge then min_ind = 0 end

  vim.ui.input({ prompt = "Procedure name: " }, function(proc_name)
    if not proc_name or vim.trim(proc_name) == "" then return end
    proc_name = vim.trim(proc_name)

    vim.schedule(function()
      -- Re-read lines in case the buffer changed while the input was open
      local buf = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local b   = find_proc_bounds(buf, sel_start)
      if not b then
        vim.notify("AL: could not re-locate procedure bounds", vim.log.levels.ERROR)
        return
      end

      -- Call line: same indentation as the first selected line
      local call_indent = buf[sel_start]:match("^(%s*)") or body_indent
      local arg_list    = table.concat(
        vim.tbl_map(function(p) return p.name end, params), ", ")
      local call_line   = call_indent .. proc_name .. "(" .. arg_list .. ");"

      -- Procedure signature
      local sig_parts = {}
      for _, p in ipairs(params) do
        sig_parts[#sig_parts + 1] = (p.is_var and "var " or "") .. p.name .. ": " .. p.type_str
      end
      local sig = proc_indent .. "local procedure " .. proc_name
        .. "(" .. table.concat(sig_parts, "; ") .. ")"

      -- Body lines: strip min_ind, add body_indent (preserves relative indentation)
      local body = {}
      for _, ln in ipairs(sel_lines) do
        local stripped = (#ln >= min_ind) and ln:sub(min_ind + 1) or vim.trim(ln)
        body[#body + 1] = body_indent .. stripped
      end

      local new_proc = { "", sig, proc_indent .. "begin" }
      vim.list_extend(new_proc, body)
      new_proc[#new_proc + 1] = proc_indent .. "end;"

      -- Insert AFTER b.fin first (bottom-up → sel line numbers stay valid)
      vim.api.nvim_buf_set_lines(bufnr, b.fin, b.fin, false, new_proc)
      -- Replace selection with call
      vim.api.nvim_buf_set_lines(bufnr, sel_start - 1, sel_end, false, { call_line })

      vim.notify(
        string.format("AL: extracted %d line%s → %s (%d param%s)",
          sel_end - sel_start + 1,
          sel_end - sel_start + 1 == 1 and "" or "s",
          proc_name, #params, #params == 1 and "" or "s"),
        vim.log.levels.INFO)
    end)
  end)
end

-- Find the double-quoted AL identifier containing the cursor.
-- Returns the name string (without quotes), or nil when the cursor is not
-- inside one.
--
-- Quotes are paired left to right, mirroring find_quoted_string above. The
-- previous version scanned *leftwards* for the nearest '"' and treated it as
-- the opening delimiter, so a cursor sitting on a closing quote paired that
-- quote with the next string's opening quote:
--   Rec.Get("Foo"); Other("Bar")
--            ^ cursor here yielded  '); Other('  as the identifier to rename.
local function dquoted_id_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  if not line then return nil end
  local cursor = col + 1  -- 1-based

  local i = 1
  while i <= #line do
    if line:sub(i, i) == '"' then
      local j = i + 1
      while j <= #line do
        if line:sub(j, j) == '"' then
          if line:sub(j + 1, j + 1) == '"' then
            j = j + 2   -- "" escapes a quote inside a quoted identifier
          else
            break
          end
        else
          j = j + 1
        end
      end
      if j > #line then break end   -- unterminated identifier, stop scanning
      if cursor >= i and cursor <= j then
        local name = line:sub(i + 1, j - 1)
        return name ~= '' and name or nil
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return nil
end

-- Rename a quoted AL identifier (object name, field name, etc.) project-wide.
-- The AL server tokenises by word boundaries, so standard LSP rename breaks for
-- multi-word identifiers like "Inv. Status TSG". This command:
--   1. Extracts the full "Name" at cursor (double-quote delimited).
--   2. Prompts for the new name.
--   3. Greps all .al files in the project for "Name" (literal) and replaces.
-- Falls back to vim.lsp.buf.rename() when cursor is not inside a quoted identifier.
function M.rename_object()
  local root = lsp_mod.get_root()
  if not root then
    vim.notify('AL: no project root found', vim.log.levels.WARN)
    return
  end

  local old_name = dquoted_id_at_cursor()
  if not old_name then
    vim.lsp.buf.rename()
    return
  end

  vim.ui.input({ prompt = 'Rename "' .. old_name .. '" to: ', default = old_name }, function(new_name)
    if not new_name or vim.trim(new_name) == '' or new_name == old_name then return end
    new_name = vim.trim(new_name)
    vim.schedule(function()
      local rg_out = vim.fn.system({
        'rg', '--files-with-matches', '--fixed-strings',
        '--glob', '*.al', '"' .. old_name .. '"', root,
      })
      local files = {}
      for _, f in ipairs(vim.split(vim.trim(rg_out), '\n', { plain = true })) do
        if f ~= '' then table.insert(files, f) end
      end
      if #files == 0 then
        vim.notify('AL rename: "' .. old_name .. '" not found in project .al files', vim.log.levels.WARN)
        return
      end
      local old_pat = '"' .. vim.pesc(old_name) .. '"'
      -- Escape % in the replacement — gsub treats it as a capture reference
      -- (AL names like "Profit %" are legal).
      local new_str = ('"' .. new_name .. '"'):gsub("%%", "%%%%")
      local changed = 0
      for _, fpath in ipairs(files) do
        local bufnr2 = vim.fn.bufadd(fpath)
        vim.fn.bufload(bufnr2)
        local lines = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
        local modified = false
        for i, ln in ipairs(lines) do
          local new_ln = ln:gsub(old_pat, new_str)
          if new_ln ~= ln then lines[i] = new_ln; modified = true end
        end
        if modified then
          vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, lines)
          changed = changed + 1
        end
      end
      vim.notify(string.format(
        'AL rename: "%s" → "%s" in %d file(s) — :wa to save all',
        old_name, new_name, changed), vim.log.levels.INFO)
    end)
  end)
end

-- Build a Label declaration. Locked only when asked: a translatable label is
-- the default, and `Locked = true` used to be emitted unconditionally, so
-- every extracted label silently dropped out of translation.
local function label_decl(var_name, text, locked)
  local d = var_name .. ": Label '" .. text .. "'"
  if locked then d = d .. ", Locked = true" end
  return d .. ";"
end

-- Insert a variable declaration into `lines` (pure; returns new array).
--   scope = "local"  → the procedure `bounds` (find_proc_bounds result)
--   scope = "global" → the object-level var block (created before the first
--                      procedure when absent)
-- Existing blocks get the declaration appended after their last non-blank
-- line, at that line's indentation.
local function insert_var_decl(lines, scope, decl, bounds)
  local out = vim.deepcopy(lines)
  local function indent_of(l) return (l or ""):match("^(%s*)") or "" end

  if scope == "global" then
    local gvar, ins = global_var_info(out)
    if gvar then
      local var_end = gvar
      for i = gvar + 1, ins - 1 do
        if vim.trim(out[i]) ~= "" then var_end = i end
      end
      local ind = (var_end > gvar) and indent_of(out[var_end]) or (indent_of(out[gvar]) .. "    ")
      table.insert(out, var_end + 1, ind .. decl)
    else
      local ind = (ins <= #out) and indent_of(out[ins]) or "    "
      table.insert(out, ins, ind .. "    " .. decl)
      table.insert(out, ins, ind .. "var")
      table.insert(out, ins, "")
    end
    return out
  end

  assert(bounds, "insert_var_decl: local scope needs bounds")
  local beg_ind  = indent_of(out[bounds.beg])
  local decl_ind = beg_ind .. "    "
  if bounds.var then
    local var_end = bounds.var
    for i = bounds.var + 1, bounds.beg - 1 do
      if vim.trim(out[i]) ~= "" then var_end = i end
    end
    local ind = (var_end > bounds.var) and indent_of(out[var_end]) or decl_ind
    table.insert(out, var_end + 1, ind .. decl)
  else
    table.insert(out, bounds.beg, decl_ind .. decl)
    table.insert(out, bounds.beg, beg_ind .. "var")
  end
  return out
end

-- opts.locked → `Locked = true` on the generated Label (default: translatable).
function M.extract_label(opts)
  opts = opts or {}
  local bufnr   = vim.api.nvim_get_current_buf()
  local pos     = vim.api.nvim_win_get_cursor(0)
  local lnum    = pos[1]   -- 1-based
  local col     = pos[2]   -- 0-based
  local curline = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''

  local text = find_quoted_string(curline, col)
  if not text then
    vim.notify('AL: cursor is not inside a single-quoted string', vim.log.levels.WARN)
    return
  end

  local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local bounds = find_proc_bounds(lines, lnum)
  if not bounds then
    vim.notify('AL: cursor must be inside a procedure or trigger', vim.log.levels.WARN)
    return
  end
  if lnum < bounds.beg or lnum > bounds.fin then
    vim.notify('AL: cursor must be inside the procedure body (between begin/end)', vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = 'Label variable name: ', default = suggest_name(text) }, function(var_name)
    if not var_name or vim.trim(var_name) == '' then return end
    var_name = vim.trim(var_name)

    vim.ui.select(
      { 'Local (current procedure)', 'Global (object level)' },
      { prompt = 'Scope for ' .. var_name .. ':' },
      function(choice)
        if not choice then return end
        local is_global = choice:match('^Global') ~= nil

        vim.schedule(function()
          local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local b = find_proc_bounds(buf_lines, lnum)
          if not b then
            vim.notify('AL: could not re-locate procedure bounds', vim.log.levels.ERROR)
            return
          end

          -- 1. Replace all occurrences in the body (same line count).
          local pat   = "'" .. vim.pesc(text) .. "'"
          local count = 0
          for i = b.beg, b.fin do
            local n = 0
            buf_lines[i] = buf_lines[i]:gsub(pat, function() n = n + 1; return var_name end)
            count = count + n
          end

          -- 2. Insert the declaration.
          local decl = label_decl(var_name, text, opts.locked)
          local new_lines = insert_var_decl(buf_lines, is_global and "global" or "local", decl, b)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

          vim.notify(
            string.format('AL: "%s" → %s (%d occurrence%s)',
              text, var_name, count, count == 1 and '' or 's'),
            vim.log.levels.INFO)
        end)
      end)
  end)
end

-- ── Pure refactors (string arrays in, string arrays out) ─────────────────────

-- Split `line` into code and string segments by pairing quotes left to right.
-- Returns a copy of the line where every quoted span (single or double) is
-- replaced by spaces of the same length, so pattern matches on the result
-- never land inside a string, yet positions still map onto the original.
local function mask_strings(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == "'" or c == '"' then
      local j = i + 1
      while j <= n do
        if line:sub(j, j) == c then
          if line:sub(j + 1, j + 1) == c then j = j + 2 else break end
        else
          j = j + 1
        end
      end
      if j > n then
        -- unterminated: mask to end of line
        out[#out + 1] = string.rep(" ", n - i + 1)
        i = n + 1
      else
        out[#out + 1] = string.rep(" ", j - i + 1)
        i = j + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Parse `X := Y;` on one line. Returns indent, lhs, rhs (all trimmed) or
-- nil, reason. Compound assignments (+= -= *= /=) are not simple assignments.
local function parse_assignment(line)
  local masked = mask_strings(line)
  if not masked:match(";%s*$") then
    return nil, "statement does not end on this line (multi-line statements are not supported)"
  end
  local s, e = masked:find(":=", 1, true)
  if not s then
    if masked:match("[%+%-%*/]=") then return nil, "compound assignment (+= etc.) is not a simple assignment" end
    return nil, "no `:=` assignment on this line"
  end
  if masked:find(":=", e + 1, true) then return nil, "more than one `:=` on this line" end
  local indent = line:match("^(%s*)")
  local lhs = vim.trim(line:sub(1, s - 1))
  local rhs = vim.trim(line:sub(e + 1):gsub(";%s*$", ""))
  if lhs == "" or rhs == "" then return nil, "incomplete assignment" end
  return indent, lhs, rhs
end

-- Split `Rec."Field"` / `Rec.Field` into receiver and member on the last dot
-- outside quotes. A bare `Field` returns nil receiver.
local function split_member(expr)
  local masked = mask_strings(expr)
  local last = nil
  local i = 0
  while true do
    i = masked:find(".", i + 1, true)
    if not i then break end
    last = i
  end
  if not last then return nil, expr end
  return expr:sub(1, last - 1), expr:sub(last + 1)
end

-- `X := Y;` → `Validate(X, Y);` — with a receiver, `Rec."No." := V;` becomes
-- `Rec.Validate("No.", V);`. Each line is one statement.
function M.to_validate(sel_lines)
  local out = {}
  for _, line in ipairs(sel_lines) do
    local indent, lhs, rhs = parse_assignment(line)
    if not indent then return nil, lhs end
    local recv, member = split_member(lhs)
    if recv then
      out[#out + 1] = string.format("%s%s.Validate(%s, %s);", indent, recv, member, rhs)
    else
      out[#out + 1] = string.format("%sValidate(%s, %s);", indent, member, rhs)
    end
  end
  return out
end

-- `X := Y;` → `Evaluate(X, Y);`
function M.to_evaluate(sel_lines)
  local out = {}
  for _, line in ipairs(sel_lines) do
    local indent, lhs, rhs = parse_assignment(line)
    if not indent then return nil, lhs end
    out[#out + 1] = string.format("%sEvaluate(%s, %s);", indent, lhs, rhs)
  end
  return out
end

-- Move the local variable declared on `cursor` (1-based) to the global var
-- block. Drops the local `var` keyword when the block becomes empty.
function M.make_var_global(lines, cursor)
  local b = find_proc_bounds(lines, cursor)
  if not b then return nil, "cursor is not inside a procedure or trigger" end
  if not b.var or cursor <= b.var or cursor >= b.beg then
    return nil, "cursor is not on a local variable declaration"
  end
  local decl = vim.trim(lines[cursor])
  if not decl:match("^[%a_][%w_]*%s*:") and not decl:match('^"[^"]+"%s*:') then
    return nil, "line is not a variable declaration"
  end

  -- Remove the local line (and a now-empty var block) first: both sit below
  -- the global block, so the global insertion point is unaffected.
  local out = vim.deepcopy(lines)
  table.remove(out, cursor)
  local remaining = false
  for i = b.var + 1, b.beg - 2 do
    if vim.trim(out[i]) ~= "" then remaining = true; break end
  end
  if not remaining then
    for i = b.beg - 2, b.var, -1 do table.remove(out, i) end
  end
  return insert_var_decl(out, "global", decl)
end

-- Parse `[local ]procedure Name(params)[: Ret]` on one line. Returns
-- { name, params = { { text, is_var, name } }, indent } or nil.
local function parse_proc_header(line)
  local indent, name, plist = line:match("^(%s*)[Ll]ocal%s+[Pp]rocedure%s+([%w_\"%. ]-)%s*%((.-)%)")
  if not name then
    indent, name, plist = line:match("^(%s*)[Pp]rocedure%s+([%w_\"%. ]-)%s*%((.-)%)")
  end
  if not name then return nil end
  local params = {}
  for p in (plist or ""):gmatch("[^;]+") do
    p = vim.trim(p)
    if p ~= "" then
      local is_var = p:lower():match("^var%s") ~= nil
      local pname = p:gsub("^[Vv]ar%s+", ""):match("^([^:]+):")
      params[#params + 1] = { text = p, is_var = is_var, name = vim.trim(pname or p) }
    end
  end
  return { name = name, params = params, indent = indent }
end

local function codeactions_config()
  local al = package.loaded["al"]
  local cfg = al and al.config and al.config.codeactions or {}
  return {
    publisher_var_params  = cfg.publisher_var_params ~= false,
    initialize_is_handled = cfg.initialize_is_handled ~= false,
  }
end

-- Add OnBefore<Name>/OnAfter<Name> integration-event publishers for the
-- procedure whose header is on `hdr_lnum`, and call them from its body.
--   opts.publisher_var_params  — pass every parameter as `var` (default true)
--   opts.initialize_is_handled — emit `IsHandled := false;` first (default true)
function M.add_publishers(lines, hdr_lnum, opts)
  opts = vim.tbl_extend("keep", opts or {}, codeactions_config())
  local hdr = parse_proc_header(lines[hdr_lnum] or "")
  if not hdr then return nil, "line is not a procedure header" end
  local b = find_proc_bounds(lines, hdr_lnum)
  if not b or b.hdr ~= hdr_lnum then return nil, "could not find the procedure body" end

  local before_name, after_name = "OnBefore" .. hdr.name, "OnAfter" .. hdr.name
  for _, l in ipairs(lines) do
    if l:match("%f[%w_]" .. vim.pesc(before_name) .. "%s*%(") then
      return nil, before_name .. " already exists"
    end
  end

  local sig, args = {}, {}
  for _, p in ipairs(hdr.params) do
    local text = p.text
    if opts.publisher_var_params and not p.is_var then text = "var " .. text end
    sig[#sig + 1]   = text
    args[#args + 1] = p.name
  end
  local before_sig = vim.deepcopy(sig); before_sig[#before_sig + 1] = "var IsHandled: Boolean"
  local before_args = vim.deepcopy(args); before_args[#before_args + 1] = "IsHandled"

  local ind      = hdr.indent
  local body_ind = ind .. "    "
  local function publisher(name, s)
    return {
      "",
      ind .. "[IntegrationEvent(false, false)]",
      ind .. "local procedure " .. name .. "(" .. table.concat(s, "; ") .. ")",
      ind .. "begin",
      ind .. "end;",
    }
  end

  local out = vim.deepcopy(lines)
  -- Bottom-up: publishers after end; OnAfter call before end; OnBefore block
  -- after begin; IsHandled declaration in the var block.
  local tail = publisher(before_name, before_sig)
  vim.list_extend(tail, publisher(after_name, sig))
  for i = #tail, 1, -1 do table.insert(out, b.fin + 1, tail[i]) end

  table.insert(out, b.fin, body_ind .. after_name .. "(" .. table.concat(args, ", ") .. ");")

  local head = {}
  if opts.initialize_is_handled then head[#head + 1] = body_ind .. "IsHandled := false;" end
  head[#head + 1] = body_ind .. before_name .. "(" .. table.concat(before_args, ", ") .. ");"
  head[#head + 1] = body_ind .. "if IsHandled then"
  head[#head + 1] = body_ind .. "    exit;"
  head[#head + 1] = ""
  for i = #head, 1, -1 do table.insert(out, b.beg + 1, head[i]) end

  return insert_var_decl(out, "local", "IsHandled: Boolean;", b)
end

-- Fixed signatures for test handler attributes.
M.HANDLER_SIGNATURES = {
  MessageHandler            = "(Message: Text[1024])",
  ConfirmHandler            = "(Question: Text[1024]; var Reply: Boolean)",
  StrMenuHandler            = "(Options: Text[1024]; var Choice: Integer; Instruction: Text[1024])",
  PageHandler               = '(var TestPage: TestPage "MyPage")',
  ModalPageHandler          = '(var TestPage: TestPage "MyPage")',
  RequestPageHandler        = '(var RequestPage: TestRequestPage "MyReport")',
  ReportHandler             = '(var Report: Report "MyReport")',
  FilterPageHandler         = "(var RecRef: RecordRef): Boolean",
  SendNotificationHandler   = "(var Notification: Notification): Boolean",
  RecallNotificationHandler = "(var Notification: Notification): Boolean",
  HyperlinkHandler          = "(Message: Text[1024])",
  SessionSettingsHandler    = "(var TestSessionSettings: SessionSettings): Boolean",
}
M.HANDLER_KINDS = vim.tbl_keys(M.HANDLER_SIGNATURES)
table.sort(M.HANDLER_KINDS)

-- From a `[HandlerFunctions('A,B')]` attribute on `cursor`, list the handler
-- names with no `procedure <Name>(` in `lines`. Returns { missing = {...},
-- proc_fin = <end line of the attributed test procedure> } or nil, reason.
function M.missing_handlers(lines, cursor)
  local line = lines[cursor] or ""
  local list = line:match("%[HandlerFunctions%s*%(%s*'([^']*)'%s*%)%s*%]")
  if not list then return nil, "line has no [HandlerFunctions('…')] attribute" end
  local b = nil
  for i = cursor + 1, math.min(#lines, cursor + 5) do
    if is_proc_line(lines[i]) then b = find_proc_bounds(lines, i); break end
  end
  if not b then return nil, "no procedure follows the attribute" end
  local missing = {}
  for name in list:gmatch("[^,]+") do
    name = vim.trim(name)
    if name ~= "" then
      local found = false
      for _, l in ipairs(lines) do
        if l:match("[Pp]rocedure%s+" .. vim.pesc(name) .. "%s*%(") then found = true; break end
      end
      if not found then missing[#missing + 1] = name end
    end
  end
  return { missing = missing, proc_fin = b.fin, indent = lines[b.hdr]:match("^(%s*)") or "    " }
end

-- Insert a stub `[<kind>] procedure <name><signature>` after `after_lnum`.
function M.create_handler_function(lines, name, kind, after_lnum, indent)
  local sig = M.HANDLER_SIGNATURES[kind]
  if not sig then return nil, "unknown handler kind " .. tostring(kind) end
  indent = indent or "    "
  local stub = {
    "",
    indent .. "[" .. kind .. "]",
    indent .. "procedure " .. name .. sig,
    indent .. "begin",
    indent .. "end;",
  }
  local out = vim.deepcopy(lines)
  for i = #stub, 1, -1 do table.insert(out, after_lnum + 1, stub[i]) end
  return out
end

-- Index of the `}` closing the block whose header is on `start` (the `{` may
-- be on the header line or a following one). Braces inside strings ignored.
local function block_end(lines, start)
  local depth, opened = 0, false
  for i = start, #lines do
    local m = mask_strings(lines[i])
    for ch in m:gmatch("[{}]") do
      if ch == "{" then depth = depth + 1; opened = true
      else depth = depth - 1 end
      if opened and depth == 0 then return i end
    end
  end
  return nil
end

-- Promote the `action(<Name>)` on `cursor`: add an actionref to
-- `area(Promoted)` of the enclosing `actions` block, creating the area and a
-- `group(Category_Process)` when absent.
function M.promote_action(lines, cursor)
  local name = (lines[cursor] or ""):match("^%s*action%s*%(%s*(.-)%s*%)")
  if not name or name == "" then return nil, "cursor is not on an action(<Name>) line" end
  local bare = name:gsub('"', ""):gsub("[^%w_]", "")
  local ref_name = bare .. "_Promoted"

  local actions_lnum = nil
  for i = cursor, 1, -1 do
    if vim.trim(lines[i]):lower() == "actions" then actions_lnum = i; break end
  end
  if not actions_lnum then return nil, "no enclosing actions block" end
  local actions_end = block_end(lines, actions_lnum)
  if not actions_end or actions_end < cursor then return nil, "could not find the end of the actions block" end

  for i = actions_lnum, actions_end do
    if lines[i]:match("actionref%s*%(.-;%s*" .. vim.pesc(name) .. "%s*%)") then
      return nil, name .. " is already promoted"
    end
  end

  local a_ind = lines[actions_lnum]:match("^(%s*)") or ""
  local i1, i2, i3 = a_ind .. "    ", a_ind .. "        ", a_ind .. "            "
  local out = vim.deepcopy(lines)

  local area_lnum = nil
  for i = actions_lnum, actions_end do
    if lines[i]:lower():match("^%s*area%s*%(%s*promoted%s*%)") then area_lnum = i; break end
  end

  local function ins(at, new)
    for k = #new, 1, -1 do table.insert(out, at, new[k]) end
  end

  if not area_lnum then
    ins(actions_end, {
      i1 .. "area(Promoted)",
      i1 .. "{",
      i2 .. "group(Category_Process)",
      i2 .. "{",
      i3 .. "actionref(" .. ref_name .. "; " .. name .. ")",
      i3 .. "{",
      i3 .. "}",
      i2 .. "}",
      i1 .. "}",
    })
    return out
  end

  local area_end = block_end(lines, area_lnum)
  if not area_end then return nil, "could not find the end of area(Promoted)" end
  local group_lnum = nil
  for i = area_lnum + 1, area_end do
    if lines[i]:match("^%s*group%s*%(") then group_lnum = i; break end
  end
  if group_lnum then
    local group_end = block_end(lines, group_lnum)
    local g_ind = lines[group_lnum]:match("^(%s*)") or i2
    ins(group_end, {
      g_ind .. "    actionref(" .. ref_name .. "; " .. name .. ")",
      g_ind .. "    {",
      g_ind .. "    }",
    })
  else
    ins(area_end, {
      i2 .. "group(Category_Process)",
      i2 .. "{",
      i3 .. "actionref(" .. ref_name .. "; " .. name .. ")",
      i3 .. "{",
      i3 .. "}",
      i2 .. "}",
    })
  end
  return out
end

-- ── Interactive wrappers over the pure functions ─────────────────────────────

-- Current line in normal mode, '< .. '> in visual / <cmd> from visual.
local function current_range(l1, l2)
  if l1 and l2 then return math.min(l1, l2), math.max(l1, l2) end
  local mode = vim.fn.mode()
  if mode:match("^[vV\22]") then
    local s = vim.fn.line("v"); local e = vim.fn.line(".")
    return math.min(s, e), math.max(s, e)
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return row, row
end
M.current_range = current_range

local function apply_or_warn(bufnr, new_lines, err, what)
  if not new_lines then
    vim.notify("AL " .. what .. ": " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  return true
end

local function convert_range(fn, what, l1, l2)
  local bufnr = vim.api.nvim_get_current_buf()
  local s, e = current_range(l1, l2)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local new, err = fn(lines)
  if not new then
    vim.notify("AL " .. what .. ": " .. tostring(err), vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, new)
end

function M.convert_to_validate(l1, l2) convert_range(M.to_validate, "Validate", l1, l2) end
function M.convert_to_evaluate(l1, l2) convert_range(M.to_evaluate, "Evaluate", l1, l2) end

function M.make_var_global_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row   = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new, err = M.make_var_global(lines, row)
  apply_or_warn(bufnr, new, err, "make var global")
end

function M.add_publishers_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row   = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local b = find_proc_bounds(lines, row)
  if not b then
    vim.notify("AL add publishers: cursor is not inside a procedure", vim.log.levels.WARN)
    return
  end
  local new, err = M.add_publishers(lines, b.hdr)
  apply_or_warn(bufnr, new, err, "add publishers")
end

function M.promote_action_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row   = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new, err = M.promote_action(lines, row)
  apply_or_warn(bufnr, new, err, "promote action")
end

-- Cursor on `[HandlerFunctions('A,B')]`: pick a missing handler (when more
-- than one) and its attribute kind, then insert the stub after the test.
function M.create_handler()
  local bufnr = vim.api.nvim_get_current_buf()
  local row   = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local info, err = M.missing_handlers(lines, row)
  if not info then
    vim.notify("AL create handler: " .. err, vim.log.levels.WARN)
    return
  end
  if #info.missing == 0 then
    vim.notify("AL create handler: all handlers already exist", vim.log.levels.INFO)
    return
  end
  local function pick_kind(name)
    vim.ui.select(M.HANDLER_KINDS, { prompt = "Handler attribute for " .. name .. ":" }, function(kind)
      if not kind then return end
      vim.schedule(function()
        local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local new, e = M.create_handler_function(cur, name, kind, info.proc_fin, info.indent)
        apply_or_warn(bufnr, new, e, "create handler")
      end)
    end)
  end
  if #info.missing == 1 then
    pick_kind(info.missing[1])
  else
    vim.ui.select(info.missing, { prompt = "Create handler:" }, function(name)
      if name then pick_kind(name) end
    end)
  end
end

-- Shared parsers for lua/al/codeactions.lua.
M.helpers = {
  find_proc_bounds   = find_proc_bounds,
  global_var_info    = global_var_info,
  parse_var_map      = parse_var_map,
  find_quoted_string = find_quoted_string,
  is_proc_line       = is_proc_line,
  mask_strings       = mask_strings,
  parse_proc_header  = parse_proc_header,
}

-- Pure internals exposed for tests/ only. Not API.
M._test = { find_quoted_string = find_quoted_string, find_proc_bounds = find_proc_bounds,
            suggest_name = suggest_name, insert_var_decl = insert_var_decl,
            label_decl = label_decl, parse_assignment = parse_assignment }

return M
