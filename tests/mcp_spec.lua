-- mcp.lua — where the MCP server entry gets written.
--
-- This used to write the *global* ~/.claude/settings.json, and with auto_mcp on
-- by default every project ever opened left an entry behind. The entry's last
-- positional argument is the AL language server's workspace root, so a stale or
-- mis-resolved one is not inert: it indexes that tree in every Claude Code
-- session. One had accumulated pointing at a 3.6TB NFS share.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local mcp = require("al.mcp")

-- A throwaway project root. The al binary must exist for configure() to write,
-- so skip the write-path assertions when it is absent.
local HAVE_AL = vim.fn.executable(vim.fn.expand("~/.dotnet/tools/al")) == 1

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "{}" }, root .. "/app.json")
  return root
end

local function settings(root)
  local p = root .. "/.claude/settings.json"
  if vim.fn.filereadable(p) == 0 then return nil end
  return vim.fn.json_decode(table.concat(vim.fn.readfile(p), "\n"))
end

describe("mcp.configure", function()
  if not HAVE_AL then
    it("SKIPPED — ~/.dotnet/tools/al not installed", function() end)
    return
  end

  it("writes into the project, not the global settings file", function()
    local root = project()
    local global_before = vim.fn.filereadable(vim.fn.expand("~/.claude/settings.json")) == 1
      and vim.fn.readfile(vim.fn.expand("~/.claude/settings.json")) or nil

    ok(mcp.configure(root))
    local s = settings(root)
    ok(s, "expected <root>/.claude/settings.json to exist")
    ok(s.mcpServers, "expected an mcpServers table")

    -- the global file must be untouched
    local global_after = vim.fn.filereadable(vim.fn.expand("~/.claude/settings.json")) == 1
      and vim.fn.readfile(vim.fn.expand("~/.claude/settings.json")) or nil
    eq(global_before, global_after, "global ~/.claude/settings.json must not be modified")
  end)

  it("keys the entry on the project basename", function()
    local root = project()
    mcp.configure(root)
    local key = "al:" .. vim.fn.fnamemodify(root, ":t")
    ok(settings(root).mcpServers[key], "expected key " .. key)
  end)

  it("passes the project root as the server's workspace argument", function()
    local root = project()
    mcp.configure(root)
    local key  = "al:" .. vim.fn.fnamemodify(root, ":t")
    local args = settings(root).mcpServers[key].args
    -- Last positional argument is the workspace root — the field that made a
    -- mis-resolved root index a whole file share.
    eq(root, args[#args])
  end)

  it("is idempotent — a second call does not rewrite the file", function()
    local root = project()
    mcp.configure(root)
    local p     = root .. "/.claude/settings.json"
    local first = vim.fn.readfile(p)
    local mtime = vim.uv.fs_stat(p).mtime.nsec
    mcp.configure(root)
    eq(first, vim.fn.readfile(p))
    eq(mtime, vim.uv.fs_stat(p).mtime.nsec, "file should not have been rewritten")
  end)

  it("preserves unrelated keys already in the project settings", function()
    local root = project()
    vim.fn.mkdir(root .. "/.claude", "p")
    require("al.json").write(root .. "/.claude/settings.json",
      { permissions = { allow = { "Bash(ls:*)" } } })
    mcp.configure(root)
    local s = settings(root)
    eq({ allow = { "Bash(ls:*)" } }, s.permissions)
    ok(s.mcpServers, "mcpServers should have been added alongside")
  end)

  it("refuses to touch a settings file it cannot parse", function()
    -- Regression: read_settings returned {} for both 'absent' and 'unparseable',
    -- so one trailing comma in a hand-edited file meant configure() rewrote it
    -- with only mcpServers, destroying permissions/hooks/env. auto_mcp reaches
    -- this on every LspAttach, so opening one .al file was enough.
    local root = project()
    vim.fn.mkdir(root .. "/.claude", "p")
    local p = root .. "/.claude/settings.json"
    local broken = [[{ "permissions": { "allow": ["Bash(ls:*)"] }, }]]
    vim.fn.writefile({ broken }, p)

    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
    local result = mcp.configure(root)
    vim.notify = orig

    eq(false, result, "configure must report failure")
    eq({ broken }, vim.fn.readfile(p), "the file must be left byte-identical")
    ok(#msgs > 0 and msgs[1]:find("not valid JSON", 1, true),
       "expected an explanatory notify, got: " .. vim.inspect(msgs))
  end)

  it("writes indented JSON, not one line", function()
    local root = project()
    mcp.configure(root)
    ok(#vim.fn.readfile(root .. "/.claude/settings.json") > 1)
  end)
end)

-- Opt-in proxies beside al:<name>. Each needs a launch configuration for its
-- connection flags; the project fixture gets one here.
local ONPREM_LAUNCH = {
  version = "0.2.0",
  configurations = { { type = "al", name = "bc2", request = "launch", authentication = "UserPassword",
    server = "http://bc2", serverInstance = "BC", port = 7049, tenant = "default",
    environmentType = "OnPrem" } },
}
local CLOUD_LAUNCH = {
  version = "0.2.0",
  configurations = { { type = "al", name = "cloud", request = "launch", authentication = "MicrosoftEntraID",
    environmentType = "Sandbox", environmentName = "Dev", tenant = "contoso.onmicrosoft.com" } },
}

local function project_with_launch(launch)
  local root = project()
  vim.fn.mkdir(root .. "/.vscode", "p")
  require("al.json").write(root .. "/.vscode/launch.json", launch)
  return root
end

-- Run fn with setup({ mcp = opts }) in force, restoring the previous config.
local function with_mcp(opts, fn)
  local al    = require("al")
  local saved = al.config.mcp
  al.config.mcp = opts
  local okc, err = pcall(fn)
  al.config.mcp = saved
  if not okc then error(err, 0) end
end

local HAVE_PROXIES = HAVE_AL and require("al.altool").has("launchprofilingmcpproxy")

describe("mcp proxy entries", function()
  local MT = mcp._test

  it("writes no proxy entry unless opted in (default off)", function()
    local root = project_with_launch(ONPREM_LAUNCH)
    with_mcp({ profiling = false, snapshot = false }, function()
      eq({}, MT.proxy_entries(root))
    end)
    with_mcp(nil, function()
      eq({}, MT.proxy_entries(root))
    end)
  end)

  it("on-prem args carry the MCP service port 7047, not the dev port 7049", function()
    local args = MT.proxy_args("profiling", "/p", ONPREM_LAUNCH.configurations[1])
    eq("launchprofilingmcpproxy", args[1])
    ok(vim.tbl_contains(args, "7047"), vim.inspect(args))
    ok(not vim.tbl_contains(args, "7049"), "dev port leaked into proxy args: " .. vim.inspect(args))
    eq("/p/.profiles", args[#args])
  end)

  it("cloud args have no --server and no --port", function()
    local args = MT.proxy_args("snapshot", "/p", CLOUD_LAUNCH.configurations[1])
    eq("launchsnapshotmcpproxy", args[1])
    ok(not vim.tbl_contains(args, "--server"), vim.inspect(args))
    ok(not vim.tbl_contains(args, "--port"), vim.inspect(args))
    ok(vim.tbl_contains(args, "--environmentname"))
  end)

  it("references credentials through env variables, never values", function()
    local env = MT.proxy_env(ONPREM_LAUNCH.configurations[1])
    eq({ BC_SERVER_USERNAME = "${AL_BC_USERNAME}", BC_SERVER_PASSWORD = "${AL_BC_PASSWORD}" }, env)
    eq(nil, MT.proxy_env(CLOUD_LAUNCH.configurations[1]))
  end)

  it("owns three keys per project", function()
    local keys = MT.all_keys("/x/HTest")
    eq({ "al:HTest", "al-profiling:HTest", "al-snapshot:HTest" }, keys)
  end)

  if not HAVE_PROXIES then
    it("SKIPPED write-path — al tool with proxies not installed", function() end)
    return
  end

  it("writes al-profiling:<name> beside al:<name> when opted in", function()
    local root = project_with_launch(ONPREM_LAUNCH)
    with_mcp({ profiling = true, snapshot = false }, function()
      ok(mcp.configure(root))
    end)
    local name = vim.fn.fnamemodify(root, ":t")
    local s = settings(root).mcpServers
    ok(s["al:" .. name], "project server entry")
    ok(s["al-profiling:" .. name], "profiling entry expected: " .. vim.inspect(vim.tbl_keys(s)))
    eq(nil, s["al-snapshot:" .. name], "snapshot was not opted in")
    eq("launchprofilingmcpproxy", s["al-profiling:" .. name].args[1])
  end)

  it("status lists the proxy entries and deconfigure removes all three", function()
    local root = project_with_launch(ONPREM_LAUNCH)
    with_mcp({ profiling = true, snapshot = true }, function()
      mcp.configure(root)
    end)
    local proj = mcp.status(root)
    local keys = {}
    for _, e in ipairs(proj) do keys[#keys + 1] = e.key:match("^[^:]+") end
    eq({ "al", "al-profiling", "al-snapshot" }, keys)

    mcp.deconfigure(root)
    local s = settings(root)
    if s then
      local name = vim.fn.fnamemodify(root, ":t")
      for _, k in ipairs({ "al:", "al-profiling:", "al-snapshot:" }) do
        eq(nil, (s.mcpServers or {})[k .. name], k .. " should be gone")
      end
    end
  end)

  it("is idempotent with proxies on — a second configure does not rewrite", function()
    local root = project_with_launch(ONPREM_LAUNCH)
    with_mcp({ profiling = true, snapshot = true }, function()
      mcp.configure(root)
      local p     = root .. "/.claude/settings.json"
      local first = vim.fn.readfile(p)
      local mtime = vim.uv.fs_stat(p).mtime.nsec
      mcp.configure(root)
      eq(first, vim.fn.readfile(p))
      eq(mtime, vim.uv.fs_stat(p).mtime.nsec, "file should not have been rewritten")
    end)
  end)
end)

describe("mcp.deconfigure", function()
  if not HAVE_AL then
    it("SKIPPED — ~/.dotnet/tools/al not installed", function() end)
    return
  end

  it("removes the entry", function()
    local root = project()
    mcp.configure(root)
    mcp.deconfigure(root)
    local s = settings(root)
    -- file removed entirely, or at least the entry gone
    if s then
      eq(nil, (s.mcpServers or {})["al:" .. vim.fn.fnamemodify(root, ":t")])
    end
  end)

  it("keeps the file when other settings remain", function()
    local root = project()
    vim.fn.mkdir(root .. "/.claude", "p")
    require("al.json").write(root .. "/.claude/settings.json", { theme = "dark" })
    mcp.configure(root)
    mcp.deconfigure(root)
    local s = settings(root)
    ok(s, "file should survive because `theme` is still there")
    eq("dark", s.theme)
  end)
end)

describe("mcp.status", function()
  it("returns project entries and global entries separately", function()
    local root = project()
    local proj, glob = mcp.status(root)
    eq("table", type(proj))
    eq("table", type(glob))
    -- every reported entry is an al:* one
    for _, list in ipairs({ proj, glob }) do
      for _, e in ipairs(list) do
        ok(e.key:match("^al:"), "unexpected key: " .. e.key)
      end
    end
  end)

  it("reports nothing for a project with no settings file", function()
    local proj = mcp.status(project())
    eq({}, proj)
  end)
end)
