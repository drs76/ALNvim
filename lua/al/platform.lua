-- Cross-platform helpers for ALNvim.
-- Centralises OS detection and all OS-specific operations so the rest of the
-- codebase stays clean of platform conditionals.

local M = {}

M.is_windows = vim.fn.has("win32") == 1
M.is_mac     = vim.fn.has("mac")   == 1

-- Subdirectory under <ext>/bin/ for the current OS.
function M.bin_subdir()
  if M.is_windows then return "win32"
  elseif M.is_mac  then return "darwin"
  else                   return "linux" end
end

-- Return name with .exe appended on Windows, unchanged elsewhere.
function M.exe(name)
  return M.is_windows and (name .. ".exe") or name
end

-- Ensure a file has the execute permission bits set.
-- No-op on Windows — executability is determined by file extension, not mode bits.
function M.ensure_executable(path)
  if M.is_windows then return end
  local stat = vim.uv.fs_stat(path)
  if stat and bit.band(stat.mode, 73) == 0 then   -- 73 = 0o111 (exec bits)
    vim.uv.fs_chmod(path, bit.bor(stat.mode, 73))
  end
end

-- Open a URL in the default browser.
function M.open_url(url)
  if M.is_windows then
    -- The empty string title prevents cmd from treating the URL as the window title.
    vim.fn.jobstart({ "cmd", "/c", "start", "", url }, { detach = true })
  elseif M.is_mac then
    vim.fn.jobstart({ "open", url })
  else
    vim.fn.jobstart({ "xdg-open", url })
  end
end

-- Extract a ZIP/VSIX archive to a destination directory.
-- @param src        source ZIP file (absolute path)
-- @param dst        destination directory (must exist)
-- @param files_glob string or table of unzip glob patterns (Linux/macOS only;
--                   Windows tar always extracts fully — subsequent glob still finds the files)
function M.extract_zip(src, dst, files_glob)
  if M.is_windows then
    -- tar.exe ships with Windows 10+ and handles ZIP archives with these flags.
    vim.fn.system({ "tar", "-xf", src, "-C", dst })
  else
    local cmd = { "unzip", "-q", "-o", src }
    if files_glob then
      local globs = type(files_glob) == "table" and files_glob or { files_glob }
      for _, p in ipairs(globs) do
        table.insert(cmd, p)
      end
    end
    vim.list_extend(cmd, { "-d", dst })
    vim.fn.system(cmd)
  end
end

-- Recursive directory copy used as a fallback when os.rename fails cross-device.
function M.copy_dir(src, dst)
  if M.is_windows then
    vim.fn.system({ "xcopy", src .. "\\.", dst, "/s", "/e", "/i", "/q" })
  else
    vim.fn.system({ "cp", "-r", src .. "/.", dst })
  end
end

-- Return all *.al / *.AL files under root, excluding .alpackages.
-- Uses vim.fn.glob so it works on both local and network (CIFS/SMB) paths on all OSes.
function M.glob_al_files(root)
  local files = vim.fn.glob(root .. "/**/*.al", false, true)
  vim.list_extend(files, vim.fn.glob(root .. "/**/*.AL", false, true))
  return vim.tbl_filter(function(f)
    return not f:find("%.alpackages", 1, true)
  end, files)
end

-- Convert a path to the OS-native separator.
-- On Windows, replaces forward slashes with backslashes.
-- On Linux/macOS, returns the path unchanged.
function M.native_path(path)
  if M.is_windows then
    return (path:gsub("/", "\\"))
  end
  return path
end

-- Stderr null-redirect suitable for the current shell.
-- Use by appending to a string passed to vim.fn.system(), not to table-form jobstart.
function M.devnull()
  return M.is_windows and "2>nul" or "2>/dev/null"
end

-- Build a minimal string-array environment for the DAP adapter subprocess.
-- @param stub_dir  directory containing the no-op xdg-open stub (Linux/macOS only)
-- @return string-array env for uv.spawn, or nil to inherit the parent environment
--
-- Linux: Neovim's full env causes the adapter to SIGABRT (NVIM/LD_* vars interfere
--   with the .NET runtime). A minimal env with the stub dir at the front of PATH is
--   passed instead.
-- Windows: no SIGABRT risk — return nil so the adapter inherits the parent env normally.
function M.adapter_env(stub_dir)
  if M.is_windows then return nil end
  local sys_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  local env = {
    "PATH="  .. stub_dir .. ":" .. sys_path,
    "HOME="  .. (os.getenv("HOME")   or "/root"),
    "TMPDIR=" .. (os.getenv("TMPDIR") or "/tmp"),
    "LANG="  .. (os.getenv("LANG")   or "C.UTF-8"),
  }
  for _, k in ipairs({ "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
                        "XDG_RUNTIME_DIR", "DOTNET_ROOT" }) do
    local v = os.getenv(k)
    if v and v ~= "" then table.insert(env, k .. "=" .. v) end
  end
  return env
end

return M
