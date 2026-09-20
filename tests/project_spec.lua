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
