-- cops.lua — the alnvim.json round-trip.
--
-- Written through al.json.write (indented, other keys preserved) and read back
-- with the defaults when the file is absent or has no codeAnalyzers key.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local cops = require("al.cops")

local DEFAULT = { "${CodeCop}", "${PerTenantExtensionCop}", "${UICop}" }

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.vscode", "p")
  return root
end

describe("cops.get_active", function()
  it("defaults when alnvim.json is absent", function()
    eq(DEFAULT, cops.get_active(project()))
  end)
  it("defaults when the key is missing or the file is invalid", function()
    local root = project()
    vim.fn.writefile({ '{ "browser": "firefox" }' }, root .. "/.vscode/alnvim.json")
    eq(DEFAULT, cops.get_active(root))
    vim.fn.writefile({ '{ not json' }, root .. "/.vscode/alnvim.json")
    eq(DEFAULT, cops.get_active(root))
  end)
end)

describe("cops.set_active", function()
  it("round-trips and preserves other keys, indented", function()
    local root = project()
    vim.fn.writefile({ '{ "browser": "firefox" }' }, root .. "/.vscode/alnvim.json")
    cops.set_active(root, { "${CodeCop}", "${AppSourceCop}" })
    eq({ "${CodeCop}", "${AppSourceCop}" }, cops.get_active(root))
    local lines = vim.fn.readfile(root .. "/.vscode/alnvim.json")
    ok(#lines > 1, "indented, not one line")
    local data = vim.fn.json_decode(table.concat(lines, "\n"))
    eq("firefox", data.browser)
  end)
  it("creates the file when absent", function()
    local root = project()
    cops.set_active(root, { "${UICop}" })
    eq({ "${UICop}" }, cops.get_active(root))
  end)
end)

describe("cops.get_browser / set_browser", function()
  it("round-trips beside codeAnalyzers", function()
    local root = project()
    cops.set_active(root, { "${UICop}" })
    cops.set_browser(root, "chromium")
    eq("chromium", cops.get_browser(root))
    eq({ "${UICop}" }, cops.get_active(root))
  end)
end)
