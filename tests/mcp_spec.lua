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

  it("writes indented JSON, not one line", function()
    local root = project()
    mcp.configure(root)
    ok(#vim.fn.readfile(root .. "/.claude/settings.json") > 1)
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
