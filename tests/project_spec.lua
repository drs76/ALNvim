-- project.lua — :ALNewProject scaffolding.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local P = require("al.project")._test

local function runtime(ver)
  for _, r in ipairs(P.RUNTIMES) do
    if r.runtime == ver then return r end
  end
end

describe("project.gen_uuid", function()
  it("produces a syntactically valid v4 UUID", function()
    local u = P.gen_uuid()
    ok(u:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"),
      "not a v4 UUID: " .. tostring(u))
  end)

  it("returns exactly one value", function()
    -- gsub returns (string, count). Unparenthesised, the count leaks into the
    -- caller — harmless in the middle of an argument list, a silent extra
    -- argument at the end of one.
    eq(1, select("#", P.gen_uuid()))
  end)

  it("does not repeat across many calls", function()
    -- This is the app.json `id`. Two extensions claiming one ID is a publish
    -- failure in BC, so a same-second reseed producing a repeat is not cosmetic.
    local seen, dup = {}, 0
    for _ = 1, 500 do
      local u = P.gen_uuid()
      if seen[u] then dup = dup + 1 end
      seen[u] = true
    end
    eq(0, dup)
  end)

  it("varies the variant nibble across the allowed set", function()
    -- Regression guard on the hand-rolled variant arithmetic: if it collapsed
    -- to a constant the UUIDs would still look valid.
    local variants = {}
    for _ = 1, 200 do
      variants[P.gen_uuid():sub(20, 20)] = true
    end
    ok(vim.tbl_count(variants) > 1,
      "variant nibble never varied: " .. vim.inspect(vim.tbl_keys(variants)))
  end)
end)

describe("project.build_app_json", function()
  it("emits parseable JSON with the chosen runtime and ID range", function()
    local rv = runtime("18.0")
    local app = vim.fn.json_decode(P.build_app_json("My App", "Me", rv, 50100))
    eq("18.0", app.runtime)
    eq("29.0.0.0", app.application)
    eq(50100, app.idRanges[1].from)
    eq(50149, app.idRanges[1].to)
    -- MS's own templates ship platform 1.0.0.0; this is not a placeholder.
    eq("1.0.0.0", app.platform)
    ok(app.id:match("^%x+%-"), "id is not a UUID: " .. tostring(app.id))
  end)

  it("does not emit showMyCode alongside resourceExposurePolicy", function()
    -- The compiler rejects the pair: AL1075 "Both 'ShowMyCode' and
    -- 'ResourceExposurePolicy' properties are added" is an error, so every
    -- project :ALNewProject created failed its first build. MS's own templates
    -- carry resourceExposurePolicy only.
    local app = vim.fn.json_decode(P.build_app_json("A", "P", runtime("18.0"), 50000))
    eq(nil, app.showMyCode)
    ok(type(app.resourceExposurePolicy) == "table", "resourceExposurePolicy missing")
  end)

  it("escapes quotes and backslashes in the name and publisher", function()
    local app = vim.fn.json_decode(
      P.build_app_json([[A "quoted" \ name]], [[Pub\"lisher]], runtime("18.0"), 50000))
    eq([[A "quoted" \ name]], app.name)
    eq([[Pub\"lisher]], app.publisher)
  end)
end)

describe("project.build_hello_world", function()
  it("uses the ID range start for the object ID", function()
    ok(P.build_hello_world("App", "Pub", runtime("18.0"), 50100)
       :find("pageextension 50100 CustomerListExt", 1, true))
  end)

  it("emits a namespace on runtime >= 12 and none below", function()
    ok(P.build_hello_world("My App", "My Pub", runtime("12.0"), 50000)
       :find("namespace MyPub.MyApp;", 1, true), "namespace missing on runtime 12")
    eq(nil, P.build_hello_world("My App", "My Pub", runtime("11.0"), 50000)
            :find("namespace", 1, true))
  end)
end)

describe("project.write_lines", function()
  it("does not leave a trailing blank line", function()
    local path = vim.fn.tempname()
    P.write_lines(path, "a\nb\n")
    eq({ "a", "b" }, vim.fn.readfile(path))
    os.remove(path)
  end)
end)

describe("the starter object's location", function()
  it("is where wizard.organise_file would put it", function()
    -- The real assertion: organise_file runs on BufWritePost for every AL file
    -- under the project root. Writing HelloWorld.al at the root — which is what
    -- VSCode's template does — means it gets renamed out from under the user on
    -- the first :w. Generate the file at HELLO_WORLD_PATH, run organise_file
    -- over it, and require that it stays put.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ vim.fn.json_encode({
      name = "T", publisher = "P", version = "1.0.0.0",
      platform = "1.0.0.0", application = "29.0.0.0",
      idRanges = { { from = 50100, to = 50149 } },
    }) }, root .. "/app.json")

    local path = root .. "/" .. P.HELLO_WORLD_PATH
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    P.write_lines(path, P.build_hello_world("T", "P", runtime("18.0"), 50100))

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    require("al.wizard").organise_file(bufnr)

    eq(path, vim.api.nvim_buf_get_name(bufnr))
    eq(1, vim.fn.filereadable(path))
  end)
end)

describe("project name validation", function()
  -- new_project() is a chain of vim.ui prompts, so the guard is exercised
  -- through the same predicate rather than by driving the whole wizard.
  local function rejected(name)
    return name:find("[/\\]") ~= nil or name:find("%.%.") ~= nil
  end

  it("rejects a name that would escape the parent directory", function()
    ok(rejected("../evil"))
    ok(rejected("a/b"))
    ok(rejected([[a\b]]))
  end)

  it("accepts an ordinary project name", function()
    eq(false, rejected("ALProject1"))
    eq(false, rejected("My App"))
  end)
end)

describe("project.substitute", function()
  local function vars()
    return { id = 50100, projectname = "My App", publishername = "Me",
             rootnamespace = "Me.MyApp" }
  end

  it("replaces every placeholder the extension templates use", function()
    local out = P.substitute(
      "{{id+0}} {{id+1}} {{id+49}} {{id+149}} {{projectname}} {{publishername}} {{rootnamespace}}",
      vars())
    eq("50100 50101 50149 50249 My App Me Me.MyApp", out)
  end)

  it("turns {{guidK}} into a UUID", function()
    local out = P.substitute('"id": "{{guid0}}"', vars())
    ok(out:match('^"id": "%x+%-%x+%-4%x+%-[89ab]%x+%-%x+"$'), out)
  end)

  it("keeps one guid per index across files of one project", function()
    -- app.json's {{guid0}} is the app id; a code file referring to {{guid0}}
    -- must get the same value, not a fresh one.
    local v = vars()
    local a = P.substitute("{{guid0}}|{{guid1}}", v)
    local b = P.substitute("{{guid0}}", v)
    local g0, g1 = a:match("^(.-)|(.*)$")
    eq(g0, b)
    ok(g0 ~= g1, "different indices must differ")
  end)

  it("leaves unknown placeholders and % in values alone", function()
    local v = vars(); v.projectname = "100% App"
    eq("{{nope}} 100% App", P.substitute("{{nope}} {{projectname}}", v))
  end)

  it("derives the root namespace as the starter object does", function()
    eq("MyPub.MyApp", P.root_namespace("My-App", "My Pub"))
    eq("DefaultNamespace", P.root_namespace("App", ""))
  end)
end)

-- A fake extension directory with two templates, one with a .resources dir.
local function fake_ext()
  local ext = vim.fn.tempname()
  local function put(rel, text)
    local p = ext .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "wb")); f:write(text); f:close()
  end
  put("templates/agent/altemplate.json",
    '{ "name": "Agent", "description": "Agent template", "generateAppJson": false }')
  put("templates/agent/app.json",
    '{ "id": "{{guid0}}", "name": "{{projectname}}", "publisher": "{{publishername}}",'
    .. ' "idRanges": [ { "from": {{id+0}}, "to": {{id+49}} } ] }')
  put("templates/agent/app/Setup/MyAgentSetup.Table.al",
    "namespace {{rootnamespace}};\r\n\r\ntable {{id+0}} \"My Agent Setup\"\r\n{\r\n}\r\n")
  put("templates/agent/app/Setup/Ref.Codeunit.al", "// {{guid0}}\n")
  put("templates/agent/.resources/Instructions/InstructionsV1.txt", "Hi {{projectname}}\n")
  put("templates/Hello World/altemplate.json",
    '{ "name": "(Preview) Hello World", "generateAppJson": true }')
  put("templates/Hello World/HelloWorld.al", "pageextension {{id+0}} X extends \"Customer List\" {}\n")
  put("templates/Hello World/app.json", '{ "should": "not be copied" }')
  return ext
end

describe("project.list_templates", function()
  it("offers only the built-in starter without an extension", function()
    local list = P.list_templates(false)
    eq(1, #list)
    eq("Hello World (built-in)", list[1].name)
    ok(list[1].builtin)
  end)

  it("lists the extension's templates after the built-in one", function()
    local list = P.list_templates(fake_ext())
    eq({ "Hello World (built-in)", "(Preview) Hello World", "Agent" },
       vim.tbl_map(function(t) return t.name end, list))
    eq(false, list[3].generate_app_json)
    eq(true, list[2].generate_app_json)
  end)
end)

describe("project.scaffold_template", function()
  local function read(p)
    local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s
  end

  it("copies, substitutes and includes the dot-dir", function()
    local list = P.list_templates(fake_ext())
    local dest = vim.fn.tempname()
    local written = P.scaffold_template(list[3], dest,
      { name = "My App", publisher = "Me", id_from = 50100 })
    table.sort(written)
    eq({ ".resources/Instructions/InstructionsV1.txt", "app.json",
         "app/Setup/MyAgentSetup.Table.al", "app/Setup/Ref.Codeunit.al" }, written)
    eq(0, vim.fn.filereadable(dest .. "/altemplate.json"))
    eq("Hi My App\n", read(dest .. "/.resources/Instructions/InstructionsV1.txt"))
    -- CRLF survives: io, not readfile/writefile.
    eq("namespace Me.MyApp;\r\n\r\ntable 50100 \"My Agent Setup\"\r\n{\r\n}\r\n",
       read(dest .. "/app/Setup/MyAgentSetup.Table.al"))
    local app = vim.fn.json_decode(read(dest .. "/app.json"))
    eq(50149, app.idRanges[1].to)
    eq("// " .. app.id .. "\n", read(dest .. "/app/Setup/Ref.Codeunit.al"))
  end)

  it("generates app.json when the template asks for it", function()
    local list = P.list_templates(fake_ext())
    local dest = vim.fn.tempname()
    P.scaffold_template(list[2], dest,
      { name = "H", publisher = "P", id_from = 60000, rv = runtime("16.0") })
    local app = vim.fn.json_decode(read(dest .. "/app.json"))
    eq("16.0", app.runtime)
    eq(60000, app.idRanges[1].from)
    eq(nil, app.should)
  end)
end)
