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

-- ── Extension layouts ────────────────────────────────────────────────────────
--
-- Two shapes exist in the wild and both must be supported:
--
--   "native"  (<= 18.0.2293710)  bin/{linux,win32,darwin}/EditorServices.Host[.exe]
--                                bin/Analyzers/*.dll
--                                bin/<platform>/alc[.exe]
--
--   "dotnet"  (>= 18.0.2668733)  bin/EditorServices.Host.dll   — framework-dependent
--                                bin/*.dll                     — analyzers, flat
--                                bin/alc.dll
--                                no bin/<platform>/ at all
--
-- The dotnet layout is framework-dependent (net10.0, needing both
-- Microsoft.NETCore.App and Microsoft.AspNetCore.App), so it is launched as
-- `dotnet <dll>` — which is exactly what VS Code does with its own bundled
-- runtime. Verified against 18.0.2668733: the server completes an LSP
-- initialize handshake and still reports definitionProvider = false, so every
-- custom-protocol workaround in plugin/al.lua continues to apply unchanged.

local HOST_BASE = "Microsoft.Dynamics.Nav.EditorServices.Host"

local function native_host(dir)
  local platform = require("al.platform")
  return dir .. "/bin/" .. platform.bin_subdir() .. "/" .. platform.exe(HOST_BASE)
end

local function dotnet_host(dir)
  return dir .. "/bin/" .. HOST_BASE .. ".dll"
end

-- Resolve a dotnet muxer able to run the framework-dependent layout.
-- Cached: nil = not probed, false = probed and absent, string = the path.
--
-- Only existence is checked here, not runtime versions. Probing versions means
-- a `dotnet --list-runtimes` subprocess, and this runs during startup while
-- choosing an extension; a dotnet too old to satisfy net10.0 produces a clear
-- "You must install .NET" message from the muxer itself anyway.
local _dotnet = nil
function M.dotnet()
  -- Configured path wins and is re-read on every call. This module is first
  -- loaded (and _dotnet first cached) before setup() runs, so a cached value
  -- must never be allowed to shadow an explicit dotnet_path.
  --
  -- package.loaded, not require: this is reachable from ext.lua's own module
  -- body via find(), where require("al") would re-enter a partially
  -- initialised module — al -> al.ext -> al. That cycle is exactly what the
  -- removed `ext_path` default used to cause.
  local al  = package.loaded["al"]
  local cfg = al and al.config and al.config.dotnet_path
  if cfg and cfg ~= "" then
    local p = vim.fn.expand(cfg)
    if vim.fn.executable(p) == 1 then return p end
  end

  if _dotnet ~= nil then return _dotnet or nil end

  local candidates = {}
  local root = os.getenv("DOTNET_ROOT")
  if root and root ~= "" then
    table.insert(candidates, root .. "/" .. require("al.platform").exe("dotnet"))
  end
  table.insert(candidates, "dotnet")  -- PATH
  -- Last resort: the runtime the VS Code .NET Install Tool downloads for the
  -- extension. Present whenever the new-layout extension has actually been run
  -- from VS Code, which is the case that brought us here.
  local home = vim.fn.expand("~")
  for _, pat in ipairs({
    home .. "/.config/Code/User/globalStorage/ms-dotnettools.vscode-dotnet-runtime/.dotnet/*/dotnet",
    home .. "/.config/Code - Insiders/User/globalStorage/ms-dotnettools.vscode-dotnet-runtime/.dotnet/*/dotnet",
  }) do
    local hits = vim.fn.glob(pat, false, true)
    table.sort(hits, function(a, b) return a > b end)  -- newest runtime first
    vim.list_extend(candidates, hits)
  end

  for _, c in ipairs(candidates) do
    if vim.fn.executable(c) == 1 then
      _dotnet = c
      return c
    end
  end
  _dotnet = false
  return nil
end

-- Layout of `dir`, or nil when it holds no usable EditorServices host.
-- The dotnet layout only counts as usable when a muxer exists to run it —
-- otherwise a new-layout install would be selected and then fail to spawn,
-- which is the regression this whole check exists to prevent.
local function layout_of(dir)
  if vim.uv.fs_stat(native_host(dir)) then return "native" end
  if vim.uv.fs_stat(dotnet_host(dir)) and M.dotnet() then return "dotnet" end
  return nil
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
        if layout_of(d) then
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
        local why = M.dotnet()
          and ("no bin/" .. require("al.platform").bin_subdir()
               .. "/Microsoft.Dynamics.Nav.EditorServices.Host and no bin/"
               .. "Microsoft.Dynamics.Nav.EditorServices.Host.dll")
          or  ("no bin/" .. require("al.platform").bin_subdir()
               .. "/Microsoft.Dynamics.Nav.EditorServices.Host, and the newer "
               .. "dotnet layout needs a `dotnet` runtime which was not found "
               .. "(set dotnet_path in setup(), or install the .NET 10 runtime)")
        vim.notify(
          "ALNvim: found MS AL extension(s), but none are usable — " .. why .. ":\n"
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

M.path   = find()
-- "native" | "dotnet" | nil — which bin layout M.path uses. Read it via the
-- accessors below rather than branching on it directly.
M.layout = M.path and layout_of(M.path) or nil

-- Re-scan for the newest installed extension (called after :ALInstallExtension).
function M.reload()
  M.path   = find()
  M.layout = M.path and layout_of(M.path) or nil
  return M.path
end

-- ── Layout-aware accessors ───────────────────────────────────────────────────
-- Everything outside this module must go through these rather than assembling
-- bin/<platform>/… paths itself, or it will silently break on the dotnet layout.

-- Command array that launches the EditorServices host, or nil.
-- native → { "<ext>/bin/linux/…Host" }      dotnet → { "<dotnet>", "<ext>/bin/…Host.dll" }
function M.host_cmd()
  if not M.path then return nil end
  if M.layout == "native" then
    local host = native_host(M.path)
    require("al.platform").ensure_executable(host)
    return { host }
  elseif M.layout == "dotnet" then
    local dn = M.dotnet()
    if not dn then return nil end
    return { dn, dotnet_host(M.path) }
  end
  return nil
end

-- Command array prefix that runs the extension's bundled alc, or nil.
-- Only a fallback: compile.lua prefers the standalone dotnet AL tool.
function M.alc_cmd()
  if not M.path then return nil end
  local platform = require("al.platform")
  if M.layout == "native" then
    local alc = M.path .. "/bin/" .. platform.bin_subdir() .. "/" .. platform.exe("alc")
    if vim.fn.filereadable(alc) == 0 then return nil end
    platform.ensure_executable(alc)
    return { alc }
  elseif M.layout == "dotnet" then
    local dll = M.path .. "/bin/alc.dll"
    local dn  = M.dotnet()
    if not dn or vim.fn.filereadable(dll) == 0 then return nil end
    return { dn, dll }
  end
  return nil
end

-- Directory holding the analyzer (cop) DLLs, or nil.
-- native → <ext>/bin/Analyzers      dotnet → <ext>/bin  (assemblies are flat)
function M.analyzers_dir()
  if not M.path then return nil end
  if M.layout == "native" then
    return M.path .. "/bin/Analyzers"
  elseif M.layout == "dotnet" then
    return M.path .. "/bin"
  end
  return nil
end

return M
