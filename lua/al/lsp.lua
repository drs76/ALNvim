local M = {}

-- Return the AL project root for the given buffer (directory containing app.json)
function M.get_root(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(bufnr)
  return vim.fs.root(fname, { "app.json" }) or vim.fs.root(fname, { ".git" })
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
