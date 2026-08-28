-- AL statusline state store.
-- Aggregates LSP loading state, project identity, and compile/publish results
-- into a single string for display via vim.wo.statusline in AL windows.
--
-- State is updated by:
--   plugin/al.lua  → set_lsp_*, set_project
--   compile.lua    → set_compiling, set_compile_result
--   publish.lua    → set_publishing, set_publish_result

local M = {}

local _s = {
  lsp      = nil,   -- nil | "starting" | "loading" | "ready"
  pct      = nil,   -- number 0-100 while lsp == "loading"
  compile  = nil,   -- nil | "building" | { ok=bool, errors=N, warnings=N }
  publish  = nil,   -- nil | "publishing" | { ok=bool }
  project  = nil,   -- nil | { name=string, version=string }
  cops     = nil,   -- nil | token list e.g. {"${CodeCop}", ...}
  root     = nil,   -- project root path (for git HEAD lookup)
  branch   = nil,   -- cached branch name
  branch_t = 0,    -- vim.uv.now() when branch was last read
}

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
local function branch()
  local now = vim.uv.now()
  if now - _s.branch_t > 2000 then
    _s.branch   = read_branch(_s.root)
    _s.branch_t = now
  end
  return _s.branch
end

-- Composed-string cache. M.get() is called from a %{} statusline expression, so
-- it runs on every redraw — every cursor move, every keystroke in some modes —
-- and it walks up to 8 directories looking for .git/HEAD and re-joins the cop
-- list each time. A short TTL collapses that to a few times a second while
-- staying visually immediate.
local _str, _str_t = nil, 0
local STR_TTL_MS = 250

-- redrawstatus! forces a full statusline redraw. al/progressNotification
-- arrives many times a second while the server indexes, and firing one redraw
-- per notification was most of the cost of watching a project load. Coalesce
-- to at most one redraw per interval; _pending guards against stacking
-- schedules while one is already in flight.
local _pending, _last_draw = false, 0
local DRAW_MS = 100

local function redraw()
  _str = nil  -- state changed: drop the composed-string cache
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
  _s.project  = { name = name, version = ver }
  _s.root     = root
  _s.branch_t = 0   -- force refresh on next get()
  redraw()
end

function M.set_lsp_starting()
  _s.lsp = "starting"
  _s.pct = nil
  redraw()
end

function M.set_lsp_loading(pct)
  _s.lsp = "loading"
  _s.pct = pct
  redraw()
end

function M.set_lsp_ready()
  _s.lsp = "ready"
  _s.pct = nil
  redraw()
end

function M.set_lsp_off()
  _s.lsp = nil
  _s.pct = nil
  redraw()
end

function M.is_loading()
  return _s.lsp == "loading"
end

function M.is_ready()
  return _s.lsp == "ready"
end

function M.set_compiling()
  _s.compile = "building"
  redraw()
end

function M.set_compile_result(errors, warnings)
  _s.compile = { ok = (errors == 0 and warnings == 0), errors = errors, warnings = warnings }
  redraw()
end

function M.set_publishing()
  _s.publish = "publishing"
  redraw()
end

function M.set_cops(tokens)
  _s.cops = tokens
  redraw()
end

function M.set_publish_result(ok)
  _s.publish = { ok = ok }
  redraw()
  -- Clear the publish result after 5 seconds so it doesn't linger
  vim.defer_fn(function()
    if type(_s.publish) == "table" then
      _s.publish = nil
      redraw()
    end
  end, 5000)
end

-- Returns a formatted string suitable for embedding in vim.wo.statusline via
-- %{v:lua.require('al.status').get()}
function M.get()
  local now = vim.uv.now()
  if _str and (now - _str_t) < STR_TTL_MS then return _str end

  local parts = {}

  if _s.project then
    parts[#parts + 1] = _s.project.name .. " " .. _s.project.version
  end

  local br = branch()
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

  _str   = #parts > 0 and table.concat(parts, "  ") or ""
  _str_t = now
  return _str
end

return M
