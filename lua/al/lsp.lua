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
