-- wizard.lua — object types, CRS paths and the file organiser.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local W = require("al.wizard")

local function type_info(key)
  for _, t in ipairs(W._test.TYPES) do
    if t.key == key then return t end
  end
end

local function scratch_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- A project root with app.json, and a writer for AL files under it.
local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ vim.fn.json_encode({
    name = "T", publisher = "P", version = "1.0.0.0",
    idRanges = { { from = 50100, to = 50149 } },
  }) }, root .. "/app.json")
  return root
end

local function open_al(root, rel, lines)
  local path = root .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), path
end

describe("wizard object types", function()
  it("offers the six added types with a template each", function()
    for _, key in ipairs({ "reportextension", "permissionsetextension", "profile",
                           "pagecustomization", "controladdin", "entitlement" }) do
      ok(type_info(key), "missing type " .. key)
      ok(W._test.TEMPLATES[key], "missing template " .. key)
    end
    for _, t in ipairs(W._test.TYPES) do
      ok(W._test.TEMPLATES[t.key], "no template for " .. t.key)
    end
  end)

  it("gives ID-less types no ID prompt", function()
    for _, key in ipairs({ "profile", "pagecustomization", "controladdin", "entitlement" }) do
      eq(false, type_info(key).has_id, key)
    end
    eq(true, type_info("reportextension").has_id)
  end)

  it("builds CRS paths for the new types", function()
    local root = project()
    local cases = {
      reportextension        = "/src/reportextension/SalesInvExt.ReportExt.al",
      permissionsetextension = "/src/permissionsetextension/SalesInvExt.PermissionSetExt.al",
      profile                = "/src/profile/SalesInvExt.Profile.al",
      pagecustomization      = "/src/pagecustomization/SalesInvExt.PageCust.al",
      controladdin           = "/src/controladdin/SalesInvExt.ControlAddin.al",
      entitlement            = "/src/entitlement/SalesInvExt.Entitlement.al",
    }
    for key, want in pairs(cases) do
      local _, path = W.build_path(root, type_info(key), "Sales Inv Ext")
      eq(root .. want, path, key)
    end
  end)

  it("generated objects are found by the organiser under the same path", function()
    -- build_path and organise_file derive the path independently; a new type
    -- the organiser does not recognise would be written and then never kept in
    -- step, one it names differently would be renamed on first save.
    local root = project()
    for _, key in ipairs({ "reportextension", "profile", "pagecustomization",
                           "controladdin", "entitlement" }) do
      local info = type_info(key)
      local content = W._test.TEMPLATES[key]({ id = 50100, name = "Thing", extends = "X" })
      local _, path = W.build_path(root, info, "Thing")
      local b = open_al(root, path:sub(#root + 2), vim.split(content, "\n"))
      W.organise_file(b)
      eq(path, vim.api.nvim_buf_get_name(b), key)
    end
  end)
end)

describe("wizard.detect_obj_type", function()
  local detect = W._test.detect_obj_type
  it("reads reportextension … extends", function()
    eq("reportextension", detect(scratch_buf({
      'namespace A.B;', '', 'reportextension 50100 "My Ext" extends "Standard Sales - Invoice"', '{' })))
  end)

  it("reads declarations without an ID", function()
    eq("profile", detect(scratch_buf({ "profile MyAgentProfile", "{" })))
    eq("pagecustomization", detect(scratch_buf({ 'pagecustomization "X" customizes "Customer List"' })))
    eq("entitlement", detect(scratch_buf({ 'entitlement "My Ent"' })))
    eq("controladdin", detect(scratch_buf({ "controladdin MyAddin" })))
    eq("interface", detect(scratch_buf({ 'interface "IFoo"' })))
  end)

  it("does not read a property as a declaration", function()
    eq(nil, detect(scratch_buf({ "    Profile = 'x';", "    Entitlement: Record X;" })))
  end)

  it("strips customizes from a page customization's name", function()
    local _, _, name = W.find_obj_decl(scratch_buf({ 'pagecustomization "My Cust" customizes "Customer List"' }))
    eq("My Cust", name)
  end)
end)

describe("wizard.organise_file scope", function()
  it("leaves a file under app/ alone — location and name", function()
    -- MS's Agent template lays code out by feature under app/. Moving
    -- app/Setup/MyAgentSetup.Table.al to src/table/ on first :w scrambles the
    -- template the user just created.
    local root = project()
    local b, path = open_al(root, "app/Setup/X.Table.al",
      { 'table 50100 "My Agent Setup"', "{", "}" })
    W.organise_file(b)
    eq(path, vim.api.nvim_buf_get_name(b))
    eq(1, vim.fn.filereadable(path))
    eq(0, vim.fn.isdirectory(root .. "/src/table"))
  end)

  it("removes spaces from the object name — never replaces them with _", function()
    -- CRS naming strips spaces. Until 2026-11-15 sanitise_name wrote "_"
    -- instead, so a project with hand-named PrivateGallerySetup.Page.al got
    -- a second file Private_Gallery_Setup.Page.al on its first :w.
    local root = project()
    local b, path = open_al(root, "src/page/PrivateGallerySetup.Page.al",
      { 'page 50100 "Private Gallery Setup"', "{", "}" })
    W.organise_file(b)
    eq(path, vim.api.nvim_buf_get_name(b))
    eq(1, vim.fn.filereadable(path))
    eq(0, vim.fn.filereadable(root .. "/src/page/Private_Gallery_Setup.Page.al"))
  end)

  it("still moves a root-level file into src/<type>/", function()
    local root = project()
    local b, path = open_al(root, "HelloWorld.al",
      { 'pageextension 50100 CustomerListExt extends "Customer List"', "{", "}" })
    W.organise_file(b)
    local want = root .. "/src/pageextension/CustomerListExt.PageExt.al"
    eq(want, vim.api.nvim_buf_get_name(b))
    eq(1, vim.fn.filereadable(want))
    eq(0, vim.fn.filereadable(path))
  end)

  it("still moves a misplaced file inside src/", function()
    local root = project()
    local b = open_al(root, "src/Misc.al", { "codeunit 50100 Foo", "{", "}" })
    W.organise_file(b)
    eq(root .. "/src/codeunit/Foo.Codeunit.al", vim.api.nvim_buf_get_name(b))
  end)

  it("honours organise_dirs", function()
    local al = require("al")
    local saved = al.config.organise_dirs
    al.config.organise_dirs = { "app" }
    local okc, err = pcall(function()
      eq(true, W._test.in_organise_scope("app/Setup/X.Table.al"))
      eq(false, W._test.in_organise_scope("src/X.Table.al"))
      eq(false, W._test.in_organise_scope("application/X.Table.al"))
      eq(true, W._test.in_organise_scope("X.Table.al"))
    end)
    al.config.organise_dirs = saved
    if not okc then error(err, 0) end
  end)
end)
