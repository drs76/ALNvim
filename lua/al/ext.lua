-- Locates the latest installed MS AL VSCode extension directory.
-- Called once at startup; result cached in M.path.
--
-- Searches both ~/.vscode/extensions and ~/.vscode-insiders/extensions so
-- the correct directory is found regardless of which VS Code variant is
-- installed (stable, Insiders, or both).
--
-- Extension directories look like:
--   ~/.vscode/extensions/ms-dynamics-smb.al-16.3.2065053/
--   ~/.vscode-insiders/extensions/ms-dynamics-smb.al-16.4.2100000/
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
  -- Use vim.fn.expand per directory (no wildcard) so the path is OS-normalised
  -- on Windows (backslash home + forward-slash suffix causes glob to fail).
  local dirs = {}
  local searched = {}

  for _, subdir in ipairs({ ".vscode", ".vscode-insiders" }) do
    -- expand "~/.vscode" etc. — no wildcard so no double-expansion (see CLAUDE.md)
    local base = vim.fn.expand("~/" .. subdir) .. "/extensions"
    table.insert(searched, base)
    local matched = vim.fn.glob(base .. "/ms-dynamics-smb.al-*", false, true)
    for _, d in ipairs(matched) do
      local stat = vim.uv.fs_stat(d)
      if stat and stat.type == "directory" then
        table.insert(dirs, d)
      end
    end
  end

  if #dirs == 0 then
    -- Defer notification past vim.pack.add to avoid it being caught as a fatal error.
    vim.api.nvim_create_autocmd("VimEnter", {
      once    = true,
      pattern = "*",
      callback = function()
        vim.notify(
          "ALNvim: MS AL extension not found.\nSearched:\n"
          .. "  " .. searched[1] .. "\n"
          .. "  " .. searched[2] .. "\n"
          .. "Run :ALInstallExtension to download it automatically.",
          vim.log.levels.WARN)
      end,
    })
    return nil
  end

  -- Sort descending by version; pick the first (newest) across both dirs
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
