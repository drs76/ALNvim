-- Locates the latest installed MS AL VSCode extension directory.
-- Called once at startup; result cached in M.path.
--
-- Extension directories look like:
--   ~/.vscode/extensions/ms-dynamics-smb.al-16.3.2065053/
--   ~/.vscode/extensions/ms-dynamics-smb.al-16.4.2100000/
--
-- Version parts are compared numerically so 16.10 sorts after 16.9.

local M = {}

local function version_parts(dir)
  local ver = dir:match("ms%-dynamics%-smb%.al%-(.-)/?$")
  if not ver then return {} end
  local parts = {}
  for n in ver:gmatch("%d+") do
    table.insert(parts, tonumber(n))
  end
  return parts
end

local function version_gt(a, b)
  local va = version_parts(a)
  local vb = version_parts(b)
  for i = 1, math.max(#va, #vb) do
    local na = va[i] or 0
    local nb = vb[i] or 0
    if na ~= nb then return na > nb end
  end
  return false
end

local function find()
  local pattern = vim.fn.expand("~/.vscode/extensions/ms-dynamics-smb.al-*")
  local dirs     = vim.fn.glob(pattern, false, true)

  -- Keep only actual directories (not leftover files)
  dirs = vim.tbl_filter(function(d)
    local stat = vim.uv.fs_stat(d)
    return stat and stat.type == "directory"
  end, dirs)

  if #dirs == 0 then
    vim.notify(
      "ALNvim: MS AL extension not found under ~/.vscode/extensions/\n"
      .. "Run :ALInstallExtension to download it automatically.",
      vim.log.levels.ERROR)
    return nil
  end

  -- Sort descending by version; pick the first (newest)
  table.sort(dirs, version_gt)
  return dirs[1]
end

M.path = find()

-- Re-scan for the newest installed extension (called after :ALInstallExtension).
function M.reload()
  M.path = find()
  return M.path
end

return M
