local M = {}

-- Return the AL project root for the given buffer (directory containing app.json).
-- Falls back to scanning downward from cwd when the buffer is outside a project
-- (e.g. a workspace root buffer). Prompts to pick if multiple projects are found.
function M.get_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(bufnr)

  -- Fast path: buffer is inside an AL project
  local from_buf = vim.fs.root(fname, { "app.json" })
  if from_buf then return from_buf end

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
