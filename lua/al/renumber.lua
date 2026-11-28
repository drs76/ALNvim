-- :ALRenumberObjects — move the project's object IDs into app.json idRanges.
--
-- Default: objects already inside a range keep their ID; objects outside every
-- range (or a second object on an in-range ID already taken) get the next free
-- ID of their type, in old-ID order. With `all = true` (`:ALRenumberObjects!`)
-- every object of a type is renumbered from the start of the ranges, keeping
-- the old order.
--
-- Numeric references to a renumbered object are rewritten as well:
-- `Cust: Record 50100;`, `RunObject = page 50100;`, `Page.Run(50100, Rec)`.
-- The compiler rejects `Page::50100` (AL0104) and IDs in permission sets
-- (AL0653), so those forms are not looked for.
-- Single-quoted literals, // comments and quoted names are not touched.
-- Field IDs in table extensions and enum extension values are not changed.

local M = {}

local ns = require("al.namespace")

-- Reference keyword → the object type whose IDs it names.
local REF_TYPES = {
  record = "table", page = "page", testpage = "page", codeunit = "codeunit",
  report = "report", query = "query", xmlport = "xmlport", enum = "enum",
}
-- `Page.Run(50100)`, `Report.RunModal(50100, …)`: the ID is an argument.
local CALL_TYPES = { page = "page", report = "report", codeunit = "codeunit", xmlport = "xmlport" }

local function id_types() return require("al.ids").ID_TYPES end

-- Object headers in `lines`: { { lnum, type, id } }. A header starts in
-- column 1; an indented `table 50100 = X` is a permission entry, not a header.
local function parse_headers(lines)
  local out, types = {}, id_types()
  for i, line in ipairs(lines) do
    local typ, id = line:match("^(%a+)%s+(%d+)%f[^%d]")
    if typ and types[typ:lower()] then
      out[#out + 1] = { lnum = i, type = typ:lower(), id = tonumber(id) }
    end
  end
  return out
end

local function in_ranges(ranges, id)
  for _, r in ipairs(ranges) do
    if id >= r.from and id <= r.to then return true end
  end
  return false
end

-- Assign new IDs. `objects` = { { type, id, ... } }. Sets `obj.new` on every
-- object whose ID changes. Returns the count, or nil + reason when a type
-- runs out of IDs.
local function plan_ids(objects, ranges, all)
  local sorted_ranges = vim.deepcopy(ranges)
  table.sort(sorted_ranges, function(a, b) return a.from < b.from end)
  local by_type = {}
  for _, o in ipairs(objects) do
    by_type[o.type] = by_type[o.type] or {}
    table.insert(by_type[o.type], o)
  end
  local count = 0
  for typ, list in pairs(by_type) do
    table.sort(list, function(a, b)
      if a.id ~= b.id then return a.id < b.id end
      if (a.path or "") ~= (b.path or "") then return (a.path or "") < (b.path or "") end
      return a.lnum < b.lnum
    end)
    local taken, move = {}, {}
    for _, o in ipairs(list) do
      if not all and in_ranges(ranges, o.id) and not taken[o.id] then
        taken[o.id] = true
      else
        move[#move + 1] = o
      end
    end
    local r, next_id = 1, sorted_ranges[1] and sorted_ranges[1].from
    local function free()
      while sorted_ranges[r] do
        if next_id > sorted_ranges[r].to then
          r = r + 1
          next_id = sorted_ranges[r] and sorted_ranges[r].from
        elseif taken[next_id] then
          next_id = next_id + 1
        else
          local id = next_id
          next_id = next_id + 1
          return id
        end
      end
      return nil
    end
    for _, o in ipairs(move) do
      local id = free()
      if not id then
        return nil, ("not enough free IDs in idRanges for %d %s object(s)"):format(#move, typ)
      end
      taken[id] = true
      if id ~= o.id then
        o.new = id
        count = count + 1
      end
    end
  end
  return count
end

-- Reference map { [type] = { [old] = new } } from the planned objects. An old
-- ID shared by two objects of one type is left out: its references cannot be
-- told apart.
local function ref_map(objects)
  local seen, map = {}, {}
  for _, o in ipairs(objects) do
    local key = o.type .. ":" .. o.id
    seen[key] = (seen[key] or 0) + 1
  end
  for _, o in ipairs(objects) do
    if o.new and seen[o.type .. ":" .. o.id] == 1 then
      map[o.type] = map[o.type] or {}
      map[o.type][o.id] = o.new
    end
  end
  return map
end

local function mask_all(line)
  -- namespace.mask_code keeps "quoted names"; blank them too, so a name like
  -- "Page 50100 Setup" is never read as a reference.
  return (ns.mask_code(line):gsub('"[^"]*"', function(q) return string.rep(" ", #q) end))
end

-- Rewrite one file. `headers` = { [lnum] = new_id }, `refs` from ref_map.
-- Returns new lines (or nil when unchanged), header count, reference count.
local function rewrite_lines(lines, headers, refs)
  local out, nh, nr, changed = {}, 0, 0, false
  for i, line in ipairs(lines) do
    local res = line
    if headers[i] then
      local s, e = line:find("%d+", 1)
      res = line:sub(1, s - 1) .. headers[i] .. line:sub(e + 1)
      nh = nh + 1
    else
      local m = mask_all(line):lower()
      local spans = {}
      local function scan(pat, types)
        local pos = 1
        while true do
          local s, _, word, ds, digits = m:find(pat, pos)
          if not s then break end
          local typ = types[word]
          local new = typ and refs[typ] and refs[typ][tonumber(digits)]
          if new then spans[#spans + 1] = { ds, ds + #digits - 1, new } end
          pos = ds + #digits
        end
      end
      scan("%f[%a](%a+)%s+()(%d+)%f[^%d]", REF_TYPES)
      scan("%f[%a](%a+)%.run%a*%s*%(%s*()(%d+)%f[^%d]", CALL_TYPES)
      table.sort(spans, function(a, b) return a[1] > b[1] end)
      local last
      for _, sp in ipairs(spans) do
        if sp[1] ~= last then
          res = res:sub(1, sp[1] - 1) .. sp[3] .. res:sub(sp[2] + 1)
          nr = nr + 1
          last = sp[1]
        end
      end
    end
    if res ~= line then changed = true end
    out[i] = res
  end
  return changed and out or nil, nh, nr
end

-- Plan across the project. Returns plan or nil + reason.
-- plan = { files = { {path, lines, fmt} }, modified = {path}, moves = {obj},
--          headers = n, refs = n }
function M.plan(root, opts)
  opts = opts or {}
  local ranges = require("al.ids").get_ranges(root)
  if #ranges == 0 then return nil, "app.json has no idRanges" end
  local files = require("al.platform").glob_al_files(root)
  local objects, contents = {}, {}
  for _, path in ipairs(files) do
    local lines, fmt = ns.read_lines(path)
    if lines then
      contents[path] = { lines = lines, fmt = fmt }
      for _, h in ipairs(parse_headers(lines)) do
        h.path = path
        objects[#objects + 1] = h
      end
    end
  end
  local n, err = plan_ids(objects, ranges, opts.all)
  if not n then return nil, err end
  local plan = { files = {}, modified = {}, moves = {}, headers = 0, refs = 0 }
  if n == 0 then return plan end
  local refs = ref_map(objects)
  local headers_by_file = {}
  for _, o in ipairs(objects) do
    if o.new then
      plan.moves[#plan.moves + 1] = o
      headers_by_file[o.path] = headers_by_file[o.path] or {}
      headers_by_file[o.path][o.lnum] = o.new
    end
  end
  for _, path in ipairs(files) do
    local c = contents[path]
    if c then
      local out, nh, nr = rewrite_lines(c.lines, headers_by_file[path] or {}, refs)
      if out then
        local buf = ns.loaded_buf(path)
        if buf and vim.bo[buf].modified then
          plan.modified[#plan.modified + 1] = path
        else
          plan.files[#plan.files + 1] = { path = path, lines = out, fmt = c.fmt }
          plan.headers, plan.refs = plan.headers + nh, plan.refs + nr
        end
      end
    end
  end
  return plan
end

function M.apply(plan)
  local written = 0
  for _, f in ipairs(plan.files) do
    if ns.write_lines(f.path, f.lines, f.fmt) then
      written = written + 1
      local buf = ns.loaded_buf(f.path)
      if buf then vim.api.nvim_buf_call(buf, function() vim.cmd("silent! edit!") end) end
    end
  end
  require("al.ids").invalidate()
  return written
end

local function rel(p) return vim.fn.fnamemodify(p, ":~:.") end

-- :ALRenumberObjects[!]
function M.renumber(root, opts)
  opts = opts or {}
  root = root or require("al.lsp").get_root()
  if not root then
    vim.notify("AL: no project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end
  local plan, err = M.plan(root, opts)
  if not plan then
    vim.notify("AL: " .. err, vim.log.levels.ERROR)
    return
  end
  if #plan.modified > 0 then
    vim.notify("AL: save these first (unsaved changes):\n  "
      .. table.concat(vim.tbl_map(rel, plan.modified), "\n  "), vim.log.levels.WARN)
    return
  end
  if #plan.moves == 0 then
    vim.notify("AL: every object is already inside idRanges", vim.log.levels.INFO)
    return
  end
  local summary = ("%d object(s), %d reference(s) in %d file(s)")
    :format(plan.headers, plan.refs, #plan.files)
  vim.ui.select({ "Yes — renumber " .. summary, "Cancel" },
    { prompt = opts.all and "Renumber every object from the start of idRanges?"
                         or "Move objects outside idRanges into range?" },
    function(choice)
      if not choice or choice == "Cancel" then return end
      local w = M.apply(plan)
      local items = {}
      for _, o in ipairs(plan.moves) do
        items[#items + 1] = { filename = o.path, lnum = o.lnum, col = 1,
          text = ("%s %d → %d"):format(o.type, o.id, o.new) }
      end
      table.sort(items, function(a, b) return a.filename < b.filename end)
      require("al.host").locations({ id = "alnvim.renumber:" .. root,
        title = "AL: renumbered objects", items = items })
      vim.notify(("AL: renumbered %d object(s) in %d file(s). Republish replaces the old objects on the server.")
        :format(#plan.moves, w), vim.log.levels.INFO)
    end)
end

M._test = {
  parse_headers = parse_headers, plan_ids = plan_ids, ref_map = ref_map,
  rewrite_lines = rewrite_lines,
}

return M
