-- Go-to-definition into base-app objects for the agentic LSP (al launchlspserver).
--
-- The tool's language server resolves base symbols — hover shows a base table's
-- fields, completion lists them — but textDocument/definition returns nothing
-- for anything defined in a symbol package, because there is no file to point
-- at. EditorServices covers this with its own al-preview:// documents; the
-- standard server has no equivalent. So gd on `Record "Sales Header"` or
-- `SH.InitInsert` went nowhere, and that is most gd presses in real AL.
--
-- The fallback uses what the server *does* answer. Hover names the target
-- precisely:
--
--   cursor on an object     →  Table Microsoft.Sales.Document."Sales Header"
--   cursor on a variable    →  (local) SH: Record "Sales Header"
--
-- From that we find the object's declaration in the .al stubs AL Explorer
-- already extracts from .alpackages, and for `Var.Member` jump on to the field,
-- procedure or enum value inside it.
--
-- Limit: symbol packages from the public NuGet feeds carry no source, so there
-- is nothing to open for those; the user is told, and hover (K) still works.
-- Packages downloaded from a BC server usually do include source.

local M = {}

-- Object kinds as they appear in hover text, mapped to the AL keyword that
-- declares them. Variables say `Record`; the object is a `table`.
local KINDS = {
  table = "table", record = "table", page = "page", codeunit = "codeunit",
  report = "report", query = "query", xmlport = "xmlport", enum = "enum",
  interface = "interface", permissionset = "permissionset",
  controladdin = "controladdin", tableextension = "tableextension",
  pageextension = "pageextension", enumextension = "enumextension",
  reportextension = "reportextension",
}

-- The last segment of a possibly namespaced, possibly quoted name:
--   Microsoft.Sales.Document."Sales Header"  →  Sales Header
--   Microsoft.Purchases.Document."Purch. Header"  →  Purch. Header  (the dot
--     is inside the quotes, so splitting on "." alone would be wrong)
--   Customer  →  Customer
local function last_segment(s)
  s = vim.trim(s):gsub("%s+temporary$", "")
  local quoted = s:match('"([^"]*)"$')
  if quoted then return quoted end
  return s:match("([^%.%s]+)$")
end

-- Parse the first code line of a hover into { kind, name }, or nil.
local function parse_hover(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("\r", "")
  local code = text:match("```al%s*\n([^\n]+)") or text:match("^%s*([^\n]+)")
  if not code then return nil end

  -- "(local) SH: Record "Sales Header"" — a variable, parameter or return value.
  if code:match("^%(") then
    local kind, rest = code:match(":%s*(%a+)%s+(.+)$")
    kind = kind and KINDS[kind:lower()]
    if not kind then return nil end   -- e.g. "(field) Name: Text[100]"
    return { kind = kind, name = last_segment(rest) }
  end

  -- "Table Microsoft.Sales.Document."Sales Header"" — the object itself.
  local kind, rest = code:match("^(%a+)%s+(.+)$")
  kind = kind and KINDS[kind:lower()]
  if not kind then return nil end
  return { kind = kind, name = last_segment(rest) }
end

-- The identifier under the cursor, quoted or bare. Returns
-- { name, s, e, qual } with 1-based columns; `qual` is the 1-based column of
-- the qualifier when the identifier is a member (`Var.Member`), else nil.
local function target_at_cursor(line, col0)
  local cur = col0 + 1
  local name, s, e

  -- Quoted identifiers, paired left to right with "" as an escaped quote (the
  -- same scan as refactor.lua — never pair by scanning left from the cursor).
  local i = 1
  while i <= #line and not name do
    if line:sub(i, i) == '"' then
      local j = i + 1
      while j <= #line do
        if line:sub(j, j) == '"' then
          if line:sub(j + 1, j + 1) == '"' then j = j + 2 else break end
        else
          j = j + 1
        end
      end
      if j > #line then break end
      if cur >= i and cur <= j and j > i + 1 then
        name, s, e = line:sub(i + 1, j - 1), i, j
      end
      i = j + 1
    else
      i = i + 1
    end
  end

  if not name then
    for ws, w, we in line:gmatch("()([%w_]+)()") do
      if cur >= ws and cur < we then name, s, e = w, ws, we - 1 break end
    end
  end
  if not name then return nil end

  -- Member access: the character before the identifier is a single "." (not
  -- "::", which is an object-kind reference like Page::"Customer List").
  local qual
  if s > 1 and line:sub(s - 1, s - 1) == "." and line:sub(s - 2, s - 2) ~= "." then
    local before = line:sub(1, s - 2)
    if before:sub(-1) == '"' then
      local qs = before:match('.*()"[^"]*"$')
      qual = qs and qs + 1
    else
      -- Not ".*()[%w_]+$": the greedy .* leaves one character for the word and
      -- returns the qualifier's *last* letter.
      qual = before:match("()[%w_]+$")
    end
  end
  return { name = name, s = s, e = e, qual = qual }
end

-- rg regex matching the declaration line of `obj` in an .al file: the name
-- either fully quoted or bare, then a boundary. Not `"?name"?` — with both
-- quotes optional, "Sales Header" also matched `table 5107 "Sales Header
-- Archive"` (prefix, then the space inside the longer name), and rg returning
-- files in no fixed order made gd land on whichever it listed first.
local function object_pattern(obj)
  local name = obj.name:gsub("([%^%$%.%|%?%*%+%(%)%[%]%{%}\\/-])", "\\%1")
  return ('^\\s*%s\\s+[0-9]+\\s+("%s"|%s)(\\s|\\{|$)'):format(obj.kind, name, name)
end

-- 1-based line of `member` declared in `lines` (field, procedure, enum value,
-- trigger), or nil. Case-insensitive, as AL is.
local function member_line(lines, member)
  local m = vim.pesc(member:lower())
  local pats = {
    '^%s*field%(%s*%d+%s*;%s*"?' .. m .. '"?%s*[;%)]',
    'procedure%s+"?' .. m .. '"?%s*%(',
    '^%s*value%(%s*%d+%s*;%s*"?' .. m .. '"?%s*%)',
    '^%s*trigger%s+' .. m .. '%s*%(',
  }
  for n, l in ipairs(lines) do
    local low = l:lower()
    for _, p in ipairs(pats) do
      if low:find(p) then return n end
    end
  end
  return nil
end

-- "local" / "global" / "parameter" … when the hover describes a variable
-- ("(local) Mgt: Codeunit "Sales-Post""), else nil.
local function hover_scope(text)
  if type(text) ~= "string" then return nil end
  return text:gsub("\r", ""):match("```al%s*\n%((%a+)%)")
end

-- 1-based line declaring variable or parameter `name`: nearest above `row`
-- first (innermost scope wins), then anywhere — AL objects usually keep their
-- global var section at the end. nil when not found.
local function declaration_line(lines, row, name)
  local n = vim.pesc(name:lower())
  -- Each must be followed by something other than "=": `G := 1` starts with
  -- the same `G :` as the declaration `G: Integer`.
  local pats = {
    '^%s*"?' .. n .. '"?%s*[:,]',               -- Mgt: Codeunit ...   /  a, b: Integer
    ',%s*"?' .. n .. '"?%s*[:,]',               -- a, Mgt: ...
    '[(;]%s*var%s+"?' .. n .. '"?%s*:',          -- procedure P(var Mgt: ...)
    '[(;]%s*"?' .. n .. '"?%s*:',                -- procedure P(Mgt: ...)
  }
  local function hit(l)
    l = l:lower()
    for _, p in ipairs(pats) do
      local _, e = l:find(p)
      if e and l:sub(e + 1, e + 1) ~= "=" then return true end
    end
  end
  for i = math.min(row, #lines), 1, -1 do
    if hit(lines[i]) then return i end
  end
  for i = row + 1, #lines do
    if hit(lines[i]) then return i end
  end
  return nil
end

-- Hover text at (row0, col0), passed to cb (nil when none).
local function hover_text(client, bufnr, row0, col0, cb)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position     = { line = row0, character = col0 },
  }
  client:request("textDocument/hover", params, function(err, res)
    if err or not res or not res.contents then return cb(nil) end
    local c = res.contents
    if type(c) == "table" and c.value then return cb(c.value) end
    if type(c) == "string" then return cb(c) end
    if vim.islist(c) then
      local parts = {}
      for _, p in ipairs(c) do parts[#parts + 1] = type(p) == "table" and p.value or p end
      return cb(table.concat(parts, "\n"))
    end
    cb(nil)
  end, bufnr)
end

-- Open `file` read-only at `lnum`, pushing the jumplist so <C-o> returns.
local function open_at(file, lnum)
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  -- These are extracted copies under the cache dir, not the user's source.
  vim.bo[buf].readonly   = true
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  vim.cmd("normal! ^zz")
end

-- Find obj's declaration across the project and extracted symbol sources.
-- cb(file, lnum) or cb(nil).
local function find_object(root, obj, cb)
  local explorer = require("al.explorer")
  -- The first search in a project unzips every symbol package's sources —
  -- seconds for Base Application, during which Neovim is busy. Say so first,
  -- rather than leave what looks like a hung keypress.
  if explorer.pending_extracts(root) > 0 then
    vim.notify("AL: extracting symbol package sources (first time only)…", vim.log.levels.INFO)
    vim.cmd.redraw()
  end
  local dirs = explorer.build_search_dirs(root)
  local cmd = { "rg", "-n", "-i", "-m", "1", "--no-heading", "--glob", "*.{al,AL}",
                "-e", object_pattern(obj) }
  vim.list_extend(cmd, dirs)
  explorer.rg_async(cmd, function(lines)
    for _, l in ipairs(lines) do
      local file, lnum = l:match("^(.-):(%d+):")
      if file then return cb(file, tonumber(lnum)) end
    end
    cb(nil)
  end, obj.kind .. " " .. obj.name)
end

local function fallback(client, bufnr)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local t = target_at_cursor(line, col)
  if not t then
    vim.notify("AL: no identifier under the cursor", vim.log.levels.INFO)
    return
  end

  -- For a member, hover the qualifier to learn which object it belongs to.
  local member = t.qual and t.name or nil
  local hcol   = (t.qual or (col + 1)) - 1   -- 0-based; t.qual is inside any quotes

  local root = require("al.lsp").get_root(bufnr)
  hover_text(client, bufnr, row - 1, hcol, function(text)
    -- A variable or parameter: go to where it is declared, as gd does in VS
    -- Code. (The server returns nothing for these.) gd on the type name in the
    -- declaration then goes on to the object.
    if hover_scope(text) and not member then
      local dl = declaration_line(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), row, t.name)
      if dl then
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { dl, 0 })
        vim.cmd("normal! ^")
        return
      end
    end
    local obj = parse_hover(text)
    if not obj then
      vim.notify("AL: no definition found for " .. t.name, vim.log.levels.INFO)
      return
    end
    if not root then
      vim.notify("AL: no project root — cannot search symbol sources", vim.log.levels.WARN)
      return
    end
    find_object(root, obj, function(file, lnum)
      if not file then
        vim.notify(("AL: %s \"%s\" has no source in its symbol package (NuGet symbol "
          .. "packages ship without .al files) — K shows its definition."):format(obj.kind, obj.name),
          vim.log.levels.INFO)
        return
      end
      if member then
        local ok, lines = pcall(vim.fn.readfile, file)
        local ml = ok and member_line(lines, member)
        if not ml then
          -- Built-in (Count, FindFirst…) or added by an extension: opening the
          -- object's first line would look like a wrong jump.
          vim.notify(("AL: %s is not declared in %s \"%s\" (built-in or from an extension)"
            .. " — K shows its definition."):format(member, obj.kind, obj.name), vim.log.levels.INFO)
          return
        end
        lnum = ml
      end
      open_at(file, lnum)
    end)
  end)
end

-- gd for the agentic LSP: the server's own answer when it has one, otherwise
-- the symbol-source fallback above.
function M.definition()
  local bufnr  = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ name = "al_agentic_lsp", bufnr = bufnr })[1]
  if not client then return vim.lsp.buf.definition() end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/definition", params, function(err, res)
    local loc = (not err and res) and (vim.islist(res) and res[1] or res) or nil
    if loc and (loc.uri or loc.targetUri) then
      vim.cmd("normal! m'")
      vim.lsp.util.show_document(loc, client.offset_encoding, { focus = true })
      return
    end
    fallback(client, bufnr)
  end, bufnr)
end

-- Internals reached by tests only — never call from plugin code.
M._test = {
  parse_hover = parse_hover, target_at_cursor = target_at_cursor,
  hover_scope = hover_scope, declaration_line = declaration_line,
  object_pattern = object_pattern, member_line = member_line, last_segment = last_segment,
}

return M
