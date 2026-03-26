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

  -- Fallback: scan downward from cwd for app.json files
  local hits = vim.fs.find("app.json", {
    path  = vim.fn.getcwd(),
    upward = false,
    type  = "file",
    limit = 20,
  })
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
