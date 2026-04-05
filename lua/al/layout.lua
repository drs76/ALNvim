-- AL Report Layout Wizard
-- Excel (.xlsx) — generated with one sheet per dataitem, column headers in row 1.
-- Word  (.docx) — rendering entry added; alc generates the file with BC XML controls on :ALCompile.
-- RDLC  (.rdlc) — rendering entry added; alc generates the file with DataSet_Result on :ALCompile.
--
-- All types inject a rendering section + DefaultRenderingLayout into the report .al buffer.

local platform = require("al.platform")
local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function xml_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- 1-based column index → Excel letter(s): 1→"A", 26→"Z", 27→"AA" …
local function col_letter(n)
  local r = ""
  while n > 0 do
    n = n - 1
    r = string.char(65 + n % 26) .. r
    n = math.floor(n / 26)
  end
  return r
end

-- Strip surrounding "…" or '…' quotes and whitespace from an AL identifier.
local function strip_name(s)
  s = vim.trim(s)
  return s:match('^"([^"]+)"') or s:match("^'([^']+)'") or s
end

-- Sanitise an AL name into a valid AL identifier (letters + digits only).
local function sanitise_id(name)
  local r = name:gsub("[^%a%d]", "")
  if r == "" then r = "Layout" end
  return r
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"), "Cannot write: " .. path)
  f:write(content)
  f:close()
end

local function rm_rf(dir)
  if platform.is_windows then
    vim.fn.system({ "cmd", "/c", "rmdir", "/s", "/q", dir })
  else
    vim.fn.system({ "rm", "-rf", dir })
  end
end

-- ── Buffer parser ─────────────────────────────────────────────────────────────

function M._parse_report(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local info = { dataitems = {} }
  local current_di = nil

  for _, line in ipairs(lines) do
    if not info.report_id then
      local id, name = line:match('^%s*report%s+(%d+)%s+"([^"]+)"')
      if not id then id, name = line:match("^%s*report%s+(%d+)%s+([%w_]+)") end
      if id then info.report_id = tonumber(id); info.report_name = name end
    end

    local di_raw = line:match("^%s*dataitem%s*%(([^;,%)]+)")
    if di_raw then
      current_di = { name = strip_name(di_raw), columns = {} }
      table.insert(info.dataitems, current_di)
    end

    local col_raw = line:match("^%s*column%s*%(([^;,%)]+)")
    if col_raw and current_di then
      table.insert(current_di.columns, strip_name(col_raw))
    end
  end

  if not info.report_id then
    vim.notify("ALReportLayout: current buffer is not an AL report", vim.log.levels.ERROR)
    return nil
  end
  if #info.dataitems == 0 then
    vim.notify("ALReportLayout: no dataitem declarations found", vim.log.levels.WARN)
    return nil
  end
  local total_cols = 0
  for _, di in ipairs(info.dataitems) do total_cols = total_cols + #di.columns end
  if total_cols == 0 then
    vim.notify("ALReportLayout: no column() declarations found", vim.log.levels.WARN)
    return nil
  end
  return info
end

-- ── Excel (.xlsx) generators ──────────────────────────────────────────────────

local function xlsx_content_types(n_sheets)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '  <Default Extension="xml"  ContentType="application/xml"/>',
    '  <Override PartName="/xl/workbook.xml"',
    '    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
  }
  for i = 1, n_sheets do
    table.insert(parts, string.format(
      '  <Override PartName="/xl/worksheets/sheet%d.xml"', i))
    table.insert(parts,
      '    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')
  end
  table.insert(parts, '  <Override PartName="/xl/sharedStrings.xml"')
  table.insert(parts,
    '    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>')
  table.insert(parts, '  <Override PartName="/xl/styles.xml"')
  table.insert(parts,
    '    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
  table.insert(parts, '</Types>')
  return table.concat(parts, "\n")
end

local function xlsx_rels()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="xl/workbook.xml"/>
</Relationships>]]
end

local function xlsx_workbook(dataitems)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"',
    '          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '  <sheets>',
  }
  for i, di in ipairs(dataitems) do
    table.insert(parts, string.format(
      '    <sheet name="%s" sheetId="%d" r:id="rId%d"/>', xml_escape(di.name), i, i))
  end
  table.insert(parts, '  </sheets>')
  table.insert(parts, '</workbook>')
  return table.concat(parts, "\n")
end

local function xlsx_workbook_rels(n_sheets)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
  }
  for i = 1, n_sheets do
    table.insert(parts, string.format('  <Relationship Id="rId%d"', i))
    table.insert(parts,
      '    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"')
    table.insert(parts, string.format('    Target="worksheets/sheet%d.xml"/>', i))
  end
  table.insert(parts, string.format('  <Relationship Id="rId%d"', n_sheets + 1))
  table.insert(parts,
    '    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"')
  table.insert(parts, '    Target="sharedStrings.xml"/>')
  table.insert(parts, string.format('  <Relationship Id="rId%d"', n_sheets + 2))
  table.insert(parts,
    '    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"')
  table.insert(parts, '    Target="styles.xml"/>')
  table.insert(parts, '</Relationships>')
  return table.concat(parts, "\n")
end

local function xlsx_shared_strings(dataitems)
  local all = {}
  for _, di in ipairs(dataitems) do
    for _, col in ipairs(di.columns) do table.insert(all, col) end
  end
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    string.format('<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      .. ' count="%d" uniqueCount="%d">', #all, #all),
  }
  for _, col in ipairs(all) do
    table.insert(parts, "  <si><t>" .. xml_escape(col) .. "</t></si>")
  end
  table.insert(parts, "</sst>")
  return table.concat(parts, "\n")
end

local function xlsx_styles()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
  <fills count="2">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
</styleSheet>]]
end

local function xlsx_sheet(columns, offset)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      .. ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '  <sheetData>',
    '    <row r="1">',
  }
  for i = 1, #columns do
    table.insert(parts,
      string.format('      <c r="%s1" t="s"><v>%d</v></c>', col_letter(i), offset + i - 1))
  end
  table.insert(parts, "    </row>")
  table.insert(parts, "  </sheetData>")
  table.insert(parts, "</worksheet>")
  return table.concat(parts, "\n")
end

local function build_xlsx(tmpdir, dataitems)
  local n = #dataitems
  write_file(tmpdir .. "/[Content_Types].xml",       xlsx_content_types(n))
  write_file(tmpdir .. "/_rels/.rels",                xlsx_rels())
  write_file(tmpdir .. "/xl/workbook.xml",            xlsx_workbook(dataitems))
  write_file(tmpdir .. "/xl/_rels/workbook.xml.rels", xlsx_workbook_rels(n))
  write_file(tmpdir .. "/xl/sharedStrings.xml",       xlsx_shared_strings(dataitems))
  write_file(tmpdir .. "/xl/styles.xml",              xlsx_styles())
  local offset = 0
  for i, di in ipairs(dataitems) do
    write_file(tmpdir .. "/xl/worksheets/sheet" .. i .. ".xml",
      xlsx_sheet(di.columns, offset))
    offset = offset + #di.columns
  end
end

-- ── AL buffer modification ────────────────────────────────────────────────────

-- Inject rendering section entries + DefaultRenderingLayout into the report buffer.
-- Does NOT save — user reviews then :w.
-- entries = { { id, type_str, layout_file }, ... }
function M._inject_rendering(bufnr, default_id, entries)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n = #lines

  -- Find report object opening brace (1-based).
  local report_brace = nil
  for i, line in ipairs(lines) do
    if line:match("^%s*report%s+%d+") then
      if line:match("{") then
        report_brace = i
      elseif i < n and lines[i + 1]:match("^%s*{") then
        report_brace = i + 1
      end
      break
    end
  end
  if not report_brace then return end

  -- Check for existing DefaultRenderingLayout.
  local has_default = false
  for _, line in ipairs(lines) do
    if line:match("DefaultRenderingLayout") then has_default = true; break end
  end

  -- Find rendering section start + closing brace (1-based).
  local rend_close = nil
  local rend_start = nil
  for i, line in ipairs(lines) do
    if line:match("^%s*rendering%s*$") or line:match("^%s*rendering%s*{") then
      rend_start = i
      local depth = 0
      local j = line:match("{") and i or (i + 1)
      for k = j, n do
        local l = lines[k]
        for _ in l:gmatch("{") do depth = depth + 1 end
        for _ in l:gmatch("}") do depth = depth - 1 end
        if depth == 0 then rend_close = k; break end
      end
      break
    end
  end

  -- Find the report's outer closing } (last bare } line).
  local report_close = nil
  for i = n, 1, -1 do
    if lines[i]:match("^}%s*$") then report_close = i; break end
  end
  if not report_close then return end

  -- Skip entries whose Type already exists in the rendering section.
  local existing_types = {}
  if rend_start and rend_close then
    for i = rend_start, rend_close do
      local t = lines[i]:match("Type%s*=%s*(%w+)%s*;")
      if t then existing_types[t:lower()] = true end
    end
  end
  local new_entries = {}
  for _, e in ipairs(entries) do
    if not existing_types[e.type_str:lower()] then
      table.insert(new_entries, e)
    end
  end

  -- Build insertions { after = 1-based line, text = string[] }, applied bottom-up.
  local ops = {}

  if not has_default and default_id then
    table.insert(ops, {
      after = report_brace,
      text  = { "    DefaultRenderingLayout = " .. default_id .. ";" },
    })
  end

  if #new_entries > 0 then
    local layout_lines = {}
    for _, e in ipairs(new_entries) do
      table.insert(layout_lines, "        layout(" .. e.id .. ")")
      table.insert(layout_lines, "        {")
      table.insert(layout_lines, "            Type = " .. e.type_str .. ";")
      table.insert(layout_lines, "            LayoutFile = '" .. e.layout_file .. "';")
      table.insert(layout_lines, "        }")
    end

    if rend_close then
      table.insert(ops, { after = rend_close - 1, text = layout_lines })
    else
      local block = { "    rendering", "    {" }
      for _, l in ipairs(layout_lines) do table.insert(block, l) end
      table.insert(block, "    }")
      table.insert(ops, { after = report_close - 1, text = block })
    end
  end

  if #ops == 0 then return end

  table.sort(ops, function(a, b) return a.after > b.after end)
  for _, op in ipairs(ops) do
    vim.api.nvim_buf_set_lines(bufnr, op.after, op.after, false, op.text)
  end

  vim.notify("ALReportLayout: report source updated — review and :w to save", vim.log.levels.WARN)
end

-- ── Layout type picker (multi-select) ─────────────────────────────────────────

local LAYOUT_OPTIONS = {
  { key = "Excel", label = "Excel (.xlsx) — generated with column headers",          ext = ".xlsx", type_str = "Excel" },
  { key = "Word",  label = "Word  (.docx) — entry added; alc generates on :ALCompile", ext = ".docx", type_str = "Word"  },
  { key = "RDLC",  label = "RDLC  (.rdlc) — entry added; alc generates on :ALCompile", ext = ".rdlc", type_str = "RDLC"  },
}

local function telescope_layout_picker(callback)
  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "AL Layout Types  (<Tab> toggle, <CR> generate)",
    finder = finders.new_table({
      results = LAYOUT_OPTIONS,
      entry_maker = function(opt)
        return { value = opt, display = "[ ]  " .. opt.label, ordinal = opt.key }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local sel = picker:get_multi_selection()
        if #sel == 0 then
          local e = action_state.get_selected_entry()
          if e then sel = { e } end
        end
        actions.close(prompt_bufnr)
        local selected = vim.tbl_map(function(s) return s.value end, sel)
        if #selected > 0 then callback(selected) end
      end)
      map({ "i", "n" }, "<Tab>", actions.toggle_selection + actions.move_selection_next)
      return true
    end,
  }):find()
end

local function simple_layout_picker(callback)
  local state = {}
  for _, opt in ipairs(LAYOUT_OPTIONS) do state[opt.key] = false end

  local function show()
    local items = {}
    for _, opt in ipairs(LAYOUT_OPTIONS) do
      items[#items + 1] = (state[opt.key] and "[x]  " or "[ ]  ") .. opt.label
    end
    items[#items + 1] = "─── Generate ───"
    items[#items + 1] = "─── Cancel ───"

    vim.ui.select(items, { prompt = "Select layout types:" }, function(_, idx)
      if not idx or idx == #items then return end
      if idx == #items - 1 then
        local selected = {}
        for _, opt in ipairs(LAYOUT_OPTIONS) do
          if state[opt.key] then table.insert(selected, opt) end
        end
        if #selected == 0 then
          vim.notify("ALReportLayout: no layout types selected", vim.log.levels.WARN)
          return
        end
        callback(selected)
        return
      end
      state[LAYOUT_OPTIONS[idx].key] = not state[LAYOUT_OPTIONS[idx].key]
      show()
    end)
  end

  show()
end

-- ── Wizard helpers ────────────────────────────────────────────────────────────

local function existing_layout_types(bufnr)
  local types = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_rendering = false
  for _, line in ipairs(lines) do
    if line:match("^%s*rendering") then in_rendering = true end
    if in_rendering then
      local t = line:match("Type%s*=%s*(%w+)%s*;")
      if t then types[t:lower()] = true end
    end
  end
  return types
end

-- Resolve IDs/paths for each selected type, prompting on duplicate Types.
local function resolve_names(bufnr, info, root, selected, cb)
  local safe  = sanitise_id(info.report_name)
  local exist = existing_layout_types(bufnr)
  local result = {}
  local i = 0

  local function next_opt()
    i = i + 1
    if i > #selected then cb(result); return end
    local opt = selected[i]
    local default_id = safe .. opt.type_str

    if not exist[opt.type_str:lower()] then
      table.insert(result, {
        opt      = opt,
        id       = default_id,
        out_path = root .. "/layouts/" .. default_id .. opt.ext,
      })
      next_opt()
    else
      local suggested = default_id .. "_2"
      vim.notify("ALReportLayout: a " .. opt.type_str
        .. " layout already exists in this report's rendering section.", vim.log.levels.WARN)
      vim.ui.input({ prompt = "New layout name (empty to skip): ", default = suggested },
        function(input)
          local name = input and vim.trim(input) or ""
          if name ~= "" then
            table.insert(result, {
              opt      = opt,
              id       = name,
              out_path = root .. "/layouts/" .. name .. opt.ext,
            })
          end
          next_opt()
        end)
    end
  end

  next_opt()
end

-- Confirm overwrite only for Excel entries (Word/RDLC files don't exist yet — alc creates them).
local function confirm_overwrites(resolved, cb)
  local excel_entries, other_entries = {}, {}
  for _, e in ipairs(resolved) do
    if e.opt.type_str == "Excel" then
      table.insert(excel_entries, e)
    else
      table.insert(other_entries, e)
    end
  end

  local confirmed_excel = {}
  local i = 0

  local function next_entry()
    i = i + 1
    if i > #excel_entries then
      -- Combine confirmed Excel + all Word/RDLC entries
      local all = {}
      for _, e in ipairs(confirmed_excel) do table.insert(all, e) end
      for _, e in ipairs(other_entries)   do table.insert(all, e) end
      cb(all)
      return
    end
    local e = excel_entries[i]
    if vim.fn.filereadable(e.out_path) == 1 then
      vim.ui.select({ "Overwrite", "Cancel" },
        { prompt = vim.fn.fnamemodify(e.out_path, ":t") .. " already exists. Overwrite?" },
        function(ans)
          if ans == "Overwrite" then table.insert(confirmed_excel, e) end
          next_entry()
        end)
    else
      table.insert(confirmed_excel, e)
      next_entry()
    end
  end

  next_entry()
end

-- ── Wizard entry point ────────────────────────────────────────────────────────

function M.generate()
  local bufnr = vim.api.nvim_get_current_buf()

  if vim.bo[bufnr].filetype ~= "al" then
    vim.notify("ALReportLayout: not an AL buffer", vim.log.levels.WARN)
    return
  end

  local info = M._parse_report(bufnr)
  if not info then return end

  local root = require("al.lsp").get_root(bufnr)
  if not root then
    vim.notify("ALReportLayout: no project root (app.json) found", vim.log.levels.WARN)
    return
  end

  vim.notify(
    "ALReportLayout:\n"
    .. "  Excel — file generated with column headers (ready to use)\n"
    .. "  Word  — rendering entry added; run :ALCompile to generate the layout with BC XML controls\n"
    .. "  RDLC  — rendering entry added; run :ALCompile to generate the layout",
    vim.log.levels.INFO)

  local function run_picker(cb)
    if pcall(require, "telescope") then telescope_layout_picker(cb)
    else simple_layout_picker(cb) end
  end

  run_picker(function(selected)
    resolve_names(bufnr, info, root, selected, function(resolved)
      if #resolved == 0 then return end

      confirm_overwrites(resolved, function(confirmed)
        if #confirmed == 0 then return end

        vim.fn.mkdir(root .. "/layouts", "p")

        -- Generate Excel files; Word/RDLC are created by alc on next :ALCompile.
        local generated = {}
        for _, e in ipairs(confirmed) do
          if e.opt.type_str == "Excel" then
            local ok, err = pcall(function()
              local tmp = vim.fn.tempname() .. "_allayout"
              vim.fn.mkdir(tmp, "p")
              build_xlsx(tmp, info.dataitems)
              if not platform.create_zip(tmp, e.out_path) then
                error("zip failed (is python3/python on PATH?)")
              end
              rm_rf(tmp)
            end)
            if ok then
              table.insert(generated, e)
            else
              vim.notify("ALReportLayout: Excel generation failed — " .. tostring(err),
                vim.log.levels.ERROR)
            end
          else
            -- Word/RDLC: no file created here; alc handles it on compile.
            table.insert(generated, e)
          end
        end

        if #generated == 0 then return end

        -- DefaultRenderingLayout priority: Excel > RDLC > Word.
        local default_id = nil
        for _, prio in ipairs({ "Excel", "RDLC", "Word" }) do
          if not default_id then
            for _, e in ipairs(generated) do
              if e.opt.type_str == prio then default_id = e.id; break end
            end
          end
        end

        local render_entries = {}
        for _, e in ipairs(generated) do
          table.insert(render_entries, {
            id          = e.id,
            type_str    = e.opt.type_str,
            layout_file = "layouts/" .. e.id .. e.opt.ext,
          })
        end

        M._inject_rendering(bufnr, default_id, render_entries)

        -- Notify and open Excel files; notify-only for Word/RDLC.
        local compile_types = {}
        for _, e in ipairs(generated) do
          if e.opt.type_str == "Excel" then
            vim.notify("ALReportLayout: created " .. vim.fn.fnamemodify(e.out_path, ":~"),
              vim.log.levels.INFO)
            platform.open_url(e.out_path)
          else
            table.insert(compile_types, e.opt.type_str)
          end
        end
        if #compile_types > 0 then
          vim.notify(
            "ALReportLayout: " .. table.concat(compile_types, " + ")
            .. " rendering " .. (#compile_types == 1 and "entry" or "entries")
            .. " added — run :ALCompile (<leader>ab) to generate the layout "
            .. (#compile_types == 1 and "file" or "files") .. " with alc",
            vim.log.levels.INFO)
        end
      end)
    end)
  end)
end

-- ── Open existing layout ──────────────────────────────────────────────────────

function M.open_layout()
  local bufnr    = vim.api.nvim_get_current_buf()
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  if buf_path == "" then
    vim.notify("ALOpenLayout: buffer has no file path", vim.log.levels.WARN)
    return
  end

  local buf_dir = vim.fn.fnamemodify(buf_path, ":p:h")
  local root    = require("al.lsp").get_root(bufnr)

  local search_dirs = {}
  if root then
    local ld = root .. "/layouts"
    if vim.fn.isdirectory(ld) == 1 then table.insert(search_dirs, ld) end
  end
  if buf_dir ~= (root and root .. "/layouts" or "") then
    table.insert(search_dirs, buf_dir)
  end

  local found, seen = {}, {}
  for _, dir in ipairs(search_dirs) do
    for _, pat in ipairs({ "/*.xlsx", "/*.docx", "/*.rdlc" }) do
      for _, f in ipairs(vim.fn.glob(dir .. pat, false, true)) do
        if not seen[f] then seen[f] = true; table.insert(found, f) end
      end
    end
  end

  if #found == 0 then
    vim.notify("ALOpenLayout: no layout files found near this file", vim.log.levels.WARN)
    return
  end

  local function open_it(path)
    platform.open_url(path)
    vim.notify("ALOpenLayout: opening " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
  end

  if #found == 1 then
    open_it(found[1])
  else
    local labels = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":~") end, found)
    vim.ui.select(labels, { prompt = "Open layout:" }, function(choice)
      if not choice then return end
      for _, f in ipairs(found) do
        if vim.fn.fnamemodify(f, ":~") == choice then open_it(f); return end
      end
    end)
  end
end

return M
