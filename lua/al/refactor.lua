-- AL code refactoring utilities.
-- M.extract_label() — extract a single-quoted string to a Label variable.

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

-- Find the double-quoted AL identifier at cursor by scanning left/right for " delimiters.
-- Returns the name string (without quotes), or nil when cursor is not inside one.
local function dquoted_id_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  if not line then return nil end
  local col1 = col + 1  -- convert to 1-based

  local q_open = nil
  for i = col1, 1, -1 do
    if line:sub(i, i) == '"' then q_open = i; break end
  end
  if not q_open then return nil end

  local q_close = nil
  for i = q_open + 1, #line do
    if line:sub(i, i) == '"' then q_close = i; break end
  end
  if not q_close or col1 > q_close then return nil end

  local name = line:sub(q_open + 1, q_close - 1)
  return name ~= '' and name or nil
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

function M.extract_label()
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

          -- ── 1. Replace all occurrences in body (bottom-up: same line count) ──
          local pat   = "'" .. vim.pesc(text) .. "'"
          local count = 0
          for i = b.fin, b.beg, -1 do
            local ln  = buf_lines[i]
            local n   = 0
            local new = ln:gsub(pat, function() n = n + 1; return var_name end)
            count = count + n
            if new ~= ln then
              vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
              buf_lines[i] = new  -- keep in sync for var-block logic below
            end
          end

          -- ── 2. Insert var declaration ─────────────────────────────────────────
          local beg_ind  = buf_lines[b.beg]:match('^(%s*)') or '    '
          local decl_ind = beg_ind .. '    '
          local label_decl = var_name .. ": Label '" .. text .. "', Locked = true;"

          if is_global then
            local gvar, ins = global_var_info(buf_lines)
            if gvar then
              -- Find last non-blank line in the existing global var block
              local var_end = gvar
              for i = gvar + 1, ins - 1 do
                if vim.trim(buf_lines[i]) ~= '' then var_end = i end
              end
              local g_ind = (var_end > gvar)
                and (buf_lines[var_end]:match('^(%s*)') or decl_ind)
                or  decl_ind
              vim.api.nvim_buf_set_lines(bufnr, var_end, var_end, false,
                { g_ind .. label_decl })
            else
              -- Create new global var block just before first procedure
              local g_var_ind = beg_ind
              vim.api.nvim_buf_set_lines(bufnr, ins - 1, ins - 1, false, {
                '',
                g_var_ind .. 'var',
                g_var_ind .. '    ' .. label_decl,
              })
            end
          else
            if b.var then
              -- Append to existing local var block
              local var_end = b.var
              for i = b.var + 1, b.beg - 1 do
                if vim.trim(buf_lines[i]) ~= '' then var_end = i end
              end
              local l_ind = (var_end > b.var)
                and (buf_lines[var_end]:match('^(%s*)') or decl_ind)
                or  decl_ind
              vim.api.nvim_buf_set_lines(bufnr, var_end, var_end, false,
                { l_ind .. label_decl })
            else
              -- No var block: create one before begin
              vim.api.nvim_buf_set_lines(bufnr, b.beg - 1, b.beg - 1, false, {
                beg_ind .. 'var',
                decl_ind .. label_decl,
              })
            end
          end

          vim.notify(
            string.format('AL: "%s" → %s (%d occurrence%s)',
              text, var_name, count, count == 1 and '' or 's'),
            vim.log.levels.INFO)
        end)
      end)
  end)
end

return M
