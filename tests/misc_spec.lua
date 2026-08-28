-- Cross-module regressions: git path quoting, JSON writing, the .alpackages
-- filter, project references, connection URL building.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

describe("diff.unquote_path", function()
  local u = require("al.diff")._test.unquote_path

  it("leaves an unquoted path alone", function()
    eq("src/Plain.al", u("src/Plain.al"))
  end)

  it("strips the surrounding quotes", function()
    eq("with space.al", u('"with space.al"'))
  end)

  it("decodes octal escapes into UTF-8", function()
    -- git emits "Caf\303\251.al" for Café.al unless core.quotePath=false
    eq("Café.al", u('"Caf\\303\\251.al"'))
  end)

  it("decodes an escaped quote", function()
    eq('has "quote".al', u('"has \\"quote\\".al"'))
  end)

  it("decodes a backslash and a tab", function()
    eq("a\\b\tc.al", u('"a\\\\b\\tc.al"'))
  end)
end)

describe("json.pretty", function()
  local J = require("al.json")

  local function roundtrip(value)
    local encoded = vim.fn.json_encode(value)
    local pretty  = J.pretty(encoded)
    return vim.fn.json_decode(pretty), pretty
  end

  it("round-trips a nested structure unchanged", function()
    local v = { mcpServers = { ["al:X"] = { command = "/bin/al", args = { "a", "b" } } }, n = 42, b = true }
    local back = roundtrip(v)
    eq(v, back)
  end)

  it("indents rather than emitting one line", function()
    local _, pretty = roundtrip({ a = { b = 1 } })
    ok(pretty:find("\n", 1, true), "expected newlines in the output")
  end)

  it("keeps an empty object as {} and an empty array as []", function()
    local _, p1 = roundtrip(vim.empty_dict())
    local _, p2 = roundtrip({})
    eq("{}", p1)
    eq("[]", p2)
  end)

  it("does not corrupt braces, colons or quotes inside strings", function()
    local v = { s = [[has "quotes", a \ backslash, {braces} and : colons]] }
    eq(v, (roundtrip(v)))
  end)

  it("writes indented JSON to disk", function()
    local path = vim.fn.tempname()
    ok(J.write(path, { a = { b = 1 } }))
    local lines = vim.fn.readfile(path)
    ok(#lines > 1, "expected a multi-line file, got " .. #lines)
    eq({ a = { b = 1 } }, vim.fn.json_decode(table.concat(lines, "\n")))
    os.remove(path)
  end)
end)

describe("platform.glob_al_files", function()
  local platform = require("al.platform")

  local function mkproject(cache_dir)
    local root = vim.fn.tempname()
    for _, rel in ipairs({ "src/A.al", "src/nested/B.AL", cache_dir .. "/src/Base.al" }) do
      local p = root .. "/" .. rel
      vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
      vim.fn.writefile({ "" }, p)
    end
    return root
  end

  local function basenames(files)
    local n = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":t") end, files)
    table.sort(n)
    return n
  end

  it("finds project sources, both extensions", function()
    eq({ "A.al", "B.AL" }, basenames(platform.glob_al_files(mkproject(".alpackages"))))
  end)

  it("excludes a non-dotted package cache named by packagecachepath", function()
    -- This is the case that actually exercises the filter. A *dotted* cache dir
    -- escapes anyway, because vim.fn.glob("**/*") does not descend into
    -- dot-directories — so a test using .alpackages passes even with the
    -- filter removed, and proves nothing.
    local al   = require("al")
    local prev = al.config.packagecachepath
    al.config.packagecachepath = "packages"
    local files = platform.glob_al_files(mkproject("packages"))
    al.config.packagecachepath = prev

    eq({ "A.al", "B.AL" }, basenames(files))
    for _, f in ipairs(files) do
      ok(not f:find("/packages/", 1, true), "leaked a cache file: " .. f)
    end
  end)

  it("still excludes .alpackages when packagecachepath is something else", function()
    local al   = require("al")
    local prev = al.config.packagecachepath
    al.config.packagecachepath = "packages"
    local files = platform.glob_al_files(mkproject(".alpackages"))
    al.config.packagecachepath = prev
    eq({ "A.al", "B.AL" }, basenames(files))
  end)
end)

describe("lsp.build_project_refs", function()
  local lsp = require("al.lsp")

  it("always includes the five implicit Microsoft base packages", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ vim.fn.json_encode({
      name = "T", publisher = "P", version = "1.0.0.0",
      platform = "26.0.0.0", application = "26.0.0.0",
    }) }, root .. "/app.json")

    local refs  = lsp.build_project_refs(root)
    local names = vim.tbl_map(function(r) return r.name end, refs)
    eq({ "System", "System Application", "Business Foundation",
         "Base Application", "Application" }, names)
    eq("26.0.0.0", refs[1].version)  -- System takes the platform version
    eq("26.0.0.0", refs[2].version)  -- the rest take application
  end)

  it("appends explicit dependencies and skips duplicated base packages", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ vim.fn.json_encode({
      platform = "26.0.0.0", application = "26.0.0.0",
      dependencies = {
        { id = "437dbf0e-84ff-417a-965d-ed2bb9650972", name = "Base Application",
          publisher = "Microsoft", version = "26.1.0.0" },
        { id = "aaaaaaaa-0000-0000-0000-000000000001", name = "Other", publisher = "ISV", version = "1.0" },
      },
    }) }, root .. "/app.json")

    local names = vim.tbl_map(function(r) return r.name end, lsp.build_project_refs(root))
    -- Base Application appears once (from the explicit dep), not twice.
    local seen = 0
    for _, n in ipairs(names) do if n == "Base Application" then seen = seen + 1 end end
    eq(1, seen)
    eq("Other", names[#names])
  end)
end)

describe("connection URL building", function()
  local conn = require("al.connection")

  it("treats UserPassword as on-prem regardless of environmentType", function()
    -- BCContainerHelper sets environmentType=Sandbox even for local containers.
    eq(false, conn.is_cloud({ authentication = "UserPassword", environmentType = "Sandbox" }))
  end)

  it("treats a non-Microsoft server as on-prem", function()
    eq(false, conn.is_cloud({ environmentType = "Sandbox", server = "http://bc27" }))
  end)

  it("treats an empty server with Sandbox as cloud", function()
    eq(true, conn.is_cloud({ environmentType = "Sandbox" }))
  end)

  it("defaults the on-prem dev port to 7049", function()
    eq("http://bc:7049/BC", conn.base_url({ server = "http://bc", serverInstance = "BC" }))
  end)

  it("keeps a port already present in the server field", function()
    eq("http://bc:1234/BC", conn.base_url({ server = "http://bc:1234", serverInstance = "BC" }))
  end)

  it("builds the cloud dev endpoint", function()
    eq("https://api.businesscentral.dynamics.com/v2.0/t.com/sbx",
       conn.base_url({ environmentType = "Sandbox", tenant = "t.com", environmentName = "sbx" }))
  end)

  it("percent-encodes reserved characters", function()
    eq("a%20b%2Fc", conn.urlencode("a b/c"))
  end)
end)

describe("ext.version_gt", function()
  local gt = require("al.ext")._test.version_gt

  it("compares numerically, not lexically", function()
    ok(gt("ms-dynamics-smb.al-16.10.0", "ms-dynamics-smb.al-16.9.0"),
       "16.10 must sort above 16.9")
  end)

  it("is false for equal versions", function()
    eq(false, gt("ms-dynamics-smb.al-18.0.1", "ms-dynamics-smb.al-18.0.1"))
  end)

  it("treats a missing component as zero", function()
    ok(gt("ms-dynamics-smb.al-18.0.1", "ms-dynamics-smb.al-18.0"))
  end)
end)

describe("cops.short_names", function()
  local cops = require("al.cops")

  it("abbreviates the known cop tokens", function()
    eq("CC·PTE·UI", cops.short_names({ "${CodeCop}", "${PerTenantExtensionCop}", "${UICop}" }))
  end)

  it("reports an empty selection", function()
    eq("no cops", cops.short_names({}))
    eq("no cops", cops.short_names(nil))
  end)

  it("falls back to the token name for an unknown cop", function()
    eq("Custom", cops.short_names({ "${Custom}" }))
  end)
end)

describe("ids.free_ids", function()
  local I = require("al.ids")._test

  it("returns the first free ids in a range", function()
    local got = vim.tbl_map(function(m) return m.id end,
      I.free_ids({ { from = 50000, to = 50010 } }, { [50000] = true, [50001] = true }, 3, ""))
    eq({ 50002, 50003, 50004 }, got)
  end)

  it("filters by the typed numeric prefix", function()
    local got = vim.tbl_map(function(m) return m.id end,
      I.free_ids({ { from = 50000, to = 50110 } }, {}, 2, "5001"))
    eq({ 50010, 50011 }, got)
  end)

  it("returns nothing when the range is exhausted", function()
    eq({}, I.free_ids({ { from = 1, to = 2 } }, { [1] = true, [2] = true }, 5, ""))
  end)

  it("detects the object type on a declaration line", function()
    eq("tableextension", I.obj_type_from_line("tableextension 50000 X extends Y"))
    eq("codeunit", I.obj_type_from_line("  CODEUNIT 50000 X"))
    eq(nil, I.obj_type_from_line("    procedure Foo()"))
  end)
end)
