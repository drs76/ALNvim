-- nvim-cmp source "al_ids": free object IDs in the normal completion menu.
--
-- Offered only on an object header ("table ", "codeunit 501"), with IDs from
-- app.json idRanges minus the ones the project already uses. The used-ID scan
-- runs through explorer.rg_async (ids.used_ids_async), never on the main
-- thread — the completefunc path (<C-x><C-u>) stays for users without cmp.
--
-- register() is idempotent; setup() and the ftplugin both call it, because cmp
-- may load after require("al").setup().

local M = {}

local source = {}
source.__index = source

function M.new() return setmetatable({}, source) end

function source:get_debug_name() return "al_ids" end

function source:is_available() return vim.bo.filetype == "al" end

function source:get_trigger_characters() return { " " } end

-- The ID is the word being completed.
function source:get_keyword_pattern() return [[\d*]] end

function source:complete(params, callback)
  local ids = require("al.ids")
  local before = params.context.cursor_before_line
  local typ, digits = ids.header_context(before)
  if not typ then return callback({ items = {}, isIncomplete = false }) end
  -- The bounded upward walk only: get_root() may prompt, and a completion
  -- source must never stop for input.
  local root = require("al.lsp").find_root_upward(vim.api.nvim_buf_get_name(params.context.bufnr))
  if not root then return callback({ items = {}, isIncomplete = false }) end
  local ranges = ids.get_ranges(root)
  if #ranges == 0 then return callback({ items = {}, isIncomplete = false }) end
  ids.used_ids_async(root, typ, function(used)
    local items = {}
    for i, m in ipairs(ids.free_ids(ranges, used, 5, digits)) do
      items[#items + 1] = {
        label         = tostring(m.id),
        kind          = 12,              -- CompletionItemKind.Value
        detail        = m.menu,
        documentation = m.info,
        sortText      = string.format("%04d", i),
      }
    end
    callback({ items = items, isIncomplete = false })
  end)
end

local _registered = false

-- Register with nvim-cmp when it is installed. Returns true when registered.
function M.register()
  if _registered then return true end
  local ok, cmp = pcall(require, "cmp")
  if not ok or type(cmp.register_source) ~= "function" then return false end
  cmp.register_source("al_ids", M.new())
  _registered = true
  return true
end

-- True when the current buffer's cmp config lists al_ids. The ftplugin keeps
-- its <C-Space> completefunc map otherwise: a host whose own
-- cmp.setup.filetype("al") runs after ours (Catnip does) has no al_ids, and
-- dropping the map would leave no way to complete an ID.
function M.in_sources()
  local ok, cmp = pcall(require, "cmp")
  if not ok or type(cmp.get_config) ~= "function" then return false end
  local okc, conf = pcall(cmp.get_config)
  for _, s in ipairs(okc and conf and conf.sources or {}) do
    if s.name == "al_ids" then return true end
  end
  return false
end

-- Tests only.
M._test = { reset = function() _registered = false end }

return M
