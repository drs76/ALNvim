-- AL text objects: procedures/triggers (af/if) and begin/end blocks (aF/iF).
local M = {}

local function indent(lnum)
  return #(vim.fn.getline(lnum):match("^(%s*)") or "")
end

-- Linewise visual selection from line a to line b.
local function select(a, b)
  vim.fn.cursor(a, 1)
  vim.cmd("normal! V")
  vim.fn.cursor(b, 1)
end

-- Returns (proc_line, begin_line|nil, end_line) for the procedure/trigger
-- that contains the cursor, using indentation to find the matching end;.
local function proc_bounds()
  local cur = vim.fn.line(".")
  local pline, pindent

  for i = cur, 1, -1 do
    local l = vim.fn.getline(i)
    if l:match("^%s*[%w%s]*[Pp]rocedure%s") or l:match("^%s*[Tt]rigger%s") then
      pline, pindent = i, indent(i)
      break
    end
    -- Stop at object closing brace or a shallowly-indented end;
    if l:match("^%s*}") then break end
    if l:match("^%s*end;%s*$") and indent(i) <= 4 then break end
  end
  if not pline then return nil end

  -- Matching end; is at the same indent as the procedure keyword.
  local eline
  for i = pline + 1, vim.fn.line("$") do
    local l = vim.fn.getline(i)
    if l:match("^%s*end;%s*$") and indent(i) == pindent then
      eline = i
      break
    end
  end
  if not eline then return nil end

  -- The outermost begin at procedure indent level (body begin, after var section).
  local bline
  for i = pline, eline - 1 do
    local l = vim.fn.getline(i)
    if l:match("^%s*begin%s*$") and indent(i) == pindent then
      bline = i
      break
    end
  end

  return pline, bline, eline
end

-- Returns (begin_line, end_line) for the innermost begin/end block containing
-- the cursor. Handles nesting by tracking depth. Also counts case…of as +1
-- so that its closing end; does not under-count.
local function block_bounds()
  local cur = vim.fn.line(".")

  -- Scan a line's block tokens in the order they appear, not by kind.
  --
  -- Counting every `begin` on a line before every `end` gets `end else begin`
  -- wrong — the single most common multi-token line in AL. Taken out of order
  -- the two cancel, so depth never reaches zero at the `else` and the text
  -- object swallows the else-branch as well. Returns a list of +1/-1 deltas in
  -- source order.
  local function tokens(line)
    local out = {}
    for pos, word in line:lower():gmatch("()(%a+)") do
      -- %f frontier equivalence: reject a match glued to another word char.
      local before = line:sub(pos - 1, pos - 1)
      local after  = line:sub(pos + #word, pos + #word)
      if not before:match("[%w_]") and not after:match("[%w_]") then
        if word == "begin" or word == "case" then
          out[#out + 1] = 1
        elseif word == "end" then
          out[#out + 1] = -1
        end
      end
    end
    return out
  end

  -- Walk backward: find the begin/case that owns the cursor.
  -- pending tracks unmatched end tokens we have passed; a line is scanned
  -- right-to-left because we are moving backwards through the source.
  local pending = 0
  local bline, bidx
  for i = cur, 1, -1 do
    local t = tokens(vim.fn.getline(i))
    for k = #t, 1, -1 do
      if t[k] == -1 then
        pending = pending + 1
      else
        if pending == 0 then bline, bidx = i, k; break end
        pending = pending - 1
      end
    end
    if bline then break end
  end
  if not bline then return nil end

  -- Walk forward counting in source order, starting *after* the token that
  -- opened the block. Restarting at the beginning of the opening line would
  -- re-consume the `end` in `end else begin`, closing the block on its own
  -- opening line.
  local depth = 1
  local eline
  for i = bline, vim.fn.line("$") do
    local t = tokens(vim.fn.getline(i))
    local from = (i == bline) and (bidx + 1) or 1
    for k = from, #t do
      depth = depth + t[k]
      if depth == 0 then eline = i; break end
    end
    if eline then break end
  end

  return bline, eline
end

-- af: around procedure/trigger (from keyword line to end;)
function M.around_proc()
  local pl, _, el = proc_bounds()
  if pl and el then select(pl, el) end
end

-- if: inside procedure/trigger (lines between begin and end;)
function M.inside_proc()
  local _, bl, el = proc_bounds()
  if bl and el and bl + 1 <= el - 1 then select(bl + 1, el - 1) end
end

-- aF: around begin/end block (includes begin and end lines)
function M.around_block()
  local bl, el = block_bounds()
  if bl and el then select(bl, el) end
end

-- iF: inside begin/end block (content between begin and end)
function M.inside_block()
  local bl, el = block_bounds()
  if bl and el and bl + 1 <= el - 1 then select(bl + 1, el - 1) end
end

return M
