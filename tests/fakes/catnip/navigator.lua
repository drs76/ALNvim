-- Fake catnip.navigator: records every navigator() call. See ui.lua beside it.
local M = { calls = {} }
local views = {}

function M.navigator(opts)
  M.calls[#M.calls + 1] = vim.deepcopy(opts)
  local v = views[opts.id] or { id = opts.id }
  v.title, v.items = opts.title, opts.items
  views[opts.id] = v
  return v
end

function M.get(id) return views[id] end

function M._reset() views = {}; M.calls = {} end

return M
