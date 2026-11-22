-- AL statusline state store.
-- Aggregates LSP loading state, project identity, and compile/publish results
-- into a single string, per project root, for display in the statusline
-- (ALNvim's window-local one, or a host's own via get()).
--
-- State is updated by:
--   plugin/al.lua  → set_lsp_*, set_project
--   compile.lua    → set_compiling, set_compile_result
--   publish.lua    → set_publishing, set_publish_result

local M = {}

-- One state per project root. With two AL projects open (two Catnip workspace
-- tabs) a single table showed whichever project attached last, in both.
--
-- Every setter takes an optional trailing `root`. A call without one goes to
-- the root updated most recently (`_cur`) — the old single-table behaviour,
-- which is still right for a session with one project.
local function new_state()
  return {
    lsp      = nil,   -- nil | "starting" | "loading" | "ready"
    pct      = nil,   -- number 0-100 while lsp == "loading"
    compile  = nil,   -- nil | "building" | { ok=bool, errors=N, warnings=N }
    publish  = nil,   -- nil | "publishing" | { ok=bool }
    project  = nil,   -- nil | { name=string, version=string }
    cops     = nil,   -- nil | token list e.g. {"${CodeCop}", ...}
    root     = nil,   -- project root path (for git HEAD lookup)
    branch   = nil,   -- cached branch name
    branch_t = 0,     -- vim.uv.now() when branch was last read
  }
end

local _states = {}   -- key: root, or "" before any root is known
local _cur    = ""   -- key of the state updated most recently

local function state(root)
  if root and root ~= "" then _cur = root end
  local k = (root and root ~= "") and root or _cur
  local st = _states[k]
  if not st then st = new_state(); st.root = (k ~= "") and k or nil; _states[k] = st end
  return st
end

-- Read the current git branch by parsing .git/HEAD directly (no subprocess).
-- Walks upward from root to find the git repo. Returns nil if not in a repo.
local function read_branch(root)
  if not root then return nil end
  local path = root
  for _ = 1, 8 do
    local f = io.open(path .. "/.git/HEAD", "r")
    if f then
      local line = f:read("*l")
      f:close()
      return line and (line:match("^ref: refs/heads/(.+)$") or line:sub(1, 7))
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end
    path = parent
  end
end

-- Return cached branch, refreshing if the cache is older than 2 seconds.
local function branch(st)
  local now = vim.uv.now()
  if now - st.branch_t > 2000 then
    st.branch   = read_branch(st.root)
    st.branch_t = now
  end
  return st.branch
end

-- Composed-string cache. M.get() is called from a %{} statusline expression, so
-- it runs on every redraw — every cursor move, every keystroke in some modes —
-- and it walks up to 8 directories looking for .git/HEAD and re-joins the cop
-- list each time. A short TTL collapses that to a few times a second while
-- staying visually immediate.
local _str = {}   -- per state key: { s = string, t = ms }
local STR_TTL_MS = 250

-- redrawstatus! forces a full statusline redraw. al/progressNotification
-- arrives many times a second while the server indexes, and firing one redraw
-- per notification was most of the cost of watching a project load. Coalesce
-- to at most one redraw per interval; _pending guards against stacking
-- schedules while one is already in flight.
local _pending, _last_draw = false, 0
local DRAW_MS = 100

local function redraw()
  _str = {}  -- state changed: drop the composed-string caches
  if _pending then return end
  _pending = true
  local wait = math.max(0, DRAW_MS - (vim.uv.now() - _last_draw))
  vim.defer_fn(function()
    _pending   = false
    _last_draw = vim.uv.now()
    vim.cmd("redrawstatus!")
  end, wait)
end

function M.set_project(name, ver, root)
  local st = state(root)
  st.project  = { name = name, version = ver }
  st.root     = root or st.root
  st.branch_t = 0   -- force refresh on next get()
  redraw()
end

function M.set_lsp_starting(root)
  local st = state(root)
  st.lsp, st.pct = "starting", nil
  redraw()
end

function M.set_lsp_loading(pct, root)
  local st = state(root)
  st.lsp, st.pct = "loading", pct
  redraw()
end

function M.set_lsp_ready(root)
  local st = state(root)
  st.lsp, st.pct = "ready", nil
  redraw()
end

function M.set_lsp_off(root)
  local st = state(root)
  st.lsp, st.pct = nil, nil
  redraw()
end

-- Without `root`: the root updated most recently.
function M.is_loading(root)
  local k = (root and root ~= "") and root or _cur
  return _states[k] ~= nil and _states[k].lsp == "loading"
end

function M.is_ready(root)
  local k = (root and root ~= "") and root or _cur
  return _states[k] ~= nil and _states[k].lsp == "ready"
end

function M.set_compiling(root)
  state(root).compile = "building"
  redraw()
end

function M.set_compile_result(errors, warnings, root)
  state(root).compile = { ok = (errors == 0 and warnings == 0), errors = errors, warnings = warnings }
  redraw()
end

function M.set_publishing(root)
  state(root).publish = "publishing"
  redraw()
end

function M.set_cops(tokens, root)
  state(root).cops = tokens
  redraw()
end

function M.set_publish_result(ok, root)
  local st = state(root)
  st.publish = { ok = ok }
  redraw()
  -- Clear the publish result after 5 seconds so it doesn't linger
  vim.defer_fn(function()
    if type(st.publish) == "table" then
      st.publish = nil
      redraw()
    end
  end, 5000)
end

-- The state the statusline shows: the current buffer's project when it has
-- one, else the root updated most recently. The buffer -> root lookup is a
-- bounded upward walk, cached per buffer and name (get() runs every redraw).
local _buf_root = {}
local function shown_key()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local c = _buf_root[buf]
  if not c or c.name ~= name then
    local root = name ~= "" and require("al.lsp").find_root_upward(name) or nil
    c = { name = name, root = root or false }
    _buf_root[buf] = c
  end
  if c.root and _states[c.root] then return c.root end
  return _cur
end

-- Returns a formatted string suitable for embedding in vim.wo.statusline via
-- %{v:lua.require('al.status').get()}
function M.get()
  local now = vim.uv.now()
  local key = shown_key()
  local cached = _str[key]
  if cached and (now - cached.t) < STR_TTL_MS then return cached.s end
  local _s = _states[key] or new_state()

  local parts = {}

  if _s.project then
    parts[#parts + 1] = _s.project.name .. " " .. _s.project.version
  end

  local br = _states[key] and branch(_s) or nil
  if br then parts[#parts + 1] = " " .. br end

  if _s.lsp == "starting" then
    parts[#parts + 1] = "starting…"
  elseif _s.lsp == "loading" then
    parts[#parts + 1] = _s.pct and string.format("loading %d%%", _s.pct) or "loading…"
  elseif _s.lsp == "ready" then
    parts[#parts + 1] = "ready"
  end

  if _s.compile == "building" then
    parts[#parts + 1] = "building…"
  elseif type(_s.compile) == "table" then
    if _s.compile.ok then
      parts[#parts + 1] = "✓"
    else
      local msg = "✗"
      if _s.compile.errors   > 0 then msg = msg .. " " .. _s.compile.errors   .. " err"  end
      if _s.compile.warnings > 0 then msg = msg .. " " .. _s.compile.warnings .. " warn" end
      parts[#parts + 1] = msg
    end
  end

  if _s.publish == "publishing" then
    parts[#parts + 1] = "publishing…"
  elseif type(_s.publish) == "table" then
    parts[#parts + 1] = _s.publish.ok and "published ✓" or "publish failed ✗"
  end

  if _s.cops then
    parts[#parts + 1] = require("al.cops").short_names(_s.cops)
  end

  local out = #parts > 0 and table.concat(parts, "  ") or ""
  _str[key] = { s = out, t = now }
  return out
end

-- Tests only — never call from plugin code.
M._test = { reset = function() _states, _cur, _str, _buf_root = {}, "", {}, {} end }

return M
