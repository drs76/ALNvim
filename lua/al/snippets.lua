local M = {}

-- Resolve the plugin's own root directory at require-time.
-- debug.getinfo(1,"S").source is  "@/path/to/plugin/lua/al/snippets.lua"
-- We strip two levels ("al/", "lua/") to reach the plugin root.
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)  -- remove leading "@"
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local PLUGIN_ROOT = plugin_root()
local USER_SNIPPET_FILE = PLUGIN_ROOT .. "/snippets/al-user.json"

local function suggest_prefix(lines)
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local word = line:match("%a[%w_]*")
      if word then return word:lower():sub(1, 20) end
    end
  end
  return "mysnippet"
end

local function strip_common_indent(lines)
  local min_ind = math.huge
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local sp = #(line:match("^(%s*)"))
      if sp < min_ind then min_ind = sp end
    end
  end
  if min_ind == math.huge then min_ind = 0 end
  local out = {}
  for _, line in ipairs(lines) do
    out[#out + 1] = #line >= min_ind and line:sub(min_ind + 1) or vim.trim(line)
  end
  return out
end

local function apply_tabstops(lines, words_str)
  if not words_str or vim.trim(words_str) == "" then return lines end
  local words = {}
  for w in words_str:gmatch("[^,]+") do
    local t = vim.trim(w)
    if t ~= "" then words[#words + 1] = t end
  end
  if #words == 0 then return lines end
  local plan = {}
  for i, w in ipairs(words) do plan[w] = { n = i, first_done = false } end
  local result = {}
  for _, line in ipairs(lines) do
    local new_line = line
    for _, w in ipairs(words) do
      local info = plan[w]
      local pat = "%f[%w_]" .. vim.pesc(w) .. "%f[^%w_]"
      new_line = new_line:gsub(pat, function()
        if not info.first_done then
          info.first_done = true
          return "${" .. info.n .. ":" .. w .. "}"
        else
          return "$" .. info.n
        end
      end)
    end
    result[#result + 1] = new_line
  end
  return result
end

local function read_user_snippets()
  local ok, raw = pcall(vim.fn.readfile, USER_SNIPPET_FILE)
  if not ok or not raw or #raw == 0 then return {} end
  local ok2, data = pcall(vim.fn.json_decode, table.concat(raw, "\n"))
  if not ok2 or type(data) ~= "table" then return {} end
  return data
end

local function write_user_snippets(data)
  -- Indented: this file is committed and hand-editable.
  local ok, err = require("al.json").write(USER_SNIPPET_FILE, data)
  if not ok then error(err) end
end

-- ── Loading ────────────────────────────────────────────────────────────────

local function read_snippet_file(path)
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then return {} end
  local data = require("al.json").decode_jsonc(table.concat(raw, "\n"))
  return type(data) == "table" and data or {}
end

-- The extension's AL snippet files, from its package.json
-- contributes.snippets (language "al" only — it also ships json/xml ones).
local function ext_snippet_files(ext_path)
  if not ext_path or ext_path == "" then return {} end
  local pkg = read_snippet_file(ext_path .. "/package.json")
  local list = type(pkg.contributes) == "table" and pkg.contributes.snippets or nil
  local out = {}
  for _, s in ipairs(type(list) == "table" and list or {}) do
    if type(s) == "table" and s.language == "al" and type(s.path) == "string" then
      out[#out + 1] = vim.fs.normalize(ext_path .. "/" .. s.path:gsub("^%./", ""))
    end
  end
  return out
end

-- Merge VS Code snippet tables, lowest precedence first, keyed by prefix: a
-- later source's snippet replaces an earlier one with the same trigger. One
-- entry per prefix (a snippet with a prefix list contributes each).
-- Returns { [prefix] = { name, prefix, body (string), description } }.
local function merge(sources)
  local out = {}
  for _, src in ipairs(sources) do
    for name, sn in pairs(src) do
      if type(sn) == "table" and sn.prefix and sn.body then
        local body = type(sn.body) == "table" and table.concat(sn.body, "\n") or tostring(sn.body)
        local prefixes = type(sn.prefix) == "table" and sn.prefix or { sn.prefix }
        for _, pfx in ipairs(prefixes) do
          if type(pfx) == "string" and pfx ~= "" then
            out[pfx] = {
              name = name, prefix = pfx, body = body,
              description = type(sn.description) == "string" and sn.description or nil,
            }
          end
        end
      end
    end
  end
  return out
end

-- Extension snippets < snippets/al.json < snippets/al-user.json.
-- ext_path defaults to the detected extension; false means none.
local function collect(ext_path)
  if ext_path == nil then
    local ok, ext = pcall(require, "al.ext")
    ext_path = ok and ext.path or nil
  end
  local sources = {}
  for _, f in ipairs(ext_snippet_files(ext_path or nil)) do
    sources[#sources + 1] = read_snippet_file(f)
  end
  sources[#sources + 1] = read_snippet_file(PLUGIN_ROOT .. "/snippets/al.json")
  sources[#sources + 1] = read_snippet_file(USER_SNIPPET_FILE)
  return merge(sources)
end

-- Register the merged set with LuaSnip under one key. add_snippets with the
-- same key replaces the previous set, so reload() is a re-run that touches no
-- other filetype's or plugin's snippets.
local function register(ls, merged)
  local list = {}
  local prefixes = vim.tbl_keys(merged)
  table.sort(prefixes)
  for _, pfx in ipairs(prefixes) do
    local sn = merged[pfx]
    local ok, parsed = pcall(ls.parser.parse_snippet,
      { trig = pfx, name = sn.name, dscr = sn.description }, sn.body)
    if ok and parsed then list[#list + 1] = parsed end
  end
  ls.add_snippets("al", list, { key = "alnvim" })
  return #list
end

function M.load()
  local ok, luasnip = pcall(require, "luasnip")
  if not ok then
    vim.notify("ALNvim: LuaSnip not available – snippets not loaded", vim.log.levels.WARN)
    return
  end
  return register(luasnip, collect())
end

function M.reload()
  local ok, luasnip = pcall(require, "luasnip")
  if not ok then
    vim.notify("ALNvim: LuaSnip not available", vim.log.levels.WARN)
    return
  end
  register(luasnip, collect())
  vim.notify("ALNvim: Snippets reloaded", vim.log.levels.INFO)
end

function M.create_from_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local sel_start = vim.api.nvim_buf_get_mark(bufnr, "<")[1]
  local sel_end   = vim.api.nvim_buf_get_mark(bufnr, ">")[1]
  if sel_start == 0 then
    vim.notify("ALNvim: select lines first (visual mode), then run :ALCreateSnippet",
      vim.log.levels.WARN)
    return
  end
  if sel_start > sel_end then sel_start, sel_end = sel_end, sel_start end
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sel_lines = vim.list_slice(all_lines, sel_start, sel_end)
  if #sel_lines == 0 then
    vim.notify("ALNvim: selection is empty", vim.log.levels.WARN)
    return
  end

  local suggested_prefix = suggest_prefix(sel_lines)

  vim.ui.input({ prompt = "Snippet name: ", default = "My AL Snippet" }, function(name)
    if not name or vim.trim(name) == "" then return end
    name = vim.trim(name)

    vim.ui.input({ prompt = "Prefix/trigger: ", default = suggested_prefix }, function(prefix)
      if not prefix or vim.trim(prefix) == "" then return end
      prefix = vim.trim(prefix)

      vim.ui.input({ prompt = "Description (optional): " }, function(desc)
        if desc == nil then return end
        desc = vim.trim(desc)

        vim.ui.input({ prompt = "Tabstop words (comma-separated, optional): " }, function(tabstop_str)
          if tabstop_str == nil then return end

          vim.schedule(function()
            local body = strip_common_indent(sel_lines)
            for i, line in ipairs(body) do
              body[i] = line:gsub("%$", "\\$")
            end
            body = apply_tabstops(body, tabstop_str)
            body[#body + 1] = "$0"

            local snippets = read_user_snippets()
            local entry = { prefix = prefix, body = body }
            if desc ~= "" then entry.description = desc end
            snippets[name] = entry

            local ok, err = pcall(write_user_snippets, snippets)
            if not ok then
              vim.notify("ALNvim: failed to write snippet: " .. tostring(err),
                vim.log.levels.ERROR)
              return
            end

            M.reload()
            vim.notify(
              string.format('ALNvim: snippet "%s" (prefix: %s) saved', name, prefix),
              vim.log.levels.INFO)
          end)
        end)
      end)
    end)
  end)
end

-- Internals reached by tests/snippets_spec.lua only.
M._test = {
  merge             = merge,
  collect           = collect,
  register          = register,
  ext_snippet_files = ext_snippet_files,
}

return M
