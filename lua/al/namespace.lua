-- lua/al/namespace.lua
-- Namespace wizard: adds `namespace <ns>;` to all AL source files that don't
-- already have one, then optionally applies source.organizeImports via the LSP
-- to add the resulting missing `using` statements.
local M = {}

local lsp      = require("al.lsp")
local platform = require("al.platform")

-- Strip characters that are not valid in an AL namespace identifier segment.
-- AL identifiers: letters, digits, underscores only (no spaces or symbols).
function M.sanitize_name(str)
  if not str then return "" end
  return (str:gsub("[^%w_]", ""))
end

-- Build a namespace suggestion from app.json: "Publisher.AppName"
function M.suggest_namespace(root)
  local app = lsp.read_app_json(root)
  if not app then return "" end
  local pub  = M.sanitize_name(app.publisher or "")
  local name = M.sanitize_name(app.name or "")
  if pub == "" and name == "" then return "" end
  if pub == "" then return name end
  if name == "" then return pub end
  return pub .. "." .. name
end

-- Return true if the file already has a namespace declaration in its first 10 lines.
function M.has_namespace(path)
  local f = io.open(path, "r")
  if not f then return false end
  local found = false
  local i = 0
  for line in f:lines() do
    i = i + 1
    if i > 10 then break end
    if line:match("^%s*namespace%s+%S") then
      found = true
      break
    end
  end
  f:close()
  return found
end

-- Return the loaded buffer for `path`, or nil when the file is not open.
local function loaded_buf(path)
  local b = vim.fn.bufnr(path)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then return b end
  return nil
end

-- Add `namespace <ns>;` to the top of a single file.
-- Returns "added", "skipped" (already namespaced / unreadable), or "modified"
-- (open with unsaved changes — see add_namespace_to_project).
function M.add_namespace_to_file(path, ns)
  if M.has_namespace(path) then return "skipped" end

  -- Refuse to touch a file whose buffer has unsaved changes. This function
  -- writes with io.open, behind Neovim's back; the caller then reloads the
  -- buffer. On a modified buffer that reload fails with E37 (swallowed by
  -- `silent!`), leaving the buffer holding pre-namespace content that the
  -- user's next :w writes straight back over the namespace line.
  local buf = loaded_buf(path)
  if buf and vim.bo[buf].modified then return "modified" end

  local f = io.open(path, "r")
  if not f then return "skipped" end
  local content = f:read("*a")
  f:close()
  -- Normalise line endings to LF.
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local new_content = "namespace " .. ns .. ";\n\n" .. content
  local fw = io.open(path, "w")
  if not fw then return "skipped" end
  fw:write(new_content)
  fw:close()
  return "added"
end

-- Add namespace to all AL source files in the project.
-- Returns { added = {path, ...}, skipped = N, modified = {path, ...} }
-- `modified` lists files left untouched because they had unsaved changes.
function M.add_namespace_to_project(root, ns)
  local files    = platform.glob_al_files(root)
  local added    = {}
  local modified = {}
  local skipped  = 0
  for _, path in ipairs(files) do
    local result = M.add_namespace_to_file(path, ns)
    if result == "added" then
      table.insert(added, path)
    elseif result == "modified" then
      table.insert(modified, path)
    else
      skipped = skipped + 1
    end
  end
  return { added = added, skipped = skipped, modified = modified }
end

-- ── Add missing usings, without a language server ─────────────────────────
--
-- :ALAddUsings used to request source.organizeImports from the language
-- server. The AL tool's server (al launchlspserver) has no code actions at all,
-- so on it the command only produced "method textDocument/codeAction is not
-- supported". This resolves usings itself:
--
--   1. refs_in(lines): the objects a file references — variable types
--      (`Record X`, `Codeunit X`, …), `Page::X` / `Database::X`, `extends`,
--      `implements`, SourceTable, LookupPageId, TableRelation, part(),
--      dataitem(), Permissions.
--   2. A namespace index: every object of every package in the package cache,
--      read from the .app's SymbolReference.json (which names each object's
--      namespace even when the package ships no .al source), plus the
--      project's own files. Cached per .app on disk; building Base
--      Application's entry takes about a second, once.
--   3. For each reference not satisfied by the file's own namespace, an
--      existing using, or the global namespace: add `using <ns>;` when the name
--      resolves to exactly one namespace; report it when it resolves to several.
-- The compiler's AL0185 ("Table 'X' is missing") comes only for declarations
-- and reaches `Page::X` references a compile later, so it is not the source.

local KIND_KEYS = {
  Tables = "table", Codeunits = "codeunit", Pages = "page", Reports = "report",
  Queries = "query", XmlPorts = "xmlport", EnumTypes = "enum", Interfaces = "interface",
  PermissionSets = "permissionset", ControlAddIns = "controladdin",
}

-- One SymbolReference.json (decoded) → { [kind] = { [lowername] = { ns... } } }.
local function index_symbolref(d)
  local idx = {}
  local function add(kind, name, ns)
    if type(name) ~= "string" then return end
    idx[kind] = idx[kind] or {}
    local k = name:lower()
    idx[kind][k] = idx[kind][k] or {}
    for _, x in ipairs(idx[kind][k]) do if x == ns then return end end
    table.insert(idx[kind][k], ns)
  end
  local function walk(node, path)
    for key, kind in pairs(KIND_KEYS) do
      for _, o in ipairs(type(node[key]) == "table" and node[key] or {}) do add(kind, o.Name, path) end
    end
    for _, sub in ipairs(type(node.Namespaces) == "table" and node.Namespaces or {}) do
      if type(sub.Name) == "string" then
        walk(sub, path == "" and sub.Name or (path .. "." .. sub.Name))
      end
    end
  end
  walk(d, "")
  return idx
end

local function merge_index(into, from)
  for kind, names in pairs(from) do
    into[kind] = into[kind] or {}
    for name, list in pairs(names) do
      into[kind][name] = into[kind][name] or {}
      for _, ns in ipairs(list) do
        if not vim.tbl_contains(into[kind][name], ns) then table.insert(into[kind][name], ns) end
      end
    end
  end
  return into
end

-- Index of one .app, from the disk cache when it is newer than the package.
local function package_index(app)
  local platform = require("al.platform")
  local dir  = vim.fn.stdpath("cache") .. "/alnvim/nsindex"
  local key  = vim.fn.fnamemodify(app, ":t:r"):gsub("[^%w%._-]", "_")
  local path = dir .. "/" .. key .. ".json"
  local st_app, st_idx = vim.uv.fs_stat(app), vim.uv.fs_stat(path)
  if st_app and st_idx and st_idx.mtime.sec >= st_app.mtime.sec then
    local ok, lines = pcall(vim.fn.readfile, path)
    local ok2, idx = pcall(vim.json.decode, ok and table.concat(lines, "\n") or "")
    if ok2 and type(idx) == "table" then return idx end
  end
  local raw = platform.zip_member(app, "SymbolReference.json")
  if not raw then return {} end
  if raw:sub(1, 3) == "\239\187\191" then raw = raw:sub(4) end   -- UTF-8 BOM
  local ok, d = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  raw = nil
  if not ok or type(d) ~= "table" then return {} end
  local idx = index_symbolref(d)
  d = nil
  collectgarbage()   -- Base Application decodes to ~250 MB; give it back now
  vim.fn.mkdir(dir, "p")
  pcall(vim.fn.writefile, { vim.json.encode(idx) }, path)
  return idx
end

-- The project's own objects: `namespace X;` plus each file's object header.
local OBJ_KINDS = { "tableextension", "pageextension", "reportextension", "enumextension",
  "permissionsetextension", "pagecustomization", "table", "page", "codeunit", "report",
  "query", "xmlport", "enum", "interface", "permissionset", "controladdin" }

local function read_name(s)
  return s:match('^"([^"]+)"') or s:match("^([%a_][%w_]*)")
end

local function file_decl(lines)
  local ns, kind, name
  for _, l in ipairs(lines) do
    ns = ns or l:match("^%s*namespace%s+([%w%._]+)%s*;")
    if not kind then
      local low = l:lower()
      for _, k in ipairs(OBJ_KINDS) do
        local rest = low:match("^%s*" .. k .. "%s+(.+)$")
        if rest then
          local after_id = rest:match("^%d+%s+(.+)$") or rest
          local orig = l:sub(#l - #after_id + 1)
          kind, name = k, read_name(orig)
          break
        end
      end
    end
    if kind and ns then break end
  end
  return ns, kind, name
end

local function project_index(root)
  local idx = {}
  for _, f in ipairs(require("al.platform").glob_al_files(root)) do
    local ok, lines = pcall(vim.fn.readfile, f, "", 40)
    if ok then
      local ns, kind, name = file_decl(lines)
      if kind and name and not kind:find("extension") and kind ~= "pagecustomization" then
        merge_index(idx, { [kind] = { [name:lower()] = { ns or "" } } })
      end
    end
  end
  return idx
end

local function namespace_index(root)
  local cfg   = package.loaded["al"] and require("al").config or {}
  local cache = root .. "/" .. (cfg.packagecachepath or ".alpackages")
  local apps  = vim.fn.glob(cache .. "/*.app", false, true)
  local idx, pending = {}, 0
  for _, app in ipairs(apps) do
    local key = vim.fn.fnamemodify(app, ":t:r"):gsub("[^%w%._-]", "_")
    local p = vim.fn.stdpath("cache") .. "/alnvim/nsindex/" .. key .. ".json"
    local a, i = vim.uv.fs_stat(app), vim.uv.fs_stat(p)
    if not (a and i and i.mtime.sec >= a.mtime.sec) then pending = pending + 1 end
  end
  if pending > 0 then
    vim.notify(("AL usings: indexing %d symbol package(s) (first time only)…"):format(pending),
      vim.log.levels.INFO)
    vim.cmd.redraw()
  end
  for _, app in ipairs(apps) do merge_index(idx, package_index(app)) end
  return merge_index(idx, project_index(root))
end

-- Mask single-quoted string literals and // comments with spaces, keeping
-- double-quoted identifiers (they are the names we are looking for).
local function mask_code(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == "/" and line:sub(i + 1, i + 1) == "/" then
      out[#out + 1] = string.rep(" ", n - i + 1); break
    elseif c == '"' then           -- copy a quoted identifier through untouched
      local j = line:find('"', i + 1, true) or n
      out[#out + 1] = line:sub(i, j); i = j + 1
    elseif c == "'" then
      local j = i + 1
      while j <= n do
        if line:sub(j, j) == "'" then
          if line:sub(j + 1, j + 1) == "'" then j = j + 2 else break end
        else j = j + 1 end
      end
      out[#out + 1] = string.rep(" ", math.min(j, n) - i + 1); i = j + 1
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

-- Every (kind, lowercase name) a file references. Pure; lines in, list out.
local TYPE_KW = { record = "table", codeunit = "codeunit", page = "page", report = "report",
  query = "query", xmlport = "xmlport", enum = "enum", interface = "interface",
  testpage = "page", testrequestpage = "report" }
local SCOPE_KW = { database = "table", page = "page", report = "report", codeunit = "codeunit",
  query = "query", xmlport = "xmlport", enum = "enum" }
local NAME = '("[^"]+")'
local BARE = "([%a_][%w_]*)"

local function refs_in(lines)
  local out, seen = {}, {}
  local function add(kind, name)
    if not name then return end
    name = name:gsub('^"', ""):gsub('"$', ""):lower()
    local k = kind .. "\0" .. name
    if name ~= "" and not seen[k] then seen[k] = true; out[#out + 1] = { kind = kind, name = name } end
  end
  -- name at `s` in `line`: quoted or bare
  local function grab(line, s)
    return line:match("^" .. NAME, s) or line:match("^" .. BARE, s)
  end
  for _, raw in ipairs(lines) do
    local line = mask_code(raw)
    local low  = line:lower()
    -- Record X / Codeunit X / Page X … (`page 50100 "X"` headers: grab never
    -- returns a name starting with a digit)
    for kw, kind in pairs(TYPE_KW) do
      local i = 1
      while true do
        local s, e = low:find("%f[%w_]" .. kw .. "%s+", i)
        if not s then break end
        local nm = grab(line, e + 1)
        add(kind, nm)
        i = e + 1
      end
    end
    -- Page::X / Database::X …
    for kw, kind in pairs(SCOPE_KW) do
      local i = 1
      while true do
        local s, e = low:find("%f[%w_]" .. kw .. "::", i)
        if not s then break end
        add(kind, grab(line, e + 1))
        i = e + 1
      end
    end
    -- object header: extends / customizes / implements
    local hdr = low:match("^%s*(%a+)%s")
    local ext = { tableextension = "table", pageextension = "page", reportextension = "report",
                  enumextension = "enum", permissionsetextension = "permissionset",
                  pagecustomization = "page" }
    if hdr and ext[hdr] then
      local s = low:find("%f[%w]extends%s+") or low:find("%f[%w]customizes%s+")
      if s then add(ext[hdr], grab(line, select(2, low:find("%s+", s)) + 1)) end
    end
    local imp = low:find("%f[%w]implements%s+")
    if imp then
      local list = line:sub(select(2, low:find("%s+", imp)) + 1)
      for item in list:gmatch("[^,{]+") do
        local nm = read_name(vim.trim(item)); if nm then add("interface", nm) end
      end
    end
    -- properties
    local props = { sourcetable = "table", tablerelation = "table", lookuppageid = "page",
                    drilldownpageid = "page", cardpageid = "page" }
    for p, kind in pairs(props) do
      local _, e = low:find("%f[%w]" .. p .. "%s*=%s*")
      if e then add(kind, grab(line, e + 1)) end
    end
    -- part(Name; X)  dataitem(Name; X)  tableelement(Name; X)
    for kw, kind in pairs({ part = "page", dataitem = "table", tableelement = "table" }) do
      local _, e = low:find("%f[%w]" .. kw .. "%s*%([^;]*;%s*")
      if e then add(kind, grab(line, e + 1)) end
    end
    -- Permissions = tabledata X = RIMD, table Y = X
    local i = 1
    while true do
      local s, e = low:find("%f[%w]tabledata%s+", i)
      if not s then break end
      add("table", grab(line, e + 1)); i = e + 1
    end
  end
  return out
end

-- Which usings `lines` needs. Pure: idx is a namespace index as built above.
-- Returns (missing namespaces sorted, ambiguous { name, kind, candidates }).
local function missing_usings(lines, idx)
  local own, have = nil, {}
  for _, l in ipairs(lines) do
    own = own or l:match("^%s*namespace%s+([%w%._]+)%s*;")
    local u = l:match("^%s*using%s+([%w%._]+)%s*;")
    if u then have[u:lower()] = true end
  end
  local need, ambiguous = {}, {}
  for _, r in ipairs(refs_in(lines)) do
    local cands = (idx[r.kind] or {})[r.name]
    if cands and #cands > 0 then
      local ok = false
      for _, ns in ipairs(cands) do
        if ns == "" or (own and ns:lower() == own:lower()) or have[ns:lower()] then ok = true end
      end
      if not ok then
        if #cands == 1 then need[cands[1]] = true
        else ambiguous[#ambiguous + 1] = { name = r.name, kind = r.kind, candidates = cands } end
      end
    end
  end
  local list = vim.tbl_keys(need)
  table.sort(list)
  return list, ambiguous
end

-- Insert `using` lines: into the existing using block (kept sorted when it
-- was sorted), else after the namespace line, else at the top. Pure.
local function insert_usings(lines, add)
  if #add == 0 then return lines end
  local out = vim.deepcopy(lines)
  local first, last, ns_line
  for i, l in ipairs(out) do
    if l:match("^%s*namespace%s+[%w%._]+%s*;") and not ns_line then ns_line = i end
    if l:match("^%s*using%s+[%w%._]+%s*;") then first = first or i; last = i end
  end
  local new = vim.tbl_map(function(ns) return "using " .. ns .. ";" end, add)
  if first then
    local block = vim.list_slice(out, first, last)
    local sorted = vim.deepcopy(block); table.sort(sorted, function(a, b) return a:lower() < b:lower() end)
    local was_sorted = vim.deep_equal(block, sorted)
    vim.list_extend(block, new)
    if was_sorted then table.sort(block, function(a, b) return a:lower() < b:lower() end) end
    for _ = first, last do table.remove(out, first) end
    for k = #block, 1, -1 do table.insert(out, first, block[k]) end
  elseif ns_line then
    -- namespace X; / blank / usings / blank / object — whatever blank lines
    -- were there before are replaced by exactly that layout.
    while out[ns_line + 1] ~= nil and vim.trim(out[ns_line + 1]) == "" do
      table.remove(out, ns_line + 1)
    end
    local ins = { "" }
    vim.list_extend(ins, new)
    table.insert(ins, "")
    for k = #ins, 1, -1 do table.insert(out, ns_line + 1, ins[k]) end
  else
    table.insert(new, "")
    for k = #new, 1, -1 do table.insert(out, 1, new[k]) end
  end
  return out
end

-- :ALAddUsings. EditorServices still gets organizeImports (it has code
-- actions); everything else uses the resolver above.
function M.add_usings(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local client = require("al.lsp").client(bufnr)
  if client and client.name == "al_language_server"
    and client.server_capabilities.codeActionProvider then
    vim.lsp.buf.code_action({ context = { only = { "source.organizeImports" } } })
    return
  end
  local root = require("al.lsp").get_root(bufnr)
  if not root then
    vim.notify("AL usings: no project root (app.json) found", vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local idx = namespace_index(root)
  local add, ambiguous = missing_usings(lines, idx)
  for _, a in ipairs(ambiguous) do
    vim.notify(('AL usings: %s "%s" is in several namespaces (%s) — add the right one by hand')
      :format(a.kind, a.name, table.concat(a.candidates, ", ")), vim.log.levels.WARN)
  end
  if #add == 0 then
    vim.notify("AL usings: nothing to add", vim.log.levels.INFO)
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, insert_usings(lines, add))
  vim.notify("AL usings: added " .. table.concat(add, ", "), vim.log.levels.INFO)
end

M._test = { index_symbolref = index_symbolref, refs_in = refs_in, missing_usings = missing_usings,
            insert_usings = insert_usings, file_decl = file_decl, mask_code = mask_code }

-- fix_usings: batch organizeImports is not reliably achievable via LSP
-- for background buffers (server returns 0 actions without interactive context).
-- Notify the user to apply per-file with <leader>acn after the namespace wizard.
function M.fix_usings(files, on_done)
  if #files > 0 then
    vim.notify(
      string.format("AL: open each file and use <leader>acn to add missing using statements (%d file(s) affected)", #files),
      vim.log.levels.INFO)
  end
  if on_done then on_done() end
end

-- ── Change namespace (POC → PTE) ───────────────────────────────────────────
--
-- Moves every project namespace under an old prefix to a new one:
-- `Demo.Sales` → `Contoso.Sales` for old `Demo`, new `Contoso`. Rewrites
--   * `namespace P;` declarations under the old prefix,
--   * `using P;` lines and qualified references `P."Name"` / `P.Name` — but
--     only when P is a namespace the PROJECT declares. A dependency may share
--     the prefix (an app that depends on `Contoso.Core` while being renamed out
--     of `Contoso`); its usings must survive, or the build breaks.
-- Qualified references are matched only for namespaces of two or more
-- segments: `Demo.Run()` is more likely a codeunit variable named Demo than a
-- reference into namespace `Demo`. Strings and comments are skipped.

local function valid_ns(s)
  if type(s) ~= "string" or s == "" then return false end
  for _, seg in ipairs(vim.split(s, ".", { plain = true })) do
    if not seg:match("^[%a_][%w_]*$") then return false end
  end
  return true
end

-- Is `ns` equal to `old` or below it? (AL names are case-insensitive.)
local function under(ns, old)
  local a, b = ns:lower(), old:lower()
  return a == b or a:sub(1, #b + 1) == b .. "."
end

local function moved(ns, old, new) return new .. ns:sub(#old + 1) end

-- Pure: rewrite one file's lines. `known` = { [lower ns] = true } for the
-- namespaces the project declares. Returns new lines (or nil when unchanged)
-- and counts { decl, using, ref }.
local function change_ns_lines(lines, old, new, known)
  local n = { decl = 0, using = 0, ref = 0 }
  local out, changed = {}, false
  for i, line in ipairs(lines) do
    local res = line
    local pre, ns, post = line:match("^(%s*namespace%s+)([%w_%.]+)(%s*;.*)$")
    if ns and under(ns, old) then
      res, n.decl = pre .. moved(ns, old, new) .. post, n.decl + 1
    else
      pre, ns, post = line:match("^(%s*using%s+)([%w_%.]+)(%s*;.*)$")
      if ns then
        if known[ns:lower()] and under(ns, old) then
          res, n.using = pre .. moved(ns, old, new) .. post, n.using + 1
        end
      else
        -- Qualified references. Scan the masked line for dotted bare paths;
        -- positions line up because mask_code keeps the length.
        local masked = mask_code(line)
        local parts, last, pos = {}, 1, 1
        while true do
          local s, e = masked:find("[%a_][%w_]*%.[%a_][%w_%.]*", pos)
          if not s then break end
          local prev = s > 1 and masked:sub(s - 1, s - 1) or ""
          local tok = masked:sub(s, e):gsub("%.+$", "")
          e = s + #tok - 1
          local hit
          if not prev:match('[%w_%."]') then
            -- longest declared namespace that the token starts with, followed
            -- by "." (inside the token or right after it)
            local low = tok:lower()
            local segs = {}
            for seg in low:gmatch("[^%.]+") do segs[#segs + 1] = seg end
            for k = #segs, 2, -1 do
              local cand = table.concat(segs, ".", 1, k)
              local follows = (k < #segs) or masked:sub(e + 1, e + 1) == "."
              if follows and known[cand] and under(cand, old) then hit = #cand; break end
            end
          end
          if hit then
            parts[#parts + 1] = line:sub(last, s - 1)
            parts[#parts + 1] = moved(line:sub(s, s + hit - 1), old, new)
            last = s + hit
            n.ref = n.ref + 1
          end
          pos = e + 1
        end
        if #parts > 0 then
          parts[#parts + 1] = line:sub(last)
          res = table.concat(parts)
        end
      end
    end
    if res ~= line then changed = true end
    out[i] = res
  end
  return changed and out or nil, n
end

-- Read a file as lines, remembering its BOM, line ending and final newline so
-- the rewrite changes nothing but the namespaces.
local function read_lines(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  local bom = s:sub(1, 3) == "\239\187\191" and "\239\187\191" or ""
  s = s:sub(#bom + 1)
  local eol = s:find("\r\n", 1, true) and "\r\n" or "\n"
  local final = s:sub(-1) == "\n"
  local lines = vim.split(s, "\n", { plain = true })
  if final then table.remove(lines) end
  for i, l in ipairs(lines) do lines[i] = l:gsub("\r$", "") end
  return lines, { bom = bom, eol = eol, final = final }
end

local function write_lines(path, lines, fmt)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(fmt.bom, table.concat(lines, fmt.eol), fmt.final and fmt.eol or "")
  f:close()
  return true
end

-- Namespaces declared by the project's files: { [lower] = original }.
local function project_namespaces(files)
  local seen = {}
  for _, path in ipairs(files) do
    local lines = read_lines(path) or {}
    for i = 1, math.min(#lines, 20) do
      local ns = lines[i]:match("^%s*namespace%s+([%w_%.]+)%s*;")
      if ns then seen[ns:lower()] = seen[ns:lower()] or ns; break end
    end
  end
  return seen
end

-- Longest segment prefix shared by every declared namespace ("" when none).
local function common_prefix(seen)
  local list = vim.tbl_values(seen)
  table.sort(list)                       -- deterministic spelling of the result
  local segs
  for _, ns in ipairs(list) do
    local s = vim.split(ns, ".", { plain = true })
    if not segs then segs = s
    else
      local k = 0
      while k < #segs and k < #s and segs[k + 1]:lower() == s[k + 1]:lower() do k = k + 1 end
      for j = #segs, k + 1, -1 do segs[j] = nil end
    end
  end
  if not segs then return "" end
  return table.concat(segs, ".")
end

-- Plan the change across files. Returns { files = { {path, lines, fmt, n} },
-- modified = {path}, totals = {decl, using, ref} }.
function M.plan_change(root, old, new)
  local files = platform.glob_al_files(root)
  local seen = project_namespaces(files)
  local known = {}
  for k in pairs(seen) do known[k] = true end
  local plan = { files = {}, modified = {}, totals = { decl = 0, using = 0, ref = 0 } }
  for _, path in ipairs(files) do
    local lines, fmt = read_lines(path)
    if lines then
      local out, n = change_ns_lines(lines, old, new, known)
      if out then
        local buf = loaded_buf(path)
        if buf and vim.bo[buf].modified then
          plan.modified[#plan.modified + 1] = path
        else
          plan.files[#plan.files + 1] = { path = path, lines = out, fmt = fmt, n = n }
          for k, v in pairs(n) do plan.totals[k] = plan.totals[k] + v end
        end
      end
    end
  end
  return plan
end

function M.apply_change(plan)
  local written = 0
  for _, f in ipairs(plan.files) do
    if write_lines(f.path, f.lines, f.fmt) then
      written = written + 1
      local buf = loaded_buf(f.path)   -- unmodified (plan_change checked)
      if buf then vim.api.nvim_buf_call(buf, function() vim.cmd("silent! edit!") end) end
    end
  end
  return written
end

local function rel(p) return vim.fn.fnamemodify(p, ":~:.") end

-- :ALChangeNamespace [old new]
function M.change(root, old, new)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: no project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end
  local seen = project_namespaces(platform.glob_al_files(root))
  if not next(seen) then
    vim.notify("AL: no file declares a namespace — use :ALAddNamespace first", vim.log.levels.WARN)
    return
  end

  local function run(o, nw)
    if not valid_ns(o) or not valid_ns(nw) then
      vim.notify(("AL: not a valid namespace: %s"):format(valid_ns(o) and nw or o), vim.log.levels.ERROR)
      return
    end
    if o:lower() == nw:lower() then
      vim.notify("AL: old and new namespace are the same", vim.log.levels.WARN)
      return
    end
    local any = false
    for k in pairs(seen) do if under(k, o) then any = true end end
    if not any then
      local list = vim.tbl_values(seen); table.sort(list)
      vim.notify(("AL: no project namespace is under '%s'. Declared: %s")
        :format(o, table.concat(list, ", ")), vim.log.levels.WARN)
      return
    end
    local plan = M.plan_change(root, o, nw)
    if #plan.modified > 0 then
      vim.notify("AL: save these first (unsaved changes):\n  "
        .. table.concat(vim.tbl_map(rel, plan.modified), "\n  "),
        vim.log.levels.WARN)
      return
    end
    if #plan.files == 0 then
      vim.notify("AL: nothing to change", vim.log.levels.INFO)
      return
    end
    local t = plan.totals
    local summary = ("%d file(s): %d namespace, %d using, %d qualified reference(s)")
      :format(#plan.files, t.decl, t.using, t.ref)
    vim.ui.select({ "Yes — change " .. summary, "Cancel" },
      { prompt = ("Change namespace %s → %s?"):format(o, nw) },
      function(choice)
        if not choice or choice == "Cancel" then return end
        local w = M.apply_change(plan)
        vim.notify(("AL: namespace %s → %s in %d file(s). Projects that depend on this app need their usings updated too.")
          :format(o, nw, w), vim.log.levels.INFO)
      end)
  end

  if old and new then return run(old, new) end
  vim.ui.input({ prompt = "Old namespace (prefix): ", default = common_prefix(seen) }, function(o)
    if not o or o == "" then return end
    vim.ui.input({ prompt = "New namespace: ", default = M.suggest_namespace(root) }, function(nw)
      if not nw or nw == "" then return end
      run(vim.trim(o), vim.trim(nw))
    end)
  end)
end

-- Shared with lua/al/renumber.lua: file IO that keeps BOM, line ending and
-- final newline, the literal/comment mask, and the loaded-buffer lookup.
M.read_lines  = read_lines
M.write_lines = write_lines
M.mask_code   = mask_code
M.loaded_buf  = loaded_buf

M._test.change_ns_lines = change_ns_lines
M._test.common_prefix   = common_prefix
M._test.valid_ns        = valid_ns
M._test.read_lines      = read_lines
M._test.write_lines     = write_lines

-- Interactive wizard: prompt for namespace, add to all eligible files,
-- optionally fix using statements via LSP.
function M.wizard(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: no project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  -- Pre-scan to find candidates.
  local all_files = platform.glob_al_files(root)
  if #all_files == 0 then
    vim.notify("AL: no AL source files found in " .. root, vim.log.levels.WARN)
    return
  end

  local candidates = {}
  for _, path in ipairs(all_files) do
    if not M.has_namespace(path) then
      table.insert(candidates, path)
    end
  end

  if #candidates == 0 then
    vim.notify("AL: all files already have a namespace — nothing to do", vim.log.levels.INFO)
    return
  end

  -- Prompt for namespace, pre-filled with Publisher.AppName.
  local suggestion = M.suggest_namespace(root)
  vim.ui.input({
    prompt  = string.format("Namespace for %d file(s) [Publisher.AppName]: ", #candidates),
    default = suggestion,
  }, function(ns)
    if not ns or ns == "" then
      vim.notify("AL: namespace wizard cancelled", vim.log.levels.WARN)
      return
    end

    -- Confirm.
    vim.ui.select(
      { string.format("Yes — add namespace to %d file(s)", #candidates), "Cancel" },
      { prompt = "Add namespace '" .. ns .. "'?" },
      function(choice)
        if not choice or choice == "Cancel" then
          vim.notify("AL: namespace wizard cancelled", vim.log.levels.WARN)
          return
        end

        -- Add namespace declarations.
        local result = M.add_namespace_to_project(root, ns)

        -- Reload any already-open buffers so Neovim sees the changes on disk.
        -- edit! is safe here: add_namespace_to_file refuses to write a file
        -- whose buffer is modified, so nothing unsaved can be discarded.
        for _, path in ipairs(result.added) do
          local existing_buf = loaded_buf(path)
          if existing_buf then
            vim.api.nvim_buf_call(existing_buf, function()
              vim.cmd("silent! edit!")
            end)
          end
        end

        vim.notify(string.format(
          "AL: namespace '%s' added to %d file(s) (%d already had one)",
          ns, #result.added, result.skipped), vim.log.levels.INFO)

        if #result.modified > 0 then
          vim.notify(string.format(
            "AL: %d file(s) skipped — unsaved changes. Save them and re-run :ALAddNamespace:\n  %s",
            #result.modified,
            table.concat(vim.tbl_map(function(p)
              return vim.fn.fnamemodify(p, ":~:.")
            end, result.modified), "\n  ")), vim.log.levels.WARN)
        end

        if #result.added == 0 then return end

        vim.notify(
          "AL: open each file and use <leader>acn to add missing using statements",
          vim.log.levels.INFO)
      end
    )
  end)
end

return M
