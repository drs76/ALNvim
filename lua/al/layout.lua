-- AL Report Layout Wizard
-- Generates a starter Word (.docx) or Excel (.xlsx) layout from an AL report's
-- dataset columns.  Both formats are Office Open XML (ZIP of XML files).

local platform = require("al.platform")
local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function xml_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- 1-based column index → Excel column letter(s): 1→"A", 26→"Z", 27→"AA" …
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

-- Parse an AL report buffer.
-- Returns { report_id, report_name, dataitems = { {name, columns={...}} } }
-- or nil (with vim.notify) on failure.
function M._parse_report(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local info = { dataitems = {} }
  local current_di = nil

  for _, line in ipairs(lines) do
    -- report <id> "<name>"  (with or without quotes around name)
    if not info.report_id then
      local id, name = line:match("^%s*report%s+(%d+)%s+\"([^\"]+)\"")
      if not id then
        id, name = line:match("^%s*report%s+(%d+)%s+([%w_]+)")
      end
      if id then
        info.report_id   = tonumber(id)
        info.report_name = name
      end
    end

    -- dataitem(<name>; ...)
    local di_raw = line:match("^%s*dataitem%s*%(([^;,%)]+)")
    if di_raw then
      current_di = { name = strip_name(di_raw), columns = {} }
      table.insert(info.dataitems, current_di)
    end

    -- column(<name>; ...)
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
    vim.notify("ALReportLayout: no column() declarations found — add columns to the dataset first",
      vim.log.levels.WARN)
    return nil
  end
  return info
end

-- ── Word (.docx) XML generators ───────────────────────────────────────────────

local function docx_content_types()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml"  ContentType="application/xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/settings.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
</Types>]]
end

local function docx_rels()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="word/document.xml"/>
</Relationships>]]
end

local function docx_document_rels()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"
    Target="settings.xml"/>
</Relationships>]]
end

local function docx_settings()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:compat/>
</w:settings>]]
end

-- Build one header <w:tc> with bold text.
local function docx_header_cell(label)
  local e = xml_escape(label)
  return "<w:tc><w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
    .. "<w:r><w:rPr><w:b/></w:rPr><w:t>" .. e .. "</w:t></w:r></w:p></w:tc>"
end

-- Build one data <w:tc> with an inline SDT content control tagged with the column name.
-- BC's report engine matches the <w:tag> value to the AL dataset column name.
local function docx_data_cell(col_name)
  local e = xml_escape(col_name)
  return "<w:tc><w:p>"
    .. "<w:sdt>"
    .. "<w:sdtPr><w:tag w:val=\"" .. e .. "\"/><w:alias w:val=\"" .. e .. "\"/></w:sdtPr>"
    .. "<w:sdtContent><w:r><w:t>" .. e .. "</w:t></w:r></w:sdtContent>"
    .. "</w:sdt>"
    .. "</w:p></w:tc>"
end

local function docx_document(di_name, columns)
  local ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document ' .. ns .. '>',
    '<w:body>',
    -- Table
    '<w:tbl>',
    '<w:tblPr>',
    '  <w:tblStyle w:val="TableGrid"/>',
    '  <w:tblW w:w="0" w:type="auto"/>',
    '</w:tblPr>',
    -- Header row
    '<w:tr>',
  }
  for _, col in ipairs(columns) do
    table.insert(parts, docx_header_cell(col))
  end
  table.insert(parts, "</w:tr>")
  -- Data row (SDT content controls)
  table.insert(parts, "<w:tr>")
  for _, col in ipairs(columns) do
    table.insert(parts, docx_data_cell(col))
  end
  table.insert(parts, "</w:tr>")
  table.insert(parts, "</w:tbl>")
  -- Section properties
  table.insert(parts, "<w:sectPr/>")
  table.insert(parts, "</w:body>")
  table.insert(parts, "</w:document>")
  return table.concat(parts, "\n")
end

local function build_docx(tmpdir, di_name, columns)
  write_file(tmpdir .. "/[Content_Types].xml",      docx_content_types())
  write_file(tmpdir .. "/_rels/.rels",               docx_rels())
  write_file(tmpdir .. "/word/_rels/document.xml.rels", docx_document_rels())
  write_file(tmpdir .. "/word/settings.xml",         docx_settings())
  write_file(tmpdir .. "/word/document.xml",         docx_document(di_name, columns))
end

-- ── Excel (.xlsx) XML generators ─────────────────────────────────────────────

local function xlsx_content_types()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml"  ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml"
    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml"
    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/sharedStrings.xml"
    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
  <Override PartName="/xl/styles.xml"
    ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>]]
end

local function xlsx_rels()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="xl/workbook.xml"/>
</Relationships>]]
end

-- BC maps each dataitem to an Excel worksheet by sheet name.
local function xlsx_workbook(sheet_name)
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    .. '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    .. ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\n'
    .. '  <sheets>\n'
    .. '    <sheet name="' .. xml_escape(sheet_name) .. '" sheetId="1" r:id="rId1"/>\n'
    .. '  </sheets>\n'
    .. '</workbook>'
end

local function xlsx_workbook_rels()
  return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
    Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
    Target="sharedStrings.xml"/>
  <Relationship Id="rId3"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    Target="styles.xml"/>
</Relationships>]]
end

local function xlsx_shared_strings(columns)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    string.format('<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      .. ' count="%d" uniqueCount="%d">', #columns, #columns),
  }
  for _, col in ipairs(columns) do
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
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
  </cellXfs>
</styleSheet>]]
end

-- Row 1: column headers as shared-string references (t="s", value = 0-based index).
-- BC matches column headers to AL dataset column names when rendering the report.
local function xlsx_sheet(columns)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
      .. ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '  <sheetData>',
    '    <row r="1">',
  }
  for i, _ in ipairs(columns) do
    table.insert(parts,
      string.format('      <c r="%s1" t="s"><v>%d</v></c>', col_letter(i), i - 1))
  end
  table.insert(parts, "    </row>")
  table.insert(parts, "  </sheetData>")
  table.insert(parts, "</worksheet>")
  return table.concat(parts, "\n")
end

local function build_xlsx(tmpdir, di_name, columns)
  write_file(tmpdir .. "/[Content_Types].xml",           xlsx_content_types())
  write_file(tmpdir .. "/_rels/.rels",                    xlsx_rels())
  write_file(tmpdir .. "/xl/workbook.xml",                xlsx_workbook(di_name))
  write_file(tmpdir .. "/xl/_rels/workbook.xml.rels",     xlsx_workbook_rels())
  write_file(tmpdir .. "/xl/sharedStrings.xml",           xlsx_shared_strings(columns))
  write_file(tmpdir .. "/xl/styles.xml",                  xlsx_styles())
  write_file(tmpdir .. "/xl/worksheets/sheet1.xml",       xlsx_sheet(columns))
end

-- ── Wizard ────────────────────────────────────────────────────────────────────

local LAYOUT_TYPES = { "Word Layout (.docx)", "Excel Layout (.xlsx)" }

function M.generate()
  local bufnr = vim.api.nvim_get_current_buf()

  if vim.bo[bufnr].filetype ~= "al" then
    vim.notify("ALReportLayout: not an AL buffer", vim.log.levels.WARN)
    return
  end

  local info = M._parse_report(bufnr)
  if not info then return end

  -- If multiple dataitems, let the user pick one.
  local function pick_dataitem(cb)
    if #info.dataitems == 1 then
      cb(info.dataitems[1])
    else
      local names = vim.tbl_map(function(di) return di.name end, info.dataitems)
      vim.ui.select(names, { prompt = "Select dataitem:" }, function(choice)
        if not choice then cb(nil); return end
        for _, di in ipairs(info.dataitems) do
          if di.name == choice then cb(di); return end
        end
      end)
    end
  end

  pick_dataitem(function(di)
    if not di then return end

    vim.ui.select(LAYOUT_TYPES, { prompt = "Layout type:" }, function(choice)
      if not choice then return end
      local is_word = choice:find("Word") ~= nil
      local ext     = is_word and ".docx" or ".xlsx"

      -- Output path: same directory as the AL file.
      local buf_path = vim.api.nvim_buf_get_name(bufnr)
      local buf_dir  = vim.fn.fnamemodify(buf_path, ":p:h")
      local safe     = info.report_name:gsub('[\\/:*?"<>|]', "_")
      local out_path = buf_dir .. "/" .. safe .. ext

      local function do_generate()
        local tmpdir = vim.fn.tempname() .. "_allayout"
        vim.fn.mkdir(tmpdir, "p")

        local ok, err = pcall(function()
          if is_word then
            build_docx(tmpdir, di.name, di.columns)
          else
            build_xlsx(tmpdir, di.name, di.columns)
          end
        end)

        local zip_ok = ok and platform.create_zip(tmpdir, out_path)
        rm_rf(tmpdir)

        if not ok then
          vim.notify("ALReportLayout: generation failed — " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        if not zip_ok then
          vim.notify("ALReportLayout: zip failed (is python3 on PATH?)", vim.log.levels.ERROR)
          return
        end

        vim.notify(string.format("ALReportLayout: created %s (%d columns)",
          vim.fn.fnamemodify(out_path, ":~"), #di.columns), vim.log.levels.INFO)
        platform.open_url(out_path)
      end

      -- Confirm overwrite if file already exists.
      if vim.fn.filereadable(out_path) == 1 then
        vim.ui.select({ "Overwrite", "Cancel" },
          { prompt = vim.fn.fnamemodify(out_path, ":t") .. " exists. Overwrite?" },
          function(ans)
            if ans == "Overwrite" then do_generate() end
          end)
      else
        do_generate()
      end
    end)
  end)
end

return M
