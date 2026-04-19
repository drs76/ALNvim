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

-- ── Public API ────────────────────────────────────────────────────────────────

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
