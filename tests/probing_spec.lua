-- .NET assembly probing paths: alc reported AL0451 "could not be found in the
-- assembly probing paths ''" for any project with a `dotnet` block, because
-- ALNvim never passed the setting VS Code passes.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local lsp      = require("al.lsp")
local al       = require("al")
local platform = require("al.platform")
local json     = require("al.json")

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(text, "\n"), path)
end

-- A project under a fresh parent dir, with VS Code user settings pointed away
-- from the real machine's so the result cannot depend on who runs the suite.
local function with_project(fn)
  local base = vim.fn.tempname()
  local root = base .. "/proj"
  vim.fn.mkdir(root, "p")
  local user = base .. "/user-settings.json"
  local saved_fn, saved_cfg = platform.vscode_user_settings, al.config.assembly_probing_paths
  platform.vscode_user_settings = function() return { user } end
  al.config.assembly_probing_paths = nil
  local okc, err = pcall(fn, root, base, user)
  platform.vscode_user_settings, al.config.assembly_probing_paths = saved_fn, saved_cfg
  vim.fn.delete(base, "rf")
  if not okc then error(err, 0) end
end

local function settings(paths)
  return vim.fn.json_encode({ ["al.assemblyProbingPaths"] = paths })
end

describe("lsp.assembly_probing_paths", function()
  it("is empty with nothing configured and no .netpackages", function()
    with_project(function(root) eq({}, lsp.assembly_probing_paths(root)) end)
  end)

  it("uses .netpackages by default only when it exists", function()
    with_project(function(root)
      vim.fn.mkdir(root .. "/.netpackages", "p")
      eq({ root .. "/.netpackages" }, lsp.assembly_probing_paths(root))
    end)
  end)

  it("reads a settings.json holding comments and a trailing comma", function()
    with_project(function(root)
      write(root .. "/.vscode/settings.json", table.concat({
        "{",
        '  // service tier assemblies',
        '  "al.assemblyProbingPaths": ["C:\\\\Program Files\\\\BC\\\\Service", "./libs",], /* done */',
        "}",
      }, "\n"))
      eq({ "C:\\Program Files\\BC\\Service", root .. "/libs" }, lsp.assembly_probing_paths(root))
    end)
  end)

  it("expands VS Code variables", function()
    with_project(function(root)
      vim.env.AL_PROBE_TEST = "/opt/x"
      write(root .. "/.vscode/settings.json",
        settings({ "${workspaceFolder}/a", "${env:AL_PROBE_TEST}/b" }))
      eq({ root .. "/a", "/opt/x/b" }, lsp.assembly_probing_paths(root))
      vim.env.AL_PROBE_TEST = nil
    end)
  end)

  it("applies VS Code's precedence between scopes", function()
    with_project(function(root, base, user)
      write(user, settings({ "/user" }))
      eq({ "/user" }, lsp.assembly_probing_paths(root))
      al.config.assembly_probing_paths = { "/setup" }
      eq({ "/setup" }, lsp.assembly_probing_paths(root))
      write(base .. "/all.code-workspace",
        vim.fn.json_encode({ folders = {}, settings = { ["al.assemblyProbingPaths"] = { "/ws" } } }))
      eq({ "/ws" }, lsp.assembly_probing_paths(root))
      write(root .. "/.vscode/settings.json", settings({ "/folder" }))
      eq({ "/folder" }, lsp.assembly_probing_paths(root))
    end)
  end)

  it("treats an explicit empty list as none, not as unset", function()
    with_project(function(root, _, user)
      write(user, settings({ "/user" }))
      vim.fn.mkdir(root .. "/.netpackages", "p")
      write(root .. "/.vscode/settings.json", '{ "al.assemblyProbingPaths": [] }')
      eq({}, lsp.assembly_probing_paths(root))
    end)
  end)

  it("survives an unparseable settings file", function()
    with_project(function(root, _, user)
      write(root .. "/.vscode/settings.json", "{ not json")
      write(user, settings({ "/user" }))
      eq({ "/user" }, lsp.assembly_probing_paths(root))
    end)
  end)
end)

describe("json.decode_jsonc", function()
  it("leaves comment and comma lookalikes inside strings alone", function()
    local got = json.decode_jsonc('{ "a": "http://x/*y*/,]", "b": "q\\"//", }')
    eq("http://x/*y*/,]", got.a)
    eq('q"//', got.b)
  end)

  it("returns nil for invalid input", function()
    eq(nil, json.decode_jsonc("{ nope"))
  end)
end)

-- Run fn with the tool present and jobstart recording its commands.
local function capture_jobs(fn)
  local altool = require("al.altool")
  local saved = { altool.available, altool.binary, vim.fn.jobstart }
  local cmds = {}
  altool.available = function() return true end
  altool.binary = function() return "/fake/al" end
  vim.fn.jobstart = function(cmd) cmds[#cmds + 1] = cmd; return 1 end
  local okc, err = pcall(fn)
  altool.available, altool.binary, vim.fn.jobstart = saved[1], saved[2], saved[3]
  if not okc then error(err, 0) end
  return cmds
end

describe("assembly probing reaches the tools", function()
  for _, entry in ipairs({ "compile", "analyze_diagnostics" }) do
    it("compile." .. entry .. " passes one flag per directory", function()
      with_project(function(root)
        write(root .. "/.vscode/settings.json", settings({ "/a", "/b,c" }))
        local cmds = capture_jobs(function() require("al.compile")[entry](root) end)
        eq(1, #cmds)
        ok(vim.tbl_contains(cmds[1], "/assemblyprobingpaths:/a"), "first dir missing")
        ok(vim.tbl_contains(cmds[1], "/assemblyprobingpaths:/b,c"), "second dir missing")
      end)
    end)
  end

  it("is passed to the agentic language server", function()
    with_project(function(root)
      write(root .. "/.vscode/settings.json", settings({ "/svc" }))
      local agentic = require("al.agentic_lsp")
      local saved_bin, saved_start, saved_exec = agentic.binary, vim.lsp.start, vim.fn.executable
      local got
      agentic.binary = function() return "/fake/al" end
      vim.fn.executable = function() return 1 end
      vim.lsp.start = function(c) got = c.cmd end
      local okc, err = pcall(agentic.start, 0, root)
      agentic.binary, vim.lsp.start, vim.fn.executable = saved_bin, saved_start, saved_exec
      if not okc then error(err, 0) end
      ok(vim.tbl_contains(got, "--assemblyprobingpath"), "flag missing")
      ok(vim.tbl_contains(got, "/svc"), "path missing")
    end)
  end)

  it("is passed to the MCP server before its project root", function()
    with_project(function(root)
      write(root .. "/.vscode/settings.json", settings({ "/svc" }))
      local args = require("al.mcp")._test.build_args(root)
      eq(root, args[#args])
      ok(vim.tbl_contains(args, "--assemblyprobingpath"), "flag missing")
      ok(vim.tbl_contains(args, "/svc"), "path missing")
    end)
  end)
end)
