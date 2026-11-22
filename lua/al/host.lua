-- Host adapter: the one module that knows which front end ALNvim runs inside.
--
-- ALNvim is a public plugin. One user runs it inside Catnip, a Neovim front end
-- with its own rules for windows (owned output floats, managed child tabs, a
-- linked location navigator — see docs/catnip-handover.md section 2). Everyone
-- else gets the plain Neovim behaviour ALNvim always had.
--
-- **No other module may require('catnip.*').** They ask this one for a sink,
-- a location list or an edit, and get the right thing for the host.
--
--   setup({ ui = "auto" })     "auto" | "catnip" | "native"
--
--   host.name()                          "catnip" | "native"; detected once, silently
--   host.output({ id, title, ... })      -> sink (below)
--   host.locations({ id, title, items, qf_title })
--   host.edit(file, line, col, { from = sink })
--
-- A sink is the one output object for the whole plugin:
--   sink.buf               the buffer (after the first open/append/clear)
--   sink:append(lines)     append; natively also follows the tail
--   sink:clear()           empty the buffer
--   sink:open({ focus })   show it (Catnip: owned float; native: float or split)
--   sink:close()           hide the window, keep the buffer and whatever feeds it
--   sink:close_later(ms)   close after ms if still open
--   sink:on_enter(fn)      buffer-local <CR> -> fn(current line)
--   sink:map(lhs, fn, desc) / sink:unmap(lhs)   buffer-local normal-mode maps
--   sink:is_open()

local M = {}
local api = vim.api

local _name -- cached detection: "catnip" | "native"

local function config_ui()
  local al = package.loaded["al"]
  local v = al and al.config and al.config.ui
  return v or "auto"
end

-- The Catnip UI module, or nil. pcall(require) leaves nothing behind on
-- failure and says nothing: an ALNvim user without Catnip must never hear
-- about it.
local function catnip_ui()
  local ok, ui = pcall(require, "catnip.ui")
  if ok and type(ui) == "table" and type(ui.output) == "function" then return ui end
end

local function catnip_navigator()
  local ok, nav = pcall(require, "catnip.navigator")
  if ok and type(nav) == "table" and type(nav.navigator) == "function" then return nav end
end

function M.name()
  if _name then return _name end
  local mode = config_ui()
  if mode ~= "native" and catnip_ui() then _name = "catnip" else _name = "native" end
  return _name
end

-- Called from require("al").setup(). Re-detects on the next name(), and warns
-- once — here, not per command — when Catnip was asked for and is not there.
function M.setup(mode)
  _name = nil
  if mode == "catnip" and not catnip_ui() then
    vim.notify('AL: setup({ ui = "catnip" }) but Catnip is not loaded; using the native UI',
      vim.log.levels.WARN)
  end
end

-- ── Edit windows (native) ────────────────────────────────────────────────────

-- Sidebar/plugin filetypes that are never edit targets.
local SIDEBAR_FT = {
  NvimTree = true, ["neo-tree"] = true, aerial = true,
  Outline = true, undotree = true, oil = true, qf = true,
  alpha = true, dashboard = true,
}

-- True if w is a real editing window (not a sidebar, terminal, quickfix, …).
local function is_edit_win(w)
  if not (w and api.nvim_win_is_valid(w)) then return false end
  local buf = api.nvim_win_get_buf(w)
  local bt  = vim.bo[buf].buftype
  if bt ~= "" and bt ~= "acwrite" then return false end
  return not SIDEBAR_FT[vim.bo[buf].filetype]
end

-- The first non-floating editing window in the current tab, excluding `exclude`.
local function find_edit_win(exclude)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if w ~= exclude and api.nvim_win_get_config(w).relative == "" and is_edit_win(w) then
      return w
    end
  end
end

-- Native target for a jump out of a sink: the window the sink was opened from
-- when it is still an edit window, else any edit window, else any non-floating
-- window that is not the sink's (e.g. a dashboard — reused rather than split),
-- else a new split above the sink. The choice is remembered on the sink so the
-- next jump reuses it.
local function native_target(sink)
  local own = sink and sink.win
  local target = sink and is_edit_win(sink.origin_win) and sink.origin_win or find_edit_win(own)
  if not target then
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if w ~= own and api.nvim_win_get_config(w).relative == "" then target = w; break end
    end
  end
  if not target then
    if own and api.nvim_win_is_valid(own) then
      api.nvim_win_call(own, function() vim.cmd("aboveleft split") end)
    else
      vim.cmd("aboveleft split")
    end
    target = api.nvim_get_current_win()
  end
  if sink then sink.origin_win = target end
  return target
end

-- Open file at line/col. Under Catnip with a `from` sink: a managed child tab
-- (the view reopens when that tab closes). Otherwise the best edit window.
function M.edit(file, line, col, opts)
  local from = opts and opts.from
  if from and from.view and M.name() == "catnip" then
    return from.view:edit_file({ file = file, line = line, col = col })
  end
  local target = native_target(from)
  api.nvim_win_call(target, function()
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file))
    if not ok then
      vim.notify("AL: cannot open " .. file .. "\n" .. tostring(err), vim.log.levels.ERROR)
      return
    end
    pcall(api.nvim_win_set_cursor, 0, { tonumber(line) or 1, math.max(0, (tonumber(col) or 1) - 1) })
    vim.cmd("normal! zz")
  end)
  api.nvim_set_current_win(target)
  return true
end

-- ── Sinks ────────────────────────────────────────────────────────────────────

local Sink = {}
Sink.__index = Sink

local function set_buf_maps(sink)
  local buf = sink.buf
  if not (buf and api.nvim_buf_is_valid(buf)) or sink._mapped == buf then return end
  sink._mapped = buf
  for lhs, m in pairs(sink._maps) do
    vim.keymap.set("n", lhs, m.fn, { buffer = buf, nowait = true, silent = true, desc = m.desc })
  end
end

function Sink:map(lhs, fn, desc)
  self._maps[lhs] = { fn = fn, desc = desc }
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true, desc = desc })
  end
  return self
end

function Sink:unmap(lhs)
  if not self._maps[lhs] then return self end
  self._maps[lhs] = nil
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    pcall(vim.keymap.del, "n", lhs, { buffer = self.buf })
  end
  return self
end

function Sink:on_enter(fn)
  return self:map("<CR>", function() fn(api.nvim_get_current_line()) end, "Open the location on this line")
end

function Sink:close_later(ms)
  vim.defer_fn(function() if self:is_open() then self:close() end end, ms)
  return self
end

-- Catnip: a catnip.ui view, created on the first open.

local CatnipSink = setmetatable({}, { __index = Sink })
CatnipSink.__index = CatnipSink

-- The view, created without opening a window: ui.output always opens, so
-- before the first open() an existing view is reused through ui.get and
-- otherwise the lines wait in _pending.
function CatnipSink:_view()
  if self.view then return self.view end
  local v = self.ui.get and self.ui.get(self.id)
  if v then self.view = v; self.buf = v.buf end
  return self.view
end

function CatnipSink:open(opts)
  local focus = not (opts and opts.focus == false)
  local cur = self.ui.get and self.ui.get(self.id)
  -- D1: View:open focuses an already-open view, and when that view sits in
  -- another tabpage, focusing it switches the user's tab. Close it there first;
  -- close() does not move focus when the view is not focused.
  if cur and cur.is_open and cur:is_open() and cur.win
     and api.nvim_win_get_tabpage(cur.win) ~= api.nvim_get_current_tabpage() then
    cur:close()
  end
  self.view = self.ui.output({ id = self.id, title = self.title, focus = focus })
  self.buf = self.view.buf
  if self._pending then
    local p = self._pending
    self._pending = nil
    if p.clear then self.view:set_lines({}) end
    if #p.lines > 0 then self.view:append(p.lines) end
  end
  set_buf_maps(self)
  return self
end

function CatnipSink:append(lines)
  if #lines == 0 then return self end
  local v = self:_view()
  if v then v:append(lines) else
    self._pending = self._pending or { lines = {} }
    vim.list_extend(self._pending.lines, lines)
  end
  return self
end

function CatnipSink:clear()
  local v = self:_view()
  if v then v:set_lines({}) else self._pending = { clear = true, lines = {} } end
  return self
end

function CatnipSink:close()
  local v = self:_view()
  if v then v:close() end
  return self
end

function CatnipSink:is_open()
  local v = self:_view()
  return v ~= nil and v:is_open()
end

-- Native: a scratch buffer kept for the session (bufhidden=hide), shown in a
-- centred float or — for the build output — a full-width bottom split.

local NativeSink = setmetatable({}, { __index = Sink })
NativeSink.__index = NativeSink

-- Split sinks open per tab one at a time: a second build panel in the same tab
-- replaces the first, as the single build panel always did.
local split_wins = {}

function NativeSink:_ensure_buf()
  if self.buf and api.nvim_buf_is_valid(self.buf) then return self.buf end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile  = false
  self.buf = buf
  self._mapped = nil
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function() self:close() end, { buffer = buf, nowait = true, silent = true })
  end
  return buf
end

function NativeSink:is_open()
  return self.win ~= nil and api.nvim_win_is_valid(self.win)
     and api.nvim_win_get_buf(self.win) == self.buf
end

function NativeSink:_open_split()
  -- Close any build panel in this tab (this sink's or another root's) first.
  local tab = api.nvim_get_current_tabpage()
  for w in pairs(split_wins) do
    if not api.nvim_win_is_valid(w) then split_wins[w] = nil
    elseif api.nvim_win_get_tabpage(w) == tab then
      split_wins[w] = nil
      api.nvim_win_close(w, true)
    end
  end
  local cur = api.nvim_get_current_win()
  self.origin_win = is_edit_win(cur) and cur or find_edit_win(nil)
  local height = math.max(15, math.floor(vim.o.lines * 0.30))
  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, self.buf)
  api.nvim_win_set_height(win, height)
  vim.wo[win].wrap         = false
  vim.wo[win].cursorline   = true
  vim.wo[win].number       = false
  vim.wo[win].signcolumn   = "no"
  vim.wo[win].winfixheight = true
  vim.wo[win].winbar       = "  " .. self.title .. (self.hint and ("  (" .. self.hint .. ")") or "")
  split_wins[win] = true
  return win
end

function NativeSink:_open_float(focus)
  local cur = api.nvim_get_current_win()
  self.origin_win = is_edit_win(cur) and cur or find_edit_win(nil)
  local w = math.min(100, math.max(60, vim.o.columns - 8))
  local h = math.min(18, math.max(8, math.floor(vim.o.lines * 0.4)))
  local win = api.nvim_open_win(self.buf, focus, {
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    style = "minimal", border = "rounded",
    title = " " .. self.title .. " ", title_pos = "center",
  })
  vim.wo[win].wrap = true
  return win
end

function NativeSink:open(opts)
  local focus = not (opts and opts.focus == false)
  self:_ensure_buf()
  if self.native == "split" then
    -- The split is the old build panel: always reopened, always focused.
    self.win = self:_open_split()
  elseif self:is_open() and api.nvim_win_get_tabpage(self.win) == api.nvim_get_current_tabpage() then
    if focus then api.nvim_set_current_win(self.win) end
  else
    -- Open in another tab: move it here rather than focus it there (focusing
    -- a window in another tabpage switches the user's tab).
    if self:is_open() then self:close() end
    self.win = self:_open_float(focus)
  end
  set_buf_maps(self)
  return self
end

function NativeSink:append(lines)
  if #lines == 0 then return self end
  local buf = self:_ensure_buf()
  local empty = api.nvim_buf_line_count(buf) == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
  local last = api.nvim_buf_line_count(buf)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(api.nvim_win_set_cursor, w, { last, 0 })
  end
  return self
end

function NativeSink:clear()
  api.nvim_buf_set_lines(self:_ensure_buf(), 0, -1, false, {})
  return self
end

function NativeSink:close()
  if self:is_open() then
    split_wins[self.win] = nil
    -- The last window of a tab cannot be closed; leave it then.
    pcall(api.nvim_win_close, self.win, true)
  end
  self.win = nil
  return self
end

-- opts: id (required, one sink per id), title, hint (native split winbar),
-- native = "float" (default) | "split".
local sinks = {}

function M.output(opts)
  assert(type(opts) == "table" and type(opts.id) == "string" and opts.id ~= "",
    "al.host.output: id required")
  local host = M.name()
  local s = sinks[opts.id]
  if s and s.host ~= host then s = nil end
  if not s then
    if host == "catnip" then
      s = setmetatable({ host = "catnip", ui = catnip_ui(), id = opts.id, _maps = {} }, CatnipSink)
    else
      s = setmetatable({ host = "native", id = opts.id, _maps = {} }, NativeSink)
    end
    sinks[opts.id] = s
  end
  s.title  = opts.title or s.title or opts.id
  s.hint   = opts.hint or s.hint
  s.native = opts.native or s.native or "float"
  return s
end

-- ── Locations ────────────────────────────────────────────────────────────────

-- A window for a buffer the caller owns (an agent terminal): under Catnip a
-- centred float sized like an output view; natively nil, and the caller keeps
-- its own split. Returns the window or nil.
function M.float_for(buf, title)
  if M.name() ~= "catnip" then return nil end
  local w = math.min(vim.o.columns - 2, math.max(1, math.floor(vim.o.columns * 0.75)))
  local h = math.min(vim.o.lines - vim.o.cmdheight - 3, math.max(1, math.floor(vim.o.lines * 0.55)))
  return api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    title = " " .. (title or "") .. " ", title_pos = "center",
    width = w, height = h,
    row = math.max(0, math.floor((vim.o.lines - h - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    zindex = 45,
  })
end

-- Quickfix entries -> navigator items. Project-level entries (no file) cannot
-- be navigated to and are counted instead.
function M.to_items(qf)
  local items, project_level = {}, 0
  for _, d in ipairs(qf or {}) do
    if type(d.filename) == "string" and d.filename ~= "" then
      items[#items + 1] = {
        file     = d.filename,
        line     = math.max(1, tonumber(d.lnum) or 1),
        col      = math.max(1, tonumber(d.col) or 1),
        severity = d.type == "E" and "E" or d.type == "W" and "W" or "I",
        message  = d.text or "",
      }
    else
      project_level = project_level + 1
    end
  end
  return items, project_level
end

-- Fill quickfix with `items` (quickfix entries — users expect :cnext), then
-- show them: Catnip's linked navigator, or :copen. Returns true when shown.
-- opts.action is setqflist's action ("r" replaces the current list, " " adds
-- a new one); default "r".
function M.locations(opts)
  local qf = opts.items or {}
  vim.fn.setqflist({}, opts.action or "r", { title = opts.qf_title or opts.title, items = qf })
  local nav = M.name() == "catnip" and catnip_navigator()
  if not nav then
    vim.cmd("copen")
    return true
  end
  local items, project_level = M.to_items(qf)
  if #items == 0 then
    vim.notify(project_level > 0
      and "AL: only project-level diagnostics; see :copen or the build output"
      or "AL: no file diagnostics", vim.log.levels.INFO)
    return false
  end
  if project_level > 0 then
    vim.notify(("AL: %d project-level diagnostic(s) remain in quickfix"):format(project_level),
      vim.log.levels.INFO)
  end
  nav.navigator({ id = opts.id, title = opts.title, items = items })
  return true
end

-- Tests only — never call from plugin code.
M._test = {
  reset = function() _name = nil; sinks = {}; split_wins = {} end,
  sinks = function() return sinks end,
}

return M
