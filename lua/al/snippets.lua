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
  vim.fn.mkdir(vim.fn.fnamemodify(USER_SNIPPET_FILE, ":h"), "p")
  vim.fn.writefile({ vim.fn.json_encode(data) }, USER_SNIPPET_FILE)
end

function M.load()
  local ok, luasnip = pcall(require, "luasnip")
  if not ok then
    vim.notify("ALNvim: LuaSnip not available – snippets not loaded", vim.log.levels.WARN)
    return
  end
  require("luasnip.loaders.from_vscode").load({ paths = { PLUGIN_ROOT } })
end

function M.reload()
  local ok, luasnip = pcall(require, "luasnip")
  if not ok then
    vim.notify("ALNvim: LuaSnip not available", vim.log.levels.WARN)
    return
  end
  -- Remove existing AL snippets before reloading to avoid duplicates
  luasnip.cleanup()
  require("luasnip.loaders.from_vscode").load({ paths = { PLUGIN_ROOT } })
  -- Reload any other paths the user had registered
  require("luasnip.loaders.from_vscode").lazy_load()
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

return M
