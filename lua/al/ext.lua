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

-- True when `dir` actually contains the EditorServices host for this platform.
--
-- Version number alone is not enough. Extension 18.0.2668733 ships a different
-- layout — binaries flat in bin/ as .NET assemblies, with no bin/{linux,win32,
-- darwin}/ at all — so selecting it purely because it sorts highest produced a
-- path to a file that does not exist, and the LSP failed to spawn with
-- "not installed, missing from PATH, or not executable" while three perfectly
-- good older installs sat unused.
local function has_host(dir)
  local platform = require("al.platform")
  local host = dir .. "/bin/" .. platform.bin_subdir() .. "/"
             .. platform.exe("Microsoft.Dynamics.Nav.EditorServices.Host")
  return vim.uv.fs_stat(host) ~= nil
end

local function find()
  -- Use vim.fn.expand per directory (no wildcard) so the path is OS-normalised
  -- on Windows (backslash home + forward-slash suffix causes glob to fail).
  local dirs = {}
  local skipped = {}
  local searched = {}

  for _, subdir in ipairs({ ".vscode", ".vscode-insiders" }) do
    -- Expand only "~" then concatenate (see CLAUDE.md glob pitfall note).
    local base = vim.fn.expand("~") .. "/" .. subdir .. "/extensions"
    table.insert(searched, base)
    local matched = vim.fn.glob(base .. "/ms-dynamics-smb.al-*", false, true)
    for _, d in ipairs(matched) do
      local stat = vim.uv.fs_stat(d)
      if stat and stat.type == "directory" then
        if has_host(d) then
          table.insert(dirs, d)
        else
          table.insert(skipped, d)
        end
      end
    end
  end

  -- Every candidate is unusable on this platform: report the versions found
  -- rather than the generic "not installed" message, which would be misleading
  -- when the directories plainly exist.
  if #dirs == 0 and #skipped > 0 then
    table.sort(skipped, version_gt)
    vim.api.nvim_create_autocmd("VimEnter", {
      once    = true,
      pattern = "*",
      callback = function()
        local ok, al = pcall(require, "al")
        if ok and al.config and al.config.experimental_lsp then return end
        local names = {}
        for _, d in ipairs(skipped) do
          names[#names + 1] = "  " .. vim.fn.fnamemodify(d, ":t")
        end
        vim.notify(
          "ALNvim: found MS AL extension(s), but none ship bin/"
          .. require("al.platform").bin_subdir()
          .. "/Microsoft.Dynamics.Nav.EditorServices.Host:\n"
          .. table.concat(names, "\n")
          .. "\nEditorServices LSP/DAP unavailable. Compile still works via the "
          .. "dotnet AL tool; run :ALInstallExtension for a usable build.",
          vim.log.levels.WARN)
      end,
    })
    return nil
  end

  if #dirs == 0 then
    -- Defer notification past vim.pack.add to avoid it being caught as a fatal error.
    vim.api.nvim_create_autocmd("VimEnter", {
      once    = true,
      pattern = "*",
      callback = function()
        -- Agentic backend (al launchlspserver) needs no extension — stay quiet.
        local ok, al = pcall(require, "al")
        if ok and al.config and al.config.experimental_lsp then return end
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

  -- Sort descending by version; pick the newest *usable* install across both dirs
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
