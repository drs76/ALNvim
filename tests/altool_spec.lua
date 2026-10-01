-- The AL dotnet tool as the only toolchain: resolving the binary, and compile,
-- publish, symbols and MCP all refusing to fall back to the VS Code extension.
--
-- The reported failure: on a Windows laptop compiling "still used alc" and
-- publishing crashed. Both were the same fault. ALNvim looked for the tool only
-- at ~/.dotnet/tools/al[.exe]; when it was not there, compile silently ran the
-- extension's alc and publish fell through to the extension's DAP adapter,
-- which cannot publish to on-prem on Windows.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local altool   = require("al.altool")
local platform = require("al.platform")

-- A fake `al` executable in a fresh directory. Returns (dir, path).
local function fake_tool(name)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. (name or "al")
  vim.fn.writefile({ "#!/bin/sh", "echo 'compile publishapp launchmcpserver downloadsymbols'" }, path)
  vim.uv.fs_chmod(path, 493)  -- 0755
  return dir, path
end

-- Run fn with HOME / PATH / USERPROFILE / platform.is_windows overridden,
-- restoring all of them afterwards even if fn throws.
local function with_env(env, fn)
  local saved = {
    HOME = vim.env.HOME, PATH = vim.env.PATH, USERPROFILE = vim.env.USERPROFILE,
    win = platform.is_windows,
  }
  if env.HOME        ~= nil then vim.env.HOME        = env.HOME end
  if env.PATH        ~= nil then vim.env.PATH        = env.PATH end
  if env.USERPROFILE ~= nil then vim.env.USERPROFILE = env.USERPROFILE end
  if env.windows     ~= nil then platform.is_windows = env.windows end
  altool.reset()
  local okc, err = pcall(fn)
  vim.env.HOME, vim.env.PATH, vim.env.USERPROFILE = saved.HOME, saved.PATH, saved.USERPROFILE
  platform.is_windows = saved.win
  altool.reset()
  if not okc then error(err, 0) end
end

-- Pretend the VS Code extension is installed, whatever this machine has, so a
-- fallback to it is always reachable and a test can prove it is not taken.
-- Stubbing is required, not a convenience: al.ext resolves on first require,
-- and if that happens inside a faked environment (empty HOME) it reports no
-- extension — and a test of "does not fall back" then passes with the
-- fallback restored, because there was nothing to fall back to.
local function with_fake_extension(fn)
  local ext = require("al.ext")
  local saved = { path = ext.path, alc_cmd = ext.alc_cmd }
  ext.path    = "/fake/vscode/extensions/ms-dynamics-smb.al-99.0.0"
  ext.alc_cmd = function() return { "EXTENSION-ALC" } end
  local okc, err = pcall(fn)
  ext.path, ext.alc_cmd = saved.path, saved.alc_cmd
  if not okc then error(err, 0) end
end

-- An environment in which the tool cannot be found anywhere.
local function no_tool(fn)
  local empty = vim.fn.tempname(); vim.fn.mkdir(empty, "p")
  with_env({ HOME = empty, PATH = empty, USERPROFILE = empty }, fn)
end

describe("altool.binary", function()
  it("uses ~/.dotnet/tools/al when it is there", function()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home .. "/.dotnet/tools", "p")
    local _, path = fake_tool()
    vim.uv.fs_rename(path, home .. "/.dotnet/tools/al")
    with_env({ HOME = home, PATH = "/nonexistent" }, function()
      eq(home .. "/.dotnet/tools/al", altool.binary())
    end)
  end)

  it("finds the tool on PATH when it is not under ~", function()
    -- The shape of the Windows failure: installed and on PATH, but not where
    -- the old single-path lookup expected it.
    local empty = vim.fn.tempname(); vim.fn.mkdir(empty, "p")
    local dir, path = fake_tool()
    with_env({ HOME = empty, PATH = dir }, function()
      eq(path, altool.binary())
      eq(true, altool.available())
    end)
  end)

  it("on Windows, finds %USERPROFILE%\\.dotnet\\tools\\al.exe when HOME points elsewhere", function()
    -- A corporate machine often sets HOME to a network drive; the dotnet
    -- installer still writes under USERPROFILE.
    local home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
    local prof = vim.fn.tempname()
    vim.fn.mkdir(prof .. "/.dotnet/tools", "p")
    local _, path = fake_tool("al.exe")
    vim.uv.fs_rename(path, prof .. "/.dotnet/tools/al.exe")
    with_env({ HOME = home, USERPROFILE = prof, PATH = "/nonexistent", windows = true }, function()
      eq(prof .. "/.dotnet/tools/al.exe", altool.binary())
    end)
  end)

  it("returns the expected default path when nothing is found", function()
    no_tool(function()
      eq(false, altool.available())
      ok(altool.binary():match("/%.dotnet/tools/al$"), "default was " .. altool.binary())
      ok(altool.missing_msg("Compiling"):find(":ALInstallDotnetTool", 1, true))
    end)
  end)
end)

describe("compile without the dotnet tool", function()
  it("reports the tool missing instead of running the extension's alc", function()
    -- With an extension present, the old fallback returned its alc here —
    -- that silent substitution is the bug.
    with_fake_extension(function()
      no_tool(function()
        eq(nil, require("al.compile").compiler_prefix())
      end)
    end)
  end)

  it("uses `al compile` from the resolved tool", function()
    local dir, path = fake_tool()
    local empty = vim.fn.tempname(); vim.fn.mkdir(empty, "p")
    with_env({ HOME = empty, PATH = dir }, function()
      eq({ path, "compile" }, require("al.compile").compiler_prefix())
    end)
  end)
end)

describe("publish without the dotnet tool", function()
  it("errors instead of falling through to the DAP adapter", function()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    vim.fn.writefile({ vim.fn.json_encode({ name = "T", publisher = "P", version = "1.0.0.0" }) },
      root .. "/app.json")

    -- Make every old fallback reachable: nvim-dap "installed", extension found
    -- (with_fake_extension below), adapter stubbed to record the call.
    local saved_dap, saved_debug = package.loaded["dap"], package.loaded["al.debug"]
    package.loaded["dap"] = {}
    local adapter_called = false
    package.loaded["al.debug"] = setmetatable(
      { publish_only = function() adapter_called = true end },
      { __index = saved_debug })

    local notes, orig = {}, vim.notify
    vim.notify = function(m, l) notes[#notes + 1] = { m = m, l = l } end
    local okc, err = pcall(with_fake_extension, function()
      no_tool(function() require("al.publish").publish(root, true) end)
    end)
    vim.notify = orig
    package.loaded["dap"], package.loaded["al.debug"] = saved_dap, saved_debug
    if not okc then error(err, 0) end

    eq(false, adapter_called, "publish routed to the DAP adapter")
    ok(notes[1] and notes[1].l == vim.log.levels.ERROR
       and notes[1].m:find("AL dotnet tool", 1, true),
       "expected a missing-tool error, got " .. vim.inspect(notes))
  end)
end)

describe("altool.connection_flags", function()
  it("maps a cloud config", function()
    eq({ "--authentication", "AAD", "--tenant", "contoso.com",
         "--environmentname", "sandbox", "--environmenttype", "Sandbox" },
      altool.connection_flags({ authentication = "MicrosoftEntraID", tenant = "contoso.com",
        environmentType = "Sandbox", environmentName = "sandbox" }))
  end)

  it("maps an on-prem config and drops the 'default' tenant", function()
    eq({ "--authentication", "UserPassword", "--server", "http://bc",
         "--serverinstance", "BC", "--port", "7049" },
      altool.connection_flags({ authentication = "NavUserPassword", tenant = "default",
        environmentType = "Sandbox", server = "http://bc", serverInstance = "BC", port = 7049 }))
  end)
end)

describe("symbols arguments", function()
  local S = require("al.symbols")._test

  local function project(extra)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.vscode", "p")
    vim.fn.writefile({ vim.fn.json_encode(vim.tbl_extend("force", {}, extra or {})) },
      root .. "/.vscode/alnvim.json")
    return root
  end

  it("global CLI download passes country and every custom feed", function()
    local root = project({ symbolsCountryRegion = "gb", nugetFeeds = { "https://a", "https://b" } })
    local a = S.cli_args(root, "global")
    local j = table.concat(a, " ")
    ok(j:find("--globalsourcesonly", 1, true))
    ok(j:find("--symbolscountryregion gb", 1, true))
    ok(j:find("--nugetfeeds https://a --nugetfeeds https://b", 1, true), j)
    eq(root .. "/.alpackages", a[5])
  end)

  it("server CLI download passes the launch config's connection, not global flags", function()
    local j = table.concat(S.cli_args(project(), "server",
      { authentication = "UserPassword", server = "http://bc", serverInstance = "BC" }), " ")
    eq(nil, j:find("--globalsourcesonly", 1, true))
    ok(j:find("--server http://bc --serverinstance BC", 1, true), j)
  end)

  it("server MCP download for AAD asks the tool to sign in interactively", function()
    local a = S.mcp_args("/p", "server", { authentication = "MicrosoftEntraID",
      environmentType = "Sandbox", environmentName = "sbx" })
    eq("AAD", a.authentication)
    eq(true, a.useInteractiveLogin)
    eq("sbx", a.environmentName)
    eq(nil, a.globalSourcesOnly)
  end)

  it("reads the tool's JSON envelope", function()
    eq({ true, "Done (5 downloaded)" }, { S.summarize(true,
      '{"succeeded":true,"message":"Done","data":{"downloadedCount":5}}') })
    eq(false, (S.summarize(true, '{"succeeded":false,"message":"nope"}')))
  end)
end)

describe("mcp.configure", function()
  it("writes the binary altool resolves", function()
    -- mcp.lua kept its own copy of the path without ".exe", so on Windows the
    -- executable() check always failed and MCP could never be configured.
    local _, path = fake_tool()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    local orig = altool.binary
    altool.binary = function() return path end
    local okc = pcall(require("al.mcp").configure, root)
    altool.binary = orig
    ok(okc)
    local data = vim.fn.json_decode(table.concat(vim.fn.readfile(root .. "/.claude/settings.json"), "\n"))
    local entry = data.mcpServers["al:" .. vim.fn.fnamemodify(root, ":t")]
    eq(path, entry.command)
  end)
end)
