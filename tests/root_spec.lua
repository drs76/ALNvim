-- lsp.find_root_upward — bounding the search for app.json.
--
-- vim.fs.root() walks to the filesystem root. A single stray app.json above a
-- project therefore claimed every file beneath it: on a real NFS share one such
-- file made AL Explorer index 77k objects across the whole mount (14s) instead
-- of the 9.5k in the actual project.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local lsp = require("al.lsp")

local function tree(spec)
  local root = vim.fn.tempname()
  for path, body in pairs(spec) do
    local p = root .. "/" .. path
    if body == true then                -- directory marker
      vim.fn.mkdir(p, "p")
    else
      vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
      vim.fn.writefile({ body }, p)
    end
  end
  return root
end

describe("lsp.find_root_upward", function()
  it("finds app.json in the file's own project", function()
    local r = tree({
      ["proj/app.json"]            = "{}",
      ["proj/.git/HEAD"]           = "ref: refs/heads/master",
      ["proj/src/table/T.Table.al"] = "table 50000 \"T\" { }",
    })
    eq(r .. "/proj", lsp.find_root_upward(r .. "/proj/src/table/T.Table.al"))
  end)

  it("stops at the repository root rather than taking a stray app.json above it", function()
    -- The exact shape that broke: no app.json in the project, one at the share root.
    local r = tree({
      ["share/app.json"]                       = "{}",
      ["share/Code/AL/MyProj/.git/HEAD"]       = "ref: refs/heads/master",
      ["share/Code/AL/MyProj/src/T.Table.al"]  = "table 50000 \"T\" { }",
    })
    local dir, why = lsp.find_root_upward(r .. "/share/Code/AL/MyProj/src/T.Table.al")
    eq(nil, dir)
    ok(why and why:find("repository root", 1, true), "reason should name the repo boundary, got: " .. tostring(why))
    -- and confirm the unbounded walk really would have escaped
    eq(r .. "/share", vim.fs.root(r .. "/share/Code/AL/MyProj/src/T.Table.al", { "app.json" }))
  end)

  it("still finds a project nested inside a larger repository", function()
    -- .git at the top, app.json in a subfolder: the nearer app.json must win.
    local r = tree({
      ["repo/.git/HEAD"]        = "ref: refs/heads/master",
      ["repo/al/app.json"]      = "{}",
      ["repo/al/src/T.Table.al"] = "table 50000 \"T\" { }",
    })
    eq(r .. "/repo/al", lsp.find_root_upward(r .. "/repo/al/src/T.Table.al"))
  end)

  it("bounds the walk when there is no repository at all", function()
    local deep = "a/b/c/d/e/f/g/h/i/src/T.al"
    local r = tree({ ["app.json"] = "{}", [deep] = "table 50000 \"T\" { }" })
    local dir, why = lsp.find_root_upward(r .. "/" .. deep)
    eq(nil, dir)
    ok(why and why:find("directories of the file", 1, true), "got: " .. tostring(why))
  end)

  it("accepts a directory as the starting point", function()
    local r = tree({ ["proj/app.json"] = "{}", ["proj/src"] = true })
    eq(r .. "/proj", lsp.find_root_upward(r .. "/proj/src"))
  end)

  it("reports a reason for an unnamed buffer", function()
    local dir, why = lsp.find_root_upward("")
    eq(nil, dir)
    ok(why and #why > 0)
  end)
end)
