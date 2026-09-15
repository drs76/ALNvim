local M = {}

-- How far up to keep looking for app.json when the buffer is not inside a git
-- repository. Enough for src/<type>/<file>.al plus a few container folders.
local MAX_UP = 8

-- Walk up from `start` looking for app.json, bounded so a stray file far above
-- cannot claim the buffer.
--
-- vim.fs.root() walks to the filesystem root, which is how a single stray
-- /mnt/rojaws/app.json made every project on a 3.6TB NFS share resolve to the
-- mount point: AL Explorer then indexed the entire share (77k objects, 14s)
-- instead of the 9.5k in the actual project. An AL project is essentially
-- always inside a repository, so the enclosing .git directory is the natural
-- boundary — past it, we are no longer in this project by any reading.
--
-- Returns (dir, nil) on success, or (nil, reason) describing why it stopped, so
-- callers can tell "no project" apart from "found one, but outside the repo".
local function find_root_upward(start)
  if not start or start == "" then return nil, "buffer has no file name" end

  local boundary = vim.fs.root(start, { ".git" })   -- may be nil
  -- Start at the file's own directory (or `start` itself when it is one).
  local st   = vim.uv.fs_stat(start)
  local from = (st and st.type == "directory") and start or vim.fs.dirname(start)

  local levels = 0
  for _, dir in ipairs(vim.list_extend({ from }, vim.iter(vim.fs.parents(from)):totable())) do
    if vim.uv.fs_stat(dir .. "/app.json") then
      return dir
    end
    if boundary and dir == boundary then
      return nil, ("no app.json between the file and its repository root (" .. boundary .. ")")
    end
    levels = levels + 1
    if not boundary and levels >= MAX_UP then
      return nil, ("no app.json within " .. MAX_UP .. " directories of the file")
    end
  end
  return nil, "no app.json above the file"
end

-- Exposed so :ALInfo and tests can explain a failed resolution.
M.find_root_upward = find_root_upward

-- Return the AL project root for the given buffer (directory containing app.json).
-- Falls back to scanning downward from cwd when the buffer is outside a project
-- (e.g. a workspace root buffer). Prompts to pick if multiple projects are found.
function M.get_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(bufnr)

  -- Fast path: buffer is inside an AL project
  local from_buf, why = find_root_upward(fname)
  if from_buf then
    M.last_root_reason = nil
    return from_buf
  end
  -- Kept rather than notified: get_root runs on every save, so a warning here
  -- would be constant noise. :ALInfo reports it when the user comes looking.
  M.last_root_reason = why

  -- Fallback: scan downward from cwd for app.json, max 3 levels deep.
  -- vim.fs.find has no depth limit and will traverse entire drives on Windows.
  local cwd  = vim.fn.getcwd()
  local hits = {}
  for _, pat in ipairs({ "/app.json", "/*/app.json", "/*/*/app.json" }) do
    for _, f in ipairs(vim.fn.glob(cwd .. pat, false, true)) do
      table.insert(hits, f)
    end
  end
  if #hits == 0 then return nil end
  if #hits == 1 then return vim.fs.dirname(hits[1]) end

  -- Multiple projects: prompt user to pick
  local choices = {}
  for _, h in ipairs(hits) do
    table.insert(choices, vim.fs.dirname(h))
  end
  local items = { "Select AL project:" }
  for i, v in ipairs(choices) do
    table.insert(items, i .. ". " .. v)
  end
  local choice = vim.fn.inputlist(items)
  return choices[choice] or nil
end

-- Return the path of the first *.code-workspace file in dir, or nil.
function M.find_workspace_file(dir)
  local hits = vim.fn.glob(dir .. "/*.code-workspace", false, true)
  return hits[1]
end

-- Parse a *.code-workspace file and return absolute paths of folders that
-- contain app.json. Paths in the file are relative to the workspace file dir.
function M.workspace_roots(ws_file)
  local f = io.open(ws_file, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then return {} end
  local base = vim.fs.dirname(ws_file)
  local roots = {}
  for _, folder in ipairs(decoded.folders or {}) do
    local rel = folder.path or folder.name
    if rel then
      local abs = base .. "/" .. rel
      if vim.fn.filereadable(abs .. "/app.json") == 1 then
        table.insert(roots, abs)
      end
    end
  end
  return roots
end

-- Implicit Microsoft base packages: always required for full type resolution.
-- The appIds are stable Microsoft-assigned GUIDs that do not change across BC versions.
-- Versions come from app.json platform/application fields.
local BASE_PKG_IDS = {
  { id = "63ca2fa4-4f03-4f2b-a480-172fef340d3f", name = "System",              publisher = "Microsoft", ver_field = "platform"    },
  { id = "e3d1b010-7f32-4370-9d80-0cb7e304b6f6", name = "System Application",  publisher = "Microsoft", ver_field = "application" },
  { id = "407dec77-aba4-4b99-a6d7-fd3fd7fc9a91", name = "Business Foundation", publisher = "Microsoft", ver_field = "application" },
  { id = "437dbf0e-84ff-417a-965d-ed2bb9650972", name = "Base Application",    publisher = "Microsoft", ver_field = "application" },
  { id = "c1335042-3002-4257-bf8a-75c898ccb1b3", name = "Application",         publisher = "Microsoft", ver_field = "application" },
}

-- Build expectedProjectReferenceDefinitions for al/setActiveWorkspace:
-- implicit Microsoft base packages first, then explicit app.json dependencies,
-- duplicates skipped. Every sender of al/setActiveWorkspace must use this —
-- omitting the base packages means the server never loads the standard symbol
-- tables (table references in report dataitems, page source tables, etc.).
function M.build_project_refs(root)
  local app_json = M.read_app_json(root)
  local refs     = {}
  local explicit = {}
  for _, dep in ipairs((app_json and app_json.dependencies) or {}) do
    if dep.id then explicit[dep.id:lower()] = true end
  end
  for _, bp in ipairs(BASE_PKG_IDS) do
    if not explicit[bp.id:lower()] then
      refs[#refs + 1] = {
        appId     = bp.id,
        name      = bp.name,
        publisher = bp.publisher,
        version   = (app_json and app_json[bp.ver_field]) or "0.0.0.0",
      }
    end
  end
  for _, dep in ipairs((app_json and app_json.dependencies) or {}) do
    if dep.id then
      refs[#refs + 1] = {
        appId     = dep.id,
        name      = dep.name or "",
        publisher = dep.publisher or "",
        version   = dep.version or "0.0.0.0",
      }
    end
  end
  return refs
end

-- Read and decode app.json from a project root, or nil on failure
function M.read_app_json(root)
  root = root or M.get_root()
  if not root then return nil end
  local path = root .. "/app.json"
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.fn.json_decode, content)
  return ok and decoded or nil
end

return M
