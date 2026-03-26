local M = {}

-- Resolve the plugin's own root directory at require-time.
-- debug.getinfo(1,"S").source is  "@/path/to/plugin/lua/al/snippets.lua"
-- We strip two levels ("al/", "lua/") to reach the plugin root.
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)  -- remove leading "@"
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local PLUGIN_ROOT = plugin_root()

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

return M
