-- AL object ID completion.
-- Suggests the next free object ID(s) within the idRanges defined in app.json.
--
-- Usage (insert mode, on a line starting with an AL object type):
--   <C-Space>  →  popup with next available IDs
--
-- Usage (normal mode):
--   :ALNextId  →  notification with next free ID for the type on the current line

local M   = {}
local lsp = require("al.lsp")

-- Object types that take numeric IDs in AL
local ID_TYPES = {
  table=1, tableextension=1, page=1, pageextension=1, pagecustomization=1,
  codeunit=1, report=1, reportextension=1, query=1, xmlport=1,
  enum=1, enumextension=1, permissionset=1, permissionsetextension=1,
  profile=1, controladdin=1,
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Return idRanges from app.json as { {from=N, to=M}, ... }
local function get_ranges(root)
  local app = lsp.read_app_json(root)
  if not app or not app.idRanges then return {} end
  local ranges = {}
  for _, r in ipairs(app.idRanges) do
    local f, t = tonumber(r["from"]), tonumber(r["to"])
    if f and t then table.insert(ranges, { from = f, to = t }) end
  end
  return ranges
end

-- Return a set of IDs already used by obj_type in the project: { [id]=true }
local function get_used_ids(root, obj_type)
  local lines = vim.fn.systemlist({
    "rg", "--no-heading", "--no-filename", "--color=never", "-i",
    "-e", string.format("^\\s*%s\\s+\\d+", obj_type),
    "--glob", "*.al", "--glob", "*.AL",
    root,
  })
  local used = {}
  local pat = "^%s*" .. obj_type .. "%s+(%d+)"
  for _, line in ipairs(lines) do
    local id = line:lower():match(pat)
    if id then used[tonumber(id)] = true end
  end
  return used
end

-- Detect the AL object type at the start of `line` (case-insensitive).
-- Returns the lowercase type string, or nil.
local function obj_type_from_line(line)
  local word = line:match("^%s*(%a+)")
  if word and ID_TYPES[word:lower()] then return word:lower() end
  return nil
end

-- Collect up to `max` free IDs per range, filtered by numeric prefix `prefix`.
local function free_ids(ranges, used, max, prefix)
  local results = {}
  for _, range in ipairs(ranges) do
    local count  = 0
    local n_used = 0
    -- Count used IDs in this range for the menu label
    for id = range.from, range.to do
      if used[id] then n_used = n_used + 1 end
    end
    for id = range.from, range.to do
      if not used[id] then
        local s = tostring(id)
        if prefix == "" or s:sub(1, #prefix) == prefix then
          table.insert(results, {
            id      = id,
            menu    = string.format("[%d-%d · %d used]", range.from, range.to, n_used),
            info    = string.format("%d of %d IDs used in range %d-%d",
                        n_used, range.to - range.from + 1, range.from, range.to),
          })
          count = count + 1
          if count >= max then break end
        end
      end
    end
  end
  return results
end

-- ── completefunc implementation ───────────────────────────────────────────────

-- Called by Vim twice:
--   findstart=1 → return byte column where the completion word starts (-3 to cancel)
--   findstart=0 → return list of completion items
function M.complete(findstart, base)
  if findstart == 1 then
    local line   = vim.api.nvim_get_current_line()
    local col    = vim.api.nvim_win_get_cursor(0)[2]  -- 0-based
    local before = line:sub(1, col)
    -- Must be: optional whitespace, object-type keyword, whitespace, optional digits, end
    local typ = before:match("^%s*(%a+)%s+%d*$")
    if typ and ID_TYPES[typ:lower()] then
      -- Start position = just after the space(s) following the keyword
      local digits = before:match("%d+$") or ""
      return col - #digits  -- 0-based column where the number starts
    end
    return -3  -- cancel: don't modify text, don't trigger

  else
    -- findstart == 0: generate completions
    local line   = vim.api.nvim_get_current_line()
    local col    = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local typ    = before:match("^%s*(%a+)%s+%d*$")
    if not typ or not ID_TYPES[typ:lower()] then return {} end
    typ = typ:lower()

    local root = lsp.get_root()
    if not root then return {} end

    local ranges = get_ranges(root)
    if #ranges == 0 then
      vim.notify("AL: No idRanges defined in app.json", vim.log.levels.WARN)
      return {}
    end

    local used    = get_used_ids(root, typ)
    local matches = free_ids(ranges, used, 5, base)

    local items = {}
    for _, m in ipairs(matches) do
      table.insert(items, {
        word  = tostring(m.id),
        abbr  = tostring(m.id),
        menu  = m.menu,
        info  = m.info,
        icase = 1,
        dup   = 0,
        empty = 0,
      })
    end

    if #items == 0 then
      vim.notify("AL: No free IDs in the defined ranges", vim.log.levels.WARN)
    end
    return items
  end
end

-- ── Normal-mode helper (:ALNextId) ────────────────────────────────────────────

function M.show_next()
  local line = vim.api.nvim_get_current_line()
  local typ  = obj_type_from_line(line)
  if not typ then
    vim.notify("AL: No object type keyword on current line", vim.log.levels.WARN)
    return
  end

  local root = lsp.get_root()
  if not root then return end

  local ranges = get_ranges(root)
  if #ranges == 0 then
    vim.notify("AL: No idRanges defined in app.json", vim.log.levels.WARN)
    return
  end

  local used    = get_used_ids(root, typ)
  local matches = free_ids(ranges, used, 1, "")

  if #matches == 0 then
    vim.notify("AL: No free IDs available in the defined ranges", vim.log.levels.WARN)
    return
  end

  local lines = { string.format("AL: Next free %s IDs:", typ) }
  for _, m in ipairs(free_ids(ranges, used, 3, "")) do
    table.insert(lines, string.format("  %d  %s", m.id, m.menu))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
