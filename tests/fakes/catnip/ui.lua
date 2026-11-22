-- Fake catnip.ui for the test suite (tests/run.sh runs -u NONE, so the real
-- one is not there). Implements the surface of docs/catnip-handover.md
-- section 2 with real floating windows, and records every call in M.calls.
--
-- It copies the real View:open on purpose, including the behaviour behind D1:
-- opening a view that is already open in another tabpage focuses it there,
-- which switches the user's tab. ALNvim must guard against that itself.
--
-- One instance per session, like the real module: install with
--   package.loaded["catnip.ui"] = require("tests.fakes.catnip.ui")
-- and call M._reset() between tests.
local M = { calls = {} }
local api = vim.api
local views = {}

local function record(name, id, args)
  M.calls[#M.calls + 1] = { fn = name, id = id, args = vim.deepcopy(args) }
end

local View = {}
View.__index = View

local function ensure_buf(v)
  if v.buf and api.nvim_buf_is_valid(v.buf) then return v.buf end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  v.buf = buf
  vim.keymap.set("n", "q", function() v:close() end, { buffer = buf })
  return buf
end

local function write(v, s, e, lines)
  local buf = ensure_buf(v)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, s, e, false, lines)
  vim.bo[buf].modifiable = false
end

function View:is_open()
  return self.win ~= nil and api.nvim_win_is_valid(self.win) and api.nvim_win_get_buf(self.win) == self.buf
end

function View:open(opts)
  record("open", self.id, opts or {})
  local focus = not (opts and opts.focus == false)
  local buf = ensure_buf(self)
  if self:is_open() then
    if focus then api.nvim_set_current_win(self.win) end -- the D1 tab switch
    return self
  end
  self.previous_win = api.nvim_get_current_win()
  self.win = api.nvim_open_win(buf, focus, {
    relative = "editor", width = 40, height = 10, row = 1, col = 1, style = "minimal",
  })
  return self
end

function View:close()
  record("close", self.id, {})
  if self:is_open() then api.nvim_win_close(self.win, true) end
  self.win = nil
  return self
end

function View:set_lines(lines)
  record("set_lines", self.id, { lines = lines })
  write(self, 0, -1, lines)
  return self
end

function View:append(lines)
  record("append", self.id, { lines = lines })
  if #lines > 0 then write(self, -1, -1, lines) end
  return self
end

function View:lines()
  if not (self.buf and api.nvim_buf_is_valid(self.buf)) then return {} end
  return api.nvim_buf_get_lines(self.buf, 0, -1, false)
end

function View:edit_file(opts)
  record("edit_file", self.id, opts)
  return true
end

function View:dispose()
  record("dispose", self.id, {})
  self:close()
  if self.buf and api.nvim_buf_is_valid(self.buf) then api.nvim_buf_delete(self.buf, { force = true }) end
  views[self.id] = nil
end

function M.output(opts)
  record("output", opts.id, opts)
  local v = views[opts.id]
  if not v then
    v = setmetatable({ id = opts.id, title = opts.title or opts.id }, View)
    views[opts.id] = v
  end
  if opts.title then v.title = opts.title end
  if opts.lines ~= nil then v:set_lines(opts.lines) end
  return v:open({ focus = opts.focus })
end

function M.get(id)
  return views[id]
end

-- Test helpers.
function M._reset()
  for _, v in pairs(views) do
    if v:is_open() then pcall(api.nvim_win_close, v.win, true) end
    if v.buf and api.nvim_buf_is_valid(v.buf) then pcall(api.nvim_buf_delete, v.buf, { force = true }) end
  end
  views = {}
  M.calls = {}
end

-- Every recorded call of `fn` (optionally for one id).
function M._calls(fn, id)
  return vim.tbl_filter(function(c) return c.fn == fn and (id == nil or c.id == id) end, M.calls)
end

return M
