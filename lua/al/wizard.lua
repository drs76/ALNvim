-- AL Object Wizard: interactive prompt flow to create a new AL object file.
--
-- M.new_object([root])  →  :ALNewObject
--   1. Pick object type (12 supported)
--   2. Enter object ID (pre-filled with next free ID from idRanges)
--   3. Enter object name
--   4. Type-specific extra prompts (DataClassification, PageType, extends, …)
--   5. Generate boilerplate, write to <root>/src/<id>.<Name>.<Type>.al, open it.

local M   = {}
local lsp = require("al.lsp")
local ids = require("al.ids")

-- ── Object type registry ───────────────────────────────────────────────────────

-- Each entry: { label, key, has_id, file_type }
-- file_type is used for the filename suffix and for id-scan in ids.lua
local TYPES = {
  { label = "Table",                key = "table",               has_id = true,  file_type = "Table" },
  { label = "Table Extension",      key = "tableextension",      has_id = true,  file_type = "TableExt" },
  { label = "Page",                 key = "page",                has_id = true,  file_type = "Page" },
  { label = "Page Extension",       key = "pageextension",       has_id = true,  file_type = "PageExt" },
  { label = "Codeunit",             key = "codeunit",            has_id = true,  file_type = "Codeunit" },
  { label = "Report",               key = "report",              has_id = true,  file_type = "Report" },
  { label = "Query",                key = "query",               has_id = true,  file_type = "Query" },
  { label = "XmlPort",              key = "xmlport",             has_id = true,  file_type = "XmlPort" },
  { label = "Enum",                 key = "enum",                has_id = true,  file_type = "Enum" },
  { label = "Enum Extension",       key = "enumextension",       has_id = true,  file_type = "EnumExt" },
  { label = "Interface",            key = "interface",           has_id = false, file_type = "Interface" },
  { label = "Permission Set",       key = "permissionset",       has_id = true,  file_type = "PermissionSet" },
}

local DATA_CLASSIFICATIONS = {
  "ToBeClassified",
  "CustomerContent",
  "AccountData",
  "EndUserIdentifiableInformation",
  "EndUserPseudonymousIdentifiers",
  "OrganizationIdentifiableInformation",
  "SystemMetadata",
}

local PAGE_TYPES = {
  "Card", "List", "CardPart", "ListPart", "Document",
  "Worksheet", "ListPlus", "RoleCenter", "HeadlinePart",
  "ConfirmationDialog", "NavigatePage", "StandardDialog", "API",
}

-- ── Templates ─────────────────────────────────────────────────────────────────

local function tpl_table(d)
  local dc = d.data_class or "ToBeClassified"
  return string.format([[table %d "%s"
{
    Caption = '%s';
    DataClassification = %s;

    fields
    {
        field(1; "Code"; Code[20])
        {
            Caption = 'Code';
            DataClassification = %s;
        }
    }

    keys
    {
        key(PK; "Code")
        {
            Clustered = true;
        }
    }
}
]], d.id, d.name, d.name, dc, dc)
end

local function tpl_tableextension(d)
  return string.format([[tableextension %d "%s" extends "%s"
{
    fields
    {
    }
}
]], d.id, d.name, d.extends or "")
end

local function tpl_page(d)
  local src = d.source_table and ('"' .. d.source_table .. '"') or '""'
  local pt  = d.page_type or "Card"

  -- Build field controls for the layout
  local field_lines = {}
  if d.fields and #d.fields > 0 then
    for _, fname in ipairs(d.fields) do
      field_lines[#field_lines + 1] = string.format(
        '                field("%s"; Rec."%s")\n                {\n                    ApplicationArea = All;\n                }',
        fname, fname)
    end
  end

  -- List-type pages use repeater; others use group
  local is_list = (pt == "List" or pt == "ListPart" or pt == "ListPlus")
  local container
  if is_list then
    if #field_lines > 0 then
      container = "            repeater(Lines)\n            {\n"
        .. table.concat(field_lines, "\n") .. "\n            }"
    else
      container = "            repeater(Lines)\n            {\n            }"
    end
  else
    if #field_lines > 0 then
      container = "            group(General)\n            {\n                Caption = 'General';\n"
        .. table.concat(field_lines, "\n") .. "\n            }"
    else
      container = "            group(General)\n            {\n                Caption = 'General';\n            }"
    end
  end

  return string.format([[page %d "%s"
{
    Caption = '%s';
    PageType = %s;
    SourceTable = %s;
    UsageCategory = None;
    ApplicationArea = All;

    layout
    {
        area(Content)
        {
%s
        }
    }

    actions
    {
        area(Processing)
        {
        }
    }
}
]], d.id, d.name, d.name, pt, src, container)
end

local function tpl_pageextension(d)
  return string.format([[pageextension %d "%s" extends "%s"
{
    layout
    {
        addlast(General)
        {
        }
    }

    actions
    {
        addlast(Processing)
        {
        }
    }
}
]], d.id, d.name, d.extends or "")
end

local function tpl_codeunit(d)
  return string.format([[codeunit %d "%s"
{
    trigger OnRun()
    begin
    end;
}
]], d.id, d.name)
end

local function tpl_report(d)
  local src = d.source_table or "SourceTable"
  return string.format([[report %d "%s"
{
    Caption = '%s';
    UsageCategory = ReportsAndAnalysis;
    ApplicationArea = All;

    dataset
    {
        dataitem(DataItemName; "%s")
        {
        }
    }

    requestpage
    {
        layout
        {
        }

        actions
        {
        }
    }
}
]], d.id, d.name, d.name, src)
end

local function tpl_query(d)
  local src = d.source_table or "SourceTable"
  return string.format([[query %d "%s"
{
    Caption = '%s';
    QueryType = Normal;

    elements
    {
        dataitem(DataItemName; "%s")
        {
        }
    }
}
]], d.id, d.name, d.name, src)
end

local function tpl_xmlport(d)
  return string.format([[xmlport %d "%s"
{
    Caption = '%s';
    Direction = Both;

    schema
    {
        textelement(RootNodeName)
        {
            tableelement(TableRow; "SourceTable")
            {
            }
        }
    }

    requestpage
    {
        layout
        {
        }

        actions
        {
        }
    }
}
]], d.id, d.name, d.name)
end

local function tpl_enum(d)
  local ext = (d.extensible == false) and "false" or "true"
  return string.format([[enum %d "%s"
{
    Extensible = %s;
    Caption = '%s';

    value(0; " ")
    {
        Caption = ' ';
    }
}
]], d.id, d.name, ext, d.name)
end

local function tpl_enumextension(d)
  return string.format([[enumextension %d "%s" extends "%s"
{
    value(%d; "NewValue")
    {
        Caption = 'New Value';
    }
}
]], d.id, d.name, d.extends or "", d.id)
end

local function tpl_interface(d)
  return string.format([[interface "%s"
{
    procedure MyProcedure(): Boolean;
}
]], d.name)
end

local function tpl_permissionset(d)
  local perm_lines = {}
  if d.permissions and #d.permissions > 0 then
    for i, p in ipairs(d.permissions) do
      local sep = (i < #d.permissions) and "," or ";"
      perm_lines[#perm_lines + 1] = string.format(
        '        %s "%s" = %s%s', p.perm_type, p.name, p.perms, sep)
    end
  else
    perm_lines[#perm_lines + 1] = "        ;"
  end
  return string.format([[permissionset %d "%s"
{
    Caption = '%s';
    Assignable = true;

    Permissions =
%s
}
]], d.id, d.name, d.name, table.concat(perm_lines, "\n"))
end

local TEMPLATES = {
  table          = tpl_table,
  tableextension = tpl_tableextension,
  page           = tpl_page,
  pageextension  = tpl_pageextension,
  codeunit       = tpl_codeunit,
  report         = tpl_report,
  query          = tpl_query,
  xmlport        = tpl_xmlport,
  enum           = tpl_enum,
  enumextension  = tpl_enumextension,
  interface      = tpl_interface,
  permissionset  = tpl_permissionset,
}

-- ── Object list helpers ───────────────────────────────────────────────────────

-- Return sorted list of object names of the given AL type across project + symbols.
local function get_objects_of_type(root, obj_type)
  local search_dirs = require("al.explorer").build_search_dirs(root)
  -- rg -i for case-insensitive match (AL keywords can be any case)
  local pat = string.format("^\\s*%s\\s+\\d+", obj_type)
  local cmd = {
    "rg", "--no-heading", "--no-filename", "--color=never", "-i",
    "--glob", "*.al", "--glob", "*.AL",
    "-e", pat,
  }
  vim.list_extend(cmd, search_dirs)
  local raw   = vim.fn.systemlist(cmd)
  local seen  = {}
  local names = {}
  -- Match: optional whitespace, keyword (any case), whitespace, digits, whitespace, rest
  local extract = "^%s*[%a]+%s+%d+%s*(.*)"
  for _, line in ipairs(raw) do
    local rest = line:match(extract)
    if rest then
      local name = rest:match('^"([^"]+)"')
                or rest:match("^'([^']+)'")
                or rest:gsub("%s*;?%s*$", ""):gsub("%s+$", "")
      if name and name ~= "" and not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

-- Show a vim.ui.select picker for objects of the given type, then call cb(name) or cb(nil).
local function pick_object(root, obj_type, prompt, cb)
  local list = get_objects_of_type(root, obj_type)
  if #list == 0 then
    vim.notify("AL Wizard: no " .. obj_type .. " objects found — enter name manually", vim.log.levels.WARN)
    vim.ui.input({ prompt = prompt }, function(val)
      cb(val == nil and nil or (val ~= "" and val or nil))
    end)
    return
  end
  vim.ui.select(list, { prompt = prompt }, function(choice)
    cb(choice)  -- nil when cancelled
  end)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function sanitise_name(name)
  return name:gsub("%s+", "_"):gsub("[^%w_%-]", "")
end

-- Read CRS.ObjectNameSuffix from .vscode/settings.json, walking upward from
-- root. Falls back to require("al").config.object_name_suffix.
local function read_crs_suffix(root)
  local path = root
  for _ = 1, 4 do
    local f = io.open(path .. "/.vscode/settings.json", "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, settings = pcall(vim.fn.json_decode, content)
      if ok and type(settings) == "table" then
        local s = settings["CRS.ObjectNameSuffix"]
        if type(s) == "string" and s ~= "" then return s end
      end
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end
    path = parent
  end
  return require("al").config.object_name_suffix
end

-- Strip an affix from the end or start of a name (case-insensitive).
-- "DavesCd PTE" / "PTE" → "DavesCd";  "PTEDavesCd" / "PTE" → "DavesCd"
local function strip_affix(name, affix)
  if not affix or affix == "" then return name end
  local nl, al = name:lower(), affix:lower()
  if nl:sub(-#al) == al then          -- suffix
    return vim.trim(name:sub(1, -#al - 1))
  end
  if nl:sub(1, #al) == al then        -- prefix
    return vim.trim(name:sub(#al + 1))
  end
  return name
end

-- Return true when name already carries the affix (as suffix or prefix).
local function has_affix(name, affix)
  if not affix or affix == "" then return true end
  local nl, al = name:lower(), affix:lower()
  return nl:sub(-#al) == al or nl:sub(1, #al) == al
end

-- Return (zero-based line index, raw line text, object name) for the first
-- AL object declaration found in the buffer.
local function find_obj_decl(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
  for i, line in ipairs(lines) do
    -- With ID: keyword <num> "Name"  or  keyword <num> Name
    local name = line:match('^%s*%a+%s+%d+%s+"([^"]+)"')
              or line:match("^%s*%a+%s+%d+%s+'([^']+)'")
              or line:match('^%s*%a+%s+%d+%s+([^%s{"\'][^{]*)')
    -- Interface (no ID): interface "Name"
    if not name then
      name = line:match('^%s*interface%s+"([^"]+)"')
          or line:match("^%s*interface%s+'([^']+)'")
          or line:match('^%s*interface%s+([^%s{"\']+)')
    end
    if name then return i - 1, line, vim.trim(name) end
  end
end

-- PascalCase file-type suffix per object type key (matches TYPES table).
local FILE_TYPE_MAP = {
  table="Table", tableextension="TableExt", page="Page",
  pageextension="PageExt", pagecustomization="PageCust",
  codeunit="Codeunit", report="Report", reportextension="ReportExt",
  query="Query", xmlport="XmlPort", enum="Enum", enumextension="EnumExt",
  interface="Interface", permissionset="PermissionSet",
  permissionsetextension="PermissionSetExt", profile="Profile",
  profileextension="ProfileExt", controladdin="ControlAddin",
}

local function build_path(root, info, id, name)
  -- Strip the CRS affix from the name for the filename (object declaration
  -- keeps the full name; organise_file will enforce it on first save).
  local suffix = read_crs_suffix(root)
  local dname  = strip_affix(name, suffix)
  local sname  = sanitise_name(dname)
  local fname  = sname .. "." .. info.file_type .. ".al"
  local dir    = root .. "/src/" .. info.key
  return dir, dir .. "/" .. fname
end

local function write_and_open(path, content)
  local lines = vim.split(content, "\n", { plain = true })
  -- Remove trailing blank line added by format strings
  if lines[#lines] == "" then table.remove(lines) end
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    vim.notify("AL Wizard: could not write file: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.notify("AL Wizard: created " .. vim.fn.fnamemodify(path, ":~:."), vim.log.levels.INFO)
end

-- ── Permission set helpers ────────────────────────────────────────────────────

-- Scan the project source and return a list of permission entries covering every
-- table, page, codeunit, report, query and xmlport found.
-- Tables get both a tabledata (RIMD) and a table (X) entry.
-- Uses vim.fn.glob + vim.fn.readfile to avoid rg unreliability on network mounts.
local PERM_KEYWORDS = {
  table = true, page = true, codeunit = true,
  report = true, query = true, xmlport = true,
}

local function scan_project_objects(root)
  local files = require("al.platform").glob_al_files(root)

  local entries = {}
  local seen    = {}  -- deduplicate by "type:name"

  for _, fpath in ipairs(files) do
    -- io.open avoids Vim's VFS layer — more reliable on CIFS/SMB mounts
    local f = io.open(fpath, "r")
    if f then
      -- Read first 10 lines — object declaration is always near the top
      local lines = {}
      for _ = 1, 10 do
        local ln = f:read("*l")
        if not ln then break end
        lines[#lines + 1] = ln
      end
      f:close()
      for _, line in ipairs(lines) do
        -- Strip Windows \r if present
        line = line:gsub("\r$", "")
        local kw, rest = line:match("^%s*([%a]+)%s+%d+%s*(.*)")
        if kw and PERM_KEYWORDS[kw:lower()] then
          local name = rest:match('^"([^"]+)"')
                  or rest:match("^'([^']+)'")
                  or rest:match("^([^%s{]+)")  -- unquoted identifier
          if name and name ~= "" then
            local kw_lower = kw:lower()
            local key_td   = "tabledata:" .. name
            local key_tb   = kw_lower .. ":" .. name
            if kw_lower == "table" then
              if not seen[key_td] then
                seen[key_td] = true
                entries[#entries + 1] = { perm_type = "tabledata", name = name, perms = "RIMD" }
              end
              if not seen[key_tb] then
                seen[key_tb] = true
                entries[#entries + 1] = { perm_type = "table", name = name, perms = "X" }
              end
            else
              if not seen[key_tb] then
                seen[key_tb] = true
                entries[#entries + 1] = { perm_type = kw_lower, name = name, perms = "X" }
              end
            end
          end
        end
      end
    end
  end

  -- Sort: tabledata first, then by type, then by name
  local order = { tabledata = 1, table = 2, page = 3, codeunit = 4,
                  report = 5, query = 6, xmlport = 7 }
  table.sort(entries, function(a, b)
    local oa, ob = order[a.perm_type] or 99, order[b.perm_type] or 99
    if oa ~= ob then return oa < ob end
    return a.name:lower() < b.name:lower()
  end)
  return entries
end

-- Find the .al file that declares the named table (project + symbol caches),
-- then extract its field names. Uses io.open to avoid CIFS/VFS issues.
local function scan_table_fields(root, table_name)
  local search_dirs = require("al.explorer").build_search_dirs(root)

  -- Step 1: find the file that contains the table declaration
  local target_file
  local platform = require("al.platform")
  for _, dir in ipairs(search_dirs) do
    local files = platform.glob_al_files(dir)
    for _, fpath in ipairs(files) do
      local f = io.open(fpath, "r")
      if f then
        local first = f:read("*l")
        f:close()
        if first then
          first = first:gsub("\r$", "")
          local kw, rest = first:match("^%s*([%a]+)%s+%d+%s*(.*)")
          if kw and kw:lower() == "table" then
            local nm = rest:match('^"([^"]+)"') or rest:match("^'([^']+)'") or rest:match("^([^%s{]+)")
            if nm and nm:lower() == table_name:lower() then
              target_file = fpath
              break
            end
          end
        end
      end
    end
    if target_file then break end
  end

  if not target_file then return {} end

  -- Step 2: extract field names from the table file
  local fields = {}
  local f = io.open(target_file, "r")
  if not f then return {} end

  local in_fields = false
  for line in f:lines() do
    line = line:gsub("\r$", "")
    -- Enter fields block
    if not in_fields and line:match("^%s*fields%s*{?%s*$") then
      in_fields = true
    elseif in_fields then
      -- Leave fields block when we hit keys or fieldgroups
      if line:match("^%s*keys%s") or line:match("^%s*fieldgroups%s") then break end
      -- Field declaration anchored to start of line (avoids matching code inside triggers)
      local name = line:match('^%s*field%s*%([^;]+;%s*"([^"]+)"')
                or line:match("^%s*field%s*%([^;]+;%s*'([^']+)'")
      if not name then
        local unquoted = line:match("^%s*field%s*%([^;]+;%s*([%w_][^;]-)%s*;")
        if unquoted then name = unquoted:gsub("%s+$", "") end
      end
      if name and name ~= "" then
        fields[#fields + 1] = name
      end
    end
  end
  f:close()

  return fields
end

-- ── Type-specific extra prompts ───────────────────────────────────────────────

-- Each handler calls cb(data) when done, or cb(nil) to abort.
local extra_prompts = {}

extra_prompts.table = function(data, cb)
  vim.ui.select(DATA_CLASSIFICATIONS, {
    prompt = "Data Classification:",
  }, function(choice)
    if not choice then cb(nil); return end
    data.data_class = choice
    cb(data)
  end)
end

extra_prompts.tableextension = function(data, cb)
  pick_object(data.root, "table", "Extends table:", function(choice)
    if not choice then cb(nil); return end
    data.extends = choice
    cb(data)
  end)
end

extra_prompts.page = function(data, cb)
  -- 1. Pick page type
  vim.ui.select(PAGE_TYPES, { prompt = "Page Type:" }, function(pt)
    if not pt then cb(nil); return end
    data.page_type = pt
    data.fields    = {}

    -- 2. Pick source table (with "none" at top so Esc still cancels the whole wizard)
    local table_list   = get_objects_of_type(data.root, "table")
    local NO_TABLE     = "— No source table —"
    local display_list = { NO_TABLE }
    vim.list_extend(display_list, table_list)

    vim.ui.select(display_list, { prompt = "Source Table:" }, function(choice)
      if choice == nil then cb(nil); return end  -- Esc = cancel wizard
      if choice == NO_TABLE then
        data.source_table = nil
        cb(data)
        return
      end
      data.source_table = choice

      -- Defer so the source-table picker fully closes before opening a new one
      vim.schedule(function()
        -- 3. Scan fields of the chosen table
        local field_list = scan_table_fields(data.root, choice)
        if #field_list == 0 then
          cb(data)
          return
        end

        -- 4. Multi-select field picker; skip if Telescope unavailable
        if not pcall(require, "telescope") then
          cb(data)
          return
        end

        local pickers      = require("telescope.pickers")
        local finders      = require("telescope.finders")
        local conf         = require("telescope.config").values
        local actions      = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        pickers.new({}, {
          prompt_title = string.format('Fields from "%s"  (<Tab> toggle, <CR> confirm)', choice),
          finder = finders.new_table({
            results     = field_list,
            entry_maker = function(fname)
              return { value = fname, display = fname, ordinal = fname }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
              local picker = action_state.get_current_picker(prompt_bufnr)
              local multi  = picker:get_multi_selection()
              if #multi == 0 then
                local sel = action_state.get_selected_entry()
                if sel then multi = { sel } end
              end
              actions.close(prompt_bufnr)
              data.fields = vim.tbl_map(function(s) return s.value end, multi)
              cb(data)
            end)
            -- Esc = proceed without fields
            map({ "i", "n" }, "<Esc>", function()
              actions.close(prompt_bufnr)
              data.fields = {}
              cb(data)
            end)
            map({ "i", "n" }, "<Tab>", actions.toggle_selection + actions.move_selection_next)
            return true
          end,
        }):find()
      end)  -- vim.schedule
    end)  -- display_list select
  end)  -- PAGE_TYPES select
end

extra_prompts.pageextension = function(data, cb)
  pick_object(data.root, "page", "Extends page:", function(choice)
    if not choice then cb(nil); return end
    data.extends = choice
    cb(data)
  end)
end

extra_prompts.report = function(data, cb)
  vim.ui.input({ prompt = "Source Table: " }, function(val)
    if val == nil then cb(nil); return end
    data.source_table = val ~= "" and val or "SourceTable"
    cb(data)
  end)
end

extra_prompts.query = function(data, cb)
  vim.ui.input({ prompt = "Source Table: " }, function(val)
    if val == nil then cb(nil); return end
    data.source_table = val ~= "" and val or "SourceTable"
    cb(data)
  end)
end

extra_prompts.enum = function(data, cb)
  vim.ui.select({ "true", "false" }, { prompt = "Extensible:" }, function(choice)
    if not choice then cb(nil); return end
    data.extensible = (choice == "true")
    cb(data)
  end)
end

extra_prompts.enumextension = function(data, cb)
  pick_object(data.root, "enum", "Extends enum:", function(choice)
    if not choice then cb(nil); return end
    data.extends = choice
    cb(data)
  end)
end

extra_prompts.permissionset = function(data, cb)
  local entries = scan_project_objects(data.root)
  if #entries == 0 then
    vim.notify("AL Wizard: no objects found in project source — empty permission set created",
      vim.log.levels.WARN)
    data.permissions = {}
    cb(data)
    return
  end
  -- Count unique objects (tabledata + table count as one table object)
  local obj_count = 0
  for _, e in ipairs(entries) do
    if e.perm_type ~= "tabledata" then obj_count = obj_count + 1 end
  end
  vim.notify(string.format(
    "AL Wizard: generated permissions for %d objects (%d entries)",
    obj_count, #entries), vim.log.levels.INFO)
  data.permissions = entries
  cb(data)
end

-- ── Wizard runner ─────────────────────────────────────────────────────────────

local function run_wizard(root, info)
  local data = { root = root }

  local function finish()
    local content = TEMPLATES[info.key](data)
    local dir, path = build_path(root, info, data.id, data.name)
    vim.fn.mkdir(dir, "p")

    if vim.fn.filereadable(path) == 1 then
      vim.ui.select({ "Yes", "No" }, {
        prompt = vim.fn.fnamemodify(path, ":~:.") .. " already exists. Overwrite?",
      }, function(choice)
        if choice == "Yes" then
          write_and_open(path, content)
        else
          vim.notify("AL Wizard: cancelled", vim.log.levels.INFO)
        end
      end)
    else
      write_and_open(path, content)
    end
  end

  local function prompt_extras()
    local handler = extra_prompts[info.key]
    if handler then
      handler(data, function(result)
        if not result then
          vim.notify("AL Wizard: cancelled", vim.log.levels.INFO)
          return
        end
        finish()
      end)
    else
      finish()
    end
  end

  local function prompt_name()
    vim.ui.input({ prompt = info.label .. " name: " }, function(name)
      if not name or name == "" then
        vim.notify("AL Wizard: cancelled", vim.log.levels.INFO)
        return
      end
      data.name = name
      prompt_extras()
    end)
  end

  if info.has_id then
    local suggested = ids.next_id(root, info.key)
    local default   = suggested and tostring(suggested) or ""
    vim.ui.input({ prompt = "Object ID: ", default = default }, function(val)
      if not val or val == "" then
        vim.notify("AL Wizard: cancelled", vim.log.levels.INFO)
        return
      end
      local n = tonumber(val)
      if not n then
        vim.notify("AL Wizard: invalid ID", vim.log.levels.ERROR)
        return
      end
      data.id = n
      prompt_name()
    end)
  else
    prompt_name()
  end
end

-- ── File organiser ────────────────────────────────────────────────────────────

-- All AL object type keywords that warrant their own src/ subfolder.
local ORG_TYPES = {
  table=1, tableextension=1, page=1, pageextension=1, pagecustomization=1,
  codeunit=1, report=1, reportextension=1, query=1, xmlport=1,
  enum=1, enumextension=1, interface=1, permissionset=1, permissionsetextension=1,
  profile=1, profileextension=1, controladdin=1,
}

local function detect_obj_type(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
  for _, line in ipairs(lines) do
    -- Types with numeric IDs: keyword <number>
    local typ = line:match("^%s*([%a]+)%s+%d+")
    if typ and ORG_TYPES[typ:lower()] then return typ:lower() end
    -- Interface has no numeric ID: interface "Name"
    if line:lower():match('^%s*interface%s+["\']') then return "interface" end
  end
  return nil
end

-- Guard against re-entrancy when organise_file triggers a :write.
local _organising = false

-- Called from BufWritePost.
-- 1. Enforces CRS.ObjectNameSuffix on the object declaration (adds it if missing).
-- 2. Moves the file into src/<obj_type>/ if not already there.
-- 3. Renames the file to <NameWithoutAffix>.<FileType>.al (CRS convention).
function M.organise_file(bufnr)
  if _organising then return end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end

  local root = lsp.get_root(bufnr)
  if not root then return end

  if path:sub(1, #root) ~= root then return end

  local obj_type = detect_obj_type(bufnr)
  if not obj_type then return end

  local suffix    = read_crs_suffix(root)
  local file_type = FILE_TYPE_MAP[obj_type] or obj_type

  -- ── 1. Enforce suffix in the object declaration ───────────────────────────
  local decl_lnum, decl_line, obj_name = find_obj_decl(bufnr)
  local name_modified = false

  if obj_name and suffix and not has_affix(obj_name, suffix) then
    -- Append suffix inside the existing quotes, or wrap unquoted name.
    local new_name = obj_name .. " " .. suffix
    local new_line
    -- Try replacing quoted form first
    new_line = decl_line:gsub('"' .. vim.pesc(obj_name) .. '"', '"' .. new_name .. '"', 1)
    if new_line == decl_line then
      new_line = decl_line:gsub("'" .. vim.pesc(obj_name) .. "'", '"' .. new_name .. '"', 1)
    end
    if new_line == decl_line then
      -- Unquoted: wrap in quotes with suffix
      new_line = decl_line:gsub(vim.pesc(obj_name), '"' .. new_name .. '"', 1)
    end
    if new_line ~= decl_line then
      vim.api.nvim_buf_set_lines(bufnr, decl_lnum, decl_lnum + 1, false, { new_line })
      obj_name = new_name
      name_modified = true
    end
  end

  -- ── 2. Compute the CRS target path ───────────────────────────────────────
  local display   = obj_name and strip_affix(obj_name, suffix) or vim.fn.fnamemodify(path, ":t:r")
  local fname     = sanitise_name(display) .. "." .. file_type .. ".al"
  local targetdir = root .. "/src/" .. obj_type
  local target    = targetdir .. "/" .. fname

  -- Nothing to do if already correct.
  if target == path and not name_modified then return end

  -- ── 3. Move / rename ─────────────────────────────────────────────────────
  vim.fn.mkdir(targetdir, "p")

  if target ~= path then
    if vim.fn.rename(path, target) ~= 0 then
      vim.notify("AL: could not rename file to " .. target, vim.log.levels.ERROR)
      return
    end
    vim.api.nvim_buf_set_name(bufnr, target)
  end

  -- Write the buffer so the suffix change (and/or new path) is persisted.
  _organising = true
  local ok, err = pcall(vim.cmd, "write")
  _organising = false
  if not ok then
    vim.notify("AL: write failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.bo[bufnr].modified = false
  local msg = target ~= path and ("AL: organised → " .. vim.fn.fnamemodify(target, ":~:."))
                              or  ("AL: added suffix → " .. obj_name)
  vim.notify(msg, vim.log.levels.INFO)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.new_object(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL Wizard: no project root found", vim.log.levels.ERROR)
    return
  end

  local labels = {}
  for _, t in ipairs(TYPES) do
    table.insert(labels, t.label)
  end

  vim.ui.select(labels, { prompt = "AL Object Type:" }, function(choice)
    if not choice then return end
    local info
    for _, t in ipairs(TYPES) do
      if t.label == choice then info = t; break end
    end
    if info then run_wizard(root, info) end
  end)
end

return M
