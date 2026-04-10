-- AL Page Preview
-- Parses the current page / pageextension buffer and renders a structural
-- layout overview in a floating window. No BC connection; sub-second.

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function strip_name(s)
  if not s then return nil end
  s = vim.trim(s)
  return s:match('^"([^"]+)"') or s:match("^'([^']+)'") or s
end

-- Derive a caption from a field source expression:
--   Rec."No."  →  No.     Rec.Name  →  Name
local function caption_from_source(src)
  if not src then return nil end
  src = vim.trim(src)
  src = src:gsub("^[Rr]ec%.", "")
  return strip_name(src)
end

-- ── Parser ────────────────────────────────────────────────────────────────────
-- Tracks absolute brace depth.  AL pages are well-structured:
--   depth 1  = object body          (PageType, SourceTable, Caption …)
--   depth 2  = layout / actions body
--   depth 3  = area body
--   depth 4  = group / repeater body
--   depth 5  = field body
--
-- Pre-processing joins a lone "{" with its predecessor so both common styles
-- ("keyword {" and "keyword\n{") are handled identically.

function M._parse_page(bufnr)
  local raw = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Normalise: join a standalone "{" with the line above it.
  local lines = {}
  for _, l in ipairs(raw) do
    l = l:gsub("\r$", "")
    if vim.trim(l) == "{" and #lines > 0 then
      lines[#lines] = lines[#lines] .. " {"
    else
      lines[#lines + 1] = l
    end
  end

  local r = {
    obj_type     = nil,   -- "page" | "pageextension"
    is_extension = false,
    page_id      = nil,
    page_name    = nil,
    extends      = nil,   -- base page name for pageextension
    page_type    = "Card",
    source_table = nil,
    caption      = nil,
    areas        = {},    -- layout areas  [{name, groups=[{name,caption,kind,fields,parts}]}]
    act_areas    = {},    -- action areas  [{name, acts=[{id,caption}]}]
  }

  local depth     = 0
  local obj_depth = nil  -- depth of object body (1 for normal AL)
  local lay_body  = nil  -- depth of layout body
  local act_body  = nil  -- depth of actions body

  local cur_area, cur_group, cur_field = nil, nil, nil
  local cur_act_area, cur_action       = nil, nil

  for _, line in ipairs(lines) do
    local lc = line:lower()

    local opens, closes = 0, 0
    for c in line:gmatch("[{}]") do
      if c == "{" then opens = opens + 1 else closes = closes + 1 end
    end

    -- ── Object header (depth 0) ───────────────────────────────────────────
    if depth == 0 and opens > 0 then
      if lc:match("^%s*pageextension%s") then
        r.obj_type    = "pageextension"
        r.is_extension = true
        r.page_id  = tonumber(line:match("^%s*[Pp]age[Ee]xtension%s+(%d+)"))
        r.page_name = line:match('^%s*[Pp]age[Ee]xtension%s+%d+%s+"([^"]+)"')
                   or line:match("^%s*[Pp]age[Ee]xtension%s+%d+%s+'([^']+)'")
        r.extends  = line:match('[Ee]xtends%s+"([^"]+)"')
                  or line:match("[Ee]xtends%s+'([^']+)'")
        obj_depth  = 1
      elseif lc:match("^%s*page%s+%d") then
        r.obj_type = "page"
        r.page_id  = tonumber(line:match("^%s*[Pp]age%s+(%d+)"))
        r.page_name = line:match('^%s*[Pp]age%s+%d+%s+"([^"]+)"')
                   or line:match("^%s*[Pp]age%s+%d+%s+'([^']+)'")
        obj_depth  = 1
      end
    end

    -- ── Object body: top-level properties ────────────────────────────────
    if obj_depth and depth == obj_depth then
      local pt = line:match("[Pp]age[Tt]ype%s*=%s*([%w]+)")
      if pt then r.page_type = pt end

      local st = line:match('[Ss]ource[Tt]able%s*=%s*"([^"]+)"')
              or line:match("[Ss]ource[Tt]able%s*=%s*'([^']+)'")
              or line:match("[Ss]ource[Tt]able%s*=%s*([%w_][%w_%.]*)%s*;")
      if st then r.source_table = st end

      local cap = line:match("[Cc]aption%s*=%s*'([^']+)'")
      if cap then r.caption = cap end

      if opens > 0 then
        if lc:match("^%s*layout[%s{]")  then lay_body = obj_depth + 1
        elseif lc:match("^%s*actions[%s{]") then act_body = obj_depth + 1
        end
      end
    end

    -- ── Layout body: area declarations ───────────────────────────────────
    if lay_body and depth == lay_body and opens > 0 then
      local aname = line:match("[Aa]rea%s*%(([^%)]+)%)")
      if aname then
        cur_area  = { name = strip_name(aname) or "area", groups = {} }
        cur_group = nil; cur_field = nil
        table.insert(r.areas, cur_area)
      end
    end

    -- ── Area body: group / repeater / modification blocks ────────────────
    if lay_body and depth == lay_body + 1 and cur_area and opens > 0 then
      local kind = lc:match("^%s*(repeater)%s*%(")
                or lc:match("^%s*(cuegroup)%s*%(")
                or lc:match("^%s*(grid)%s*%(")
                or lc:match("^%s*(fixed)%s*%(")
                or lc:match("^%s*(group)%s*%(")
                or lc:match("^%s*(addfirst)%s*%(")
                or lc:match("^%s*(addlast)%s*%(")
                or lc:match("^%s*(addafter)%s*%(")
                or lc:match("^%s*(addbefore)%s*%(")
                or lc:match("^%s*(movefirst)%s*%(")
                or lc:match("^%s*(movelast)%s*%(")
                or lc:match("^%s*(movebefore)%s*%(")
                or lc:match("^%s*(moveafter)%s*%(")
                or lc:match("^%s*(modify)%s*%(")
      if kind then
        local gname_raw = line:match("[%a]+%s*%(([^%)]+)%)")
        cur_group = {
          name    = strip_name(gname_raw) or "",
          kind    = kind,
          caption = nil,
          fields  = {},
          parts   = {},
        }
        cur_field = nil
        table.insert(cur_area.groups, cur_group)
      end
    end

    -- ── Group body: Caption + field / part declarations ───────────────────
    if lay_body and depth == lay_body + 2 and cur_group then

      -- Group Caption — skip field declaration lines to avoid false matches
      if not lc:match("^%s*field%s*%(") then
        local cap = line:match("[Cc]aption%s*=%s*'([^']+)'")
        if cap and not cur_group.caption then cur_group.caption = cap end
      end

      -- Field declaration
      local fname_raw = line:match("[Ff]ield%s*%(([^;%)]+)%;")
      if fname_raw then
        local fsrc_raw = line:match("[Ff]ield%s*%([^;]+;%s*([^%)]+)%)")
        cur_field = {
          id      = strip_name(vim.trim(fname_raw)),
          source  = fsrc_raw and vim.trim(fsrc_raw),
          caption = line:match("[Cc]aption%s*=%s*'([^']+)'"),
          visible = not lc:match("visible%s*=%s*false"),
          enabled = not lc:match("enabled%s*=%s*false") and not lc:match("editable%s*=%s*false"),
        }
        table.insert(cur_group.fields, cur_field)
        -- No body, or body fully resolved on this line
        if opens <= closes then cur_field = nil end
      end

      -- Part (sub-page)
      local pid_raw = line:match("[Pp]art%s*%(([^;%)]+)%;")
      if pid_raw then
        table.insert(cur_group.parts, {
          id   = strip_name(vim.trim(pid_raw)),
          page = strip_name(vim.trim(line:match("[Pp]art%s*%([^;]+;%s*([^%)]+)%)") or "")),
        })
      end
    end

    -- ── Field body: Caption + visibility / editability ───────────────────
    if lay_body and depth == lay_body + 3 and cur_field then
      local cap = line:match("[Cc]aption%s*=%s*'([^']+)'")
      if cap and not cur_field.caption then cur_field.caption = cap end
      if lc:match("visible%s*=%s*false")  then cur_field.visible = false end
      if lc:match("enabled%s*=%s*false")  then cur_field.enabled = false end
      if lc:match("editable%s*=%s*false") then cur_field.enabled = false end
    end

    -- ── Actions body: area declarations ──────────────────────────────────
    if act_body and depth == act_body and opens > 0 then
      local aname = line:match("[Aa]rea%s*%(([^%)]+)%)")
      if aname then
        cur_act_area = { name = strip_name(aname) or "area", acts = {} }
        cur_action   = nil
        table.insert(r.act_areas, cur_act_area)
      end
    end

    -- ── Action area body: action declarations ────────────────────────────
    if act_body and depth == act_body + 1 and cur_act_area and opens > 0 then
      -- Skip systemaction(...) — built-in BC toolbar buttons
      if not lc:match("^%s*systemaction%s*%(") then
        local act_id = line:match("[Aa]ction%s*%(([^%)]+)%)")
        if act_id then
          cur_action = {
            id      = strip_name(vim.trim(act_id)),
            caption = line:match("[Cc]aption%s*=%s*'([^']+)'"),
          }
          table.insert(cur_act_area.acts, cur_action)
        else
          cur_action = nil
        end
      end
    end

    -- ── Action body: Caption ─────────────────────────────────────────────
    if act_body and depth == act_body + 2 and cur_action then
      local cap = line:match("[Cc]aption%s*=%s*'([^']+)'")
      if cap and not cur_action.caption then cur_action.caption = cap end
    end

    -- ── Update depth ─────────────────────────────────────────────────────
    depth = depth + opens - closes

    -- Clear containers when we exit their scope
    if lay_body then
      if depth <= lay_body + 2 then cur_field = nil end
      if depth <= lay_body + 1 then cur_group = nil end
      if depth <= lay_body     then cur_area  = nil end
      if depth <  lay_body     then lay_body  = nil end
    end
    if act_body then
      if depth <= act_body + 1 then cur_action   = nil end
      if depth <= act_body     then cur_act_area = nil end
      if depth <  act_body     then act_body     = nil end
    end
    if obj_depth and depth < obj_depth then obj_depth = nil end
  end

  -- Derive captions for fields that had none in the source
  for _, area in ipairs(r.areas) do
    for _, grp in ipairs(area.groups) do
      for _, f in ipairs(grp.fields) do
        if not f.caption then
          f.caption = caption_from_source(f.source) or f.id or "?"
        end
      end
    end
  end

  return r
end

-- ── Renderer ──────────────────────────────────────────────────────────────────

function M._render(data, width)
  width = width or 80
  -- Layout: "│  <content>  │" — 3 chars on each side
  local inner = width - 6

  local out       = {}
  local hls       = {}
  local parts_map = {}  -- 0-indexed line_idx -> page_name (for <CR> drill)
  local BORDER    = 5   -- │ (3 bytes) + 2 spaces
  local function push(s) out[#out + 1] = s end

  local function content_line(s)
    s = s or ""
    local dw = vim.fn.strdisplaywidth(s)
    if dw > inner then
      repeat s = s:sub(1, -2) until vim.fn.strdisplaywidth(s) <= inner - 1
      s = s .. "…"
      dw = vim.fn.strdisplaywidth(s)
    end
    return "│  " .. s .. string.rep(" ", math.max(0, inner - dw)) .. "  │"
  end

  local function rule_line(ch)
    return "│  " .. string.rep(ch, inner) .. "  │"
  end

  -- Title bar ────────────────────────────────────────────────────────────────
  local page_name = data.caption or data.page_name or "?"
  local page_type = data.page_type or "Card"
  local src       = data.source_table or ""

  local right_str = data.is_extension
    and ("extends " .. (data.extends or "?"))
    or (page_type .. (src ~= "" and " │ " .. src or ""))

  local left  = " " .. page_name .. " "
  local right = " " .. right_str .. " "
  local fill  = (width - 2) - #left - #right
  if fill < 0 then
    left = " " .. page_name:sub(1, (width - 2) - #right - 4) .. "… "
    fill = (width - 2) - #left - #right
    if fill < 0 then fill = 0 end
  end
  push("╭" .. left .. string.rep("─", fill) .. right .. "╮")

  -- Layout ───────────────────────────────────────────────────────────────────
  local pt_lower    = page_type:lower()
  local has_content = false

  for _, area in ipairs(data.areas) do
    -- For standard pages: only render the Content area (skip FactBoxes etc).
    -- For extensions: show everything (all areas hold modifications).
    local show = area.name:lower() == "content"
              or area.name:lower() == "rolecenter"
              or data.is_extension

    if show then
      for _, grp in ipairs(area.groups) do
        if #grp.fields > 0 or #grp.parts > 0 then
          has_content = true

          -- Group heading
          local grp_caption = grp.caption or grp.name or ""
          local badge = ""
          if     grp.kind == "repeater"      then badge = "  ▸ Lines"
          elseif grp.kind:match("^add")      then badge = "  [+]"
          elseif grp.kind:match("^move")     then badge = "  [moved]"
          elseif grp.kind == "modify"        then badge = "  [modified]"
          elseif grp.kind == "cuegroup"      then badge = "  [Cues]"
          end

          push(content_line(""))
          push(content_line("  " .. grp_caption .. badge))
          push(rule_line("┄"))

          -- Render as list (column headers) or card (2-column grid)
          local as_list = grp.kind == "repeater"
                       or pt_lower == "list"
                       or pt_lower == "listpart"
                       or pt_lower == "worksheet"

          if as_list and #grp.fields > 0 then
            local n = math.min(#grp.fields, 5)
            local col_w = math.max(8, math.floor((inner - (n - 1) * 3) / n))
            local SEP   = 5  -- " │ " = space(1) + │(3 bytes) + space(1)

            local headers, seps, caps = {}, {}, {}
            for i = 1, n do
              local cap = grp.fields[i].caption or "?"
              if #cap > col_w then cap = cap:sub(1, col_w - 1) .. "…" end
              caps[i]    = cap
              headers[i] = cap .. string.rep(" ", col_w - #cap)
              seps[i]    = string.rep("─", col_w)
            end
            if #grp.fields > n then headers[n] = headers[n]:sub(1, col_w - 2) .. " …" end
            local hdr_idx = #out  -- 0-indexed line index after push
            push(content_line(table.concat(headers, " │ ")))
            push(content_line(table.concat(seps,    "─┼─")))
            push(content_line(""))  -- blank data row
            for j = 1, n do
              local f = grp.fields[j]
              if f then
                local hl = f.visible == false and "ALPvHidden"
                        or (f.enabled == false and "ALPvDisabled")
                if hl then
                  local cs = BORDER + (j - 1) * (col_w + SEP)
                  hls[#hls+1] = { line = hdr_idx, cs = cs, ce = cs + #caps[j], group = hl }
                end
              end
            end
          else
            -- 2-column card layout
            local col_w = math.floor((inner - 2) / 2)
            local i = 1
            while i <= #grp.fields do
              local lf = grp.fields[i]
              local rf = grp.fields[i + 1]
              local ls = lf and (lf.caption or "") or ""
              local rs = rf and (rf.caption or "") or ""
              if #ls > col_w then ls = ls:sub(1, col_w - 1) .. "…" end
              if #rs > col_w then rs = rs:sub(1, col_w - 1) .. "…" end
              local card_idx = #out
              push(content_line(ls .. string.rep(" ", col_w - #ls) .. "  " .. rs))
              if lf and #ls > 0 then
                local hl = lf.visible == false and "ALPvHidden"
                        or (lf.enabled == false and "ALPvDisabled")
                if hl then
                  hls[#hls+1] = { line = card_idx, cs = BORDER, ce = BORDER + #ls, group = hl }
                end
              end
              if rf and #rs > 0 then
                local hl = rf.visible == false and "ALPvHidden"
                        or (rf.enabled == false and "ALPvDisabled")
                if hl then
                  local rs_start = BORDER + col_w + 2
                  hls[#hls+1] = { line = card_idx, cs = rs_start, ce = rs_start + #rs, group = hl }
                end
              end
              i = i + 2
            end
          end

          -- Sub-page parts
          for _, p in ipairs(grp.parts) do
            local part_name = p.page or p.id or "?"
            local part_idx  = #out
            push(content_line("  [Part: " .. part_name .. "]"))
            if part_name ~= "?" then
              parts_map[part_idx] = part_name
            end
          end
        end
      end
    end
  end

  if not has_content then
    push(content_line(""))
    push(content_line("  (no layout found)"))
    push(content_line(""))
  end

  -- Actions footer ───────────────────────────────────────────────────────────
  local all_acts = {}
  for _, aa in ipairs(data.act_areas) do
    for _, a in ipairs(aa.acts) do
      all_acts[#all_acts + 1] = a.caption or a.id or "?"
    end
  end

  if #all_acts > 0 then
    push("├" .. string.rep("─", width - 2) .. "┤")
    push(content_line("  " .. table.concat(all_acts, "  │  ")))
  end

  push("╰" .. string.rep("─", width - 2) .. "╯")
  return { lines = out, hls = hls, parts = parts_map }
end

-- ── Part navigation ───────────────────────────────────────────────────────────
-- Search project root and extracted symbol caches for a page declaration.
local function find_page_file(name, root)
  local dirs = {}
  if root and vim.fn.isdirectory(root) == 1 then
    dirs[#dirs + 1] = vim.fn.shellescape(root)
  end
  local sym_base = vim.fn.stdpath("cache") .. "/alnvim/symbols"
  if vim.fn.isdirectory(sym_base) == 1 then
    for _, d in ipairs(vim.fn.glob(sym_base .. "/*", false, true)) do
      if vim.fn.isdirectory(d) == 1 then
        dirs[#dirs + 1] = vim.fn.shellescape(d)
      end
    end
  end
  if #dirs == 0 then return nil, nil end

  -- Escape regex metacharacters in the page name
  local esc = name:gsub("([%(%)%.%[%]%*%+%?%^%$%{%}|\\])", "\\%1")
  local pattern = string.format([[page\s+\d+\s+["']?%s["']?]], esc)
  local cmd = "rg --no-heading -n -i -e " .. vim.fn.shellescape(pattern)
           .. " --glob '*.al' --glob '*.AL' "
           .. table.concat(dirs, " ")
  local found = vim.fn.systemlist(cmd)
  if #found == 0 then return nil, nil end
  -- First match format: "path:linenum:content"
  local path, lnum = found[1]:match("^(.-):(%d+):")
  return path, tonumber(lnum)
end

-- ── Entry point ───────────────────────────────────────────────────────────────

function M.preview(bufnr, root)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if vim.bo[bufnr].filetype ~= "al" then
    vim.notify("ALPreviewPage: not an AL buffer", vim.log.levels.WARN)
    return
  end

  local data = M._parse_page(bufnr)

  if not data.obj_type then
    vim.notify("ALPreviewPage: buffer is not a page or pageextension", vim.log.levels.WARN)
    return
  end
  if data.obj_type ~= "page" and data.obj_type ~= "pageextension" then
    vim.notify("ALPreviewPage: not a page (found: " .. tostring(data.obj_type) .. ")",
      vim.log.levels.WARN)
    return
  end

  local ui     = vim.api.nvim_list_uis()[1]
  local width  = math.min(math.floor(ui.width  * 0.85), 120)
  local result = M._render(data, width)
  local lines  = result.lines
  local height = math.min(#lines, math.floor(ui.height * 0.80))

  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden  = "wipe"
  vim.bo[pbuf].modifiable = true
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  vim.bo[pbuf].modifiable = false

  local win = vim.api.nvim_open_win(pbuf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = math.floor((ui.height - height) / 2),
    col      = math.floor((ui.width  - width)  / 2),
    style    = "minimal",
    border   = "none",
    zindex   = 50,
  })
  vim.wo[win].wrap       = false
  vim.wo[win].cursorline = false
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = "no"

  -- Light syntax: dim structural chars so field names stand out
  vim.api.nvim_buf_call(pbuf, function()
    vim.cmd("syntax match ALPvBorder /[╭╮╰╯│├┤]/")
    vim.cmd("syntax match ALPvRule   /[┄▸]+/")
    vim.cmd("syntax match ALPvSep    /[─┼]+/")
    vim.cmd("highlight default link ALPvBorder  Comment")
    vim.cmd("highlight default link ALPvRule    Type")
    vim.cmd("highlight default link ALPvSep     Comment")
    vim.cmd("highlight default link ALPvHidden  NonText")
    vim.cmd("highlight default link ALPvDisabled Comment")
  end)

  -- Apply per-field highlights (Visible=false / Enabled|Editable=false)
  if #result.hls > 0 then
    local ns = vim.api.nvim_create_namespace("al_preview")
    for _, hl in ipairs(result.hls) do
      vim.api.nvim_buf_add_highlight(pbuf, ns, hl.group, hl.line, hl.cs, hl.ce)
    end
  end

  local co = { buffer = pbuf, nowait = true, silent = true }
  vim.keymap.set("n", "q",     "<cmd>close<CR>", co)
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", co)

  -- <CR> / gd on a [Part: ...] line: open that page
  local parts_map = result.parts
  local function drill_part()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
    local page_name = parts_map[row]
    if not page_name then return end
    vim.cmd("close")
    local path, lnum = find_page_file(page_name, root)
    if not path then
      vim.notify("ALPreviewPage: page '" .. page_name .. "' not found", vim.log.levels.WARN)
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if lnum then pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 }) end
  end
  vim.keymap.set("n", "<CR>", drill_part, co)
  vim.keymap.set("n", "gd",   drill_part, co)
end

return M
