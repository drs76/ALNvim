-- install.lua — locating an already-installed extension.
--
-- The "already installed?" check searched one extensions directory: the
-- Insiders one whenever ~/.vscode-insiders exists. A user with Insiders present
-- and the AL extension under stable ~/.vscode was told it was not installed,
-- and :ALInstallExtension re-downloaded the whole 300–700 MB VSIX every run.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local I = require("al.install")._test

-- Two extensions dirs standing in for ~/.vscode and ~/.vscode-insiders.
local function fixture(stable_versions, insiders_versions)
  local home = vim.fn.tempname()
  local bases = { home .. "/.vscode/extensions", home .. "/.vscode-insiders/extensions" }
  for i, versions in ipairs({ stable_versions, insiders_versions }) do
    vim.fn.mkdir(bases[i], "p")
    for _, v in ipairs(versions) do
      vim.fn.mkdir(bases[i] .. "/ms-dynamics-smb.al-" .. v, "p")
    end
  end
  return bases
end

describe("install.installed_path", function()
  it("finds an install in the stable dir when Insiders also exists", function()
    -- The exact regression: present under .vscode, absent under
    -- .vscode-insiders, and EXT_DIR would have pointed at the latter.
    local bases = fixture({ "18.0.2668733" }, {})
    local dir = I.installed_path("18.0.2668733", bases)
    ok(dir, "did not find the extension installed under .vscode")
    ok(dir:find("/.vscode/extensions/", 1, true), "found the wrong directory: " .. tostring(dir))
  end)

  it("finds an install in the Insiders dir", function()
    local bases = fixture({}, { "18.0.2668733" })
    local dir = I.installed_path("18.0.2668733", bases)
    ok(dir and dir:find("-insiders/extensions/", 1, true), "did not search the Insiders dir")
  end)

  it("returns nil for a version that is not installed", function()
    eq(nil, I.installed_path("19.0.0", fixture({ "18.0.2668733" }, {})))
  end)

  it("does not match a different version sharing a prefix", function()
    eq(nil, I.installed_path("18.0.26", fixture({ "18.0.2668733" }, {})))
  end)
end)

describe("install.installed_version", function()
  it("reports the newest across both directories", function()
    eq("18.1.0", I.installed_version(fixture({ "18.0.2668733" }, { "18.1.0" })))
    eq("18.1.0", I.installed_version(fixture({ "18.1.0" }, { "18.0.2668733" })))
  end)

  it("compares numerically, not lexically", function()
    eq("16.10.0", I.installed_version(fixture({ "16.9.0" }, { "16.10.0" })))
  end)

  it("is nil when nothing is installed", function()
    eq(nil, I.installed_version(fixture({}, {})))
  end)

  it("ignores a plain file named like an extension dir", function()
    local bases = fixture({}, {})
    vim.fn.writefile({ "" }, bases[1] .. "/ms-dynamics-smb.al-99.0.0")
    eq(nil, I.installed_version(bases))
  end)
end)

describe("ext.version_gt", function()
  local gt = require("al.ext").version_gt

  it("accepts bare version strings, not just directories", function()
    -- install.lua compares bare versions ("18.1.0"), ext.lua compares full
    -- directory paths. One shared function has to handle both — returning an
    -- empty part list for a bare version made every comparison false, so
    -- :ALUpdateExtension would report "already up to date" forever.
    ok(gt("18.1.0", "18.0.2668733"), "bare versions compared as equal")
    eq(false, gt("18.0.2668733", "18.1.0"))
  end)

  it("reads only the version tail of a directory path", function()
    -- A home directory containing digits must not take part in the comparison.
    ok(gt("/home/user9/.vscode/extensions/ms-dynamics-smb.al-18.1.0",
          "/home/user1/.vscode/extensions/ms-dynamics-smb.al-18.2.0") == false,
       "digits from the home directory leaked into the comparison")
  end)
end)
