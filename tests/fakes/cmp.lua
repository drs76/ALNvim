-- Fake nvim-cmp: records register_source, setup.filetype, setup.buffer and
-- event handlers. get_config() returns M.sources_for_buffer as the sources.
-- Install: package.loaded["cmp"] = require("tests.fakes.cmp"); M._reset().
local M = { calls = {}, handlers = {}, sources_for_buffer = {} }

local function rec(fn, args) M.calls[#M.calls + 1] = { fn = fn, args = args } end

function M.register_source(name, src) rec("register_source", { name = name, source = src }) end

M.setup = {
  filetype = function(ft, conf) rec("setup.filetype", { ft = ft, conf = conf }) end,
  buffer   = function(conf) rec("setup.buffer", { conf = conf }) end,
}

M.config = { sources = function(list) return list end }

function M.get_config() return { sources = M.sources_for_buffer } end

function M.visible() return false end

M.event = { on = function(_, ev, fn) M.handlers[ev] = M.handlers[ev] or {}; table.insert(M.handlers[ev], fn) end }

function M._calls(fn)
  return vim.tbl_filter(function(c) return c.fn == fn end, M.calls)
end

function M._reset() M.calls, M.handlers, M.sources_for_buffer = {}, {}, {} end

return M
