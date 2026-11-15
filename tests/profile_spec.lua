-- profile.lua — .alcpuprofile aggregation, frame → source resolution, proxy
-- response scraping.
--
-- The proxies' tool names come from tools/list on 30.0.42; their *stop*
-- response shapes are not verified live (bc2 was down), so the archive
-- extraction is tested on what the schema promises: base64 ZIP inline in a
-- JSON text block or a resource blob.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local P = require("al.profile")._test

-- Two frames under a root: Slow() self 300µs (samples 2,3 → 100+200),
-- Fast() self 50µs; root has no own samples. Slow is the parent of Fast, so
-- its total is 350.
local PROFILE = {
  nodes = {
    { id = 1, callFrame = { functionName = "(root)", url = "", lineNumber = 0 }, children = { 2 } },
    { id = 2, callFrame = { functionName = "Slow", url = "codeunit/50100/Slow.Codeunit.al", lineNumber = 12 },
      children = { 3 } },
    { id = 3, callFrame = { functionName = "Fast", url = "codeunit/50100/Slow.Codeunit.al", lineNumber = 40 } },
  },
  samples    = { 3, 2, 2 },
  timeDeltas = { 50, 100, 200 },
}

describe("profile.parse_cpuprofile", function()
  it("orders frames by self time and sums self + descendants into total", function()
    local rows = P.parse_cpuprofile(PROFILE)
    eq({ "Slow", "Fast", "(root)" }, { rows[1].name, rows[2].name, rows[3].name })
    eq({ 300, 350 }, { rows[1].self_us, rows[1].total_us })
    eq({ 50, 50 },   { rows[2].self_us, rows[2].total_us })
    eq({ 0, 350 },   { rows[3].self_us, rows[3].total_us })
  end)

  it("keeps url and line on the row for the jump", function()
    local rows = P.parse_cpuprofile(PROFILE)
    eq("codeunit/50100/Slow.Codeunit.al", rows[1].url)
    eq(12, rows[1].line)
  end)

  it("merges nodes that share a call frame", function()
    local p = vim.deepcopy(PROFILE)
    -- a second Slow node reached by another path
    table.insert(p.nodes, { id = 4, callFrame = p.nodes[2].callFrame })
    table.insert(p.nodes[1].children, 4)
    table.insert(p.samples, 4); table.insert(p.timeDeltas, 1000)
    local rows = P.parse_cpuprofile(p)
    eq({ "Slow", 1300, 2 }, { rows[1].name, rows[1].self_us, rows[1].hits })
    eq(3, #rows)
  end)

  it("accepts the JSON text of the file, with log noise before it", function()
    local rows = P.parse_cpuprofile("info: starting\n" .. vim.fn.json_encode(PROFILE))
    eq("Slow", rows[1].name)
  end)

  it("refuses something that is not a cpuprofile", function()
    local rows, err = P.parse_cpuprofile('{"hello": 1}')
    eq(nil, rows)
    ok(err:find("nodes", 1, true))
  end)

  it("builds the tree from parent links when children[] is absent", function()
    local rows = P.parse_cpuprofile({
      nodes = { { id = 1, callFrame = { functionName = "A" } },
                { id = 2, parent = 1, callFrame = { functionName = "B" } } },
      samples = { 2 }, timeDeltas = { 10 },
    })
    eq({ "B", 10, 10 }, { rows[1].name, rows[1].self_us, rows[1].total_us })
    eq({ "A", 0, 10 },  { rows[2].name, rows[2].self_us, rows[2].total_us })  -- parent: no self, B's total
  end)
end)

describe("profile.frame_location", function()
  it("reads kind and id out of an object-shaped url", function()
    local l = P.frame_location("Codeunit/50100/Slow.Codeunit.al", "Slow")
    eq({ "codeunit", 50100, "Slow.Codeunit.al" }, { l.kind, l.id, l.basename })
  end)

  it("takes a file URI as a path", function()
    local l = P.frame_location("file:///src/codeunit/X.Codeunit.al", "Codeunit 50100 X.Run")
    eq("/src/codeunit/X.Codeunit.al", l.path)
    eq("Run", l.member)
  end)

  it("strips an Object::\"Proc\" qualifier down to the member name", function()
    eq("Post", P.frame_location('', 'Codeunit::"Sales-Post"."Post"').member)
  end)

  it("reads a quoted object name", function()
    local l = P.frame_location('Page "Customer Card"', "OnOpenPage")
    eq({ "page", "Customer Card" }, { l.kind, l.name })
  end)
end)

describe("profile.find_field / json_in", function()
  it("finds a key case-insensitively at any depth", function()
    eq("abc", P.find_field({ result = { data = { ScheduleId = "abc" } } }, { "scheduleId" }))
  end)

  it("skips empty values and nulls", function()
    eq("x", P.find_field({ a = "", b = vim.NIL, c = { scheduleId = "x" } }, { "scheduleId" }))
  end)

  it("tolerates log lines before the JSON", function()
    eq({ id = 1 }, P.json_in("Connecting...\n{\"id\": 1}"))
    eq(nil, P.json_in("no json here"))
  end)
end)

-- One-entry zip holding a1.alcpuprofile (made with Python zipfile).
local ZIP_B64 = "UEsDBBQAAAAAAMEMb13MmTAvCAEAAAgBAAAPAAAAYTEuYWxjcHVwcm9maWxleyJub2RlcyI6IFt7ImlkIjogMSwgImNhbGxGcmFtZSI6IHsiZnVuY3Rpb25OYW1lIjogIihyb290KSIsICJ1cmwiOiAiIiwgImxpbmVOdW1iZXIiOiAwfSwgImNoaWxkcmVuIjogWzJdfSwgeyJpZCI6IDIsICJjYWxsRnJhbWUiOiB7ImZ1bmN0aW9uTmFtZSI6ICJPblJ1biIsICJ1cmwiOiAiY29kZXVuaXQvNTAxMDAvU2xvdy5Db2RldW5pdC5hbCIsICJsaW5lTnVtYmVyIjogMTJ9fV0sICJzYW1wbGVzIjogWzIsIDJdLCAidGltZURlbHRhcyI6IFsxMDAsIDIwMF19UEsBAhQDFAAAAAAAwQxvXcyZMC8IAQAACAEAAA8AAAAAAAAAAAAAAIABAAAAAGExLmFsY3B1cHJvZmlsZVBLBQYAAAAAAQABAD0AAAA1AQAAAAA="

describe("profile.extract_archives", function()
  it("finds a base64 zip inside the JSON of a text block", function()
    local res = { content = { { type = "text", text = vim.fn.json_encode({
      scheduleId = "s1", archive = { contentType = "application/zip", base64 = ZIP_B64 },
      profilesOverview = { activities = {} } }) } } }
    local list = P.extract_archives(res)
    eq(1, #list)
    eq("PK", list[1].bytes:sub(1, 2))
  end)

  it("takes a resource block's blob and remembers its uri", function()
    local res = { content = { { type = "resource",
      resource = { uri = "bc://profiles/1.zip", mimeType = "application/zip", blob = ZIP_B64 } } } }
    local list, uri = P.extract_archives(res)
    eq(1, #list)
    eq("bc://profiles/1.zip", uri)
  end)

  it("ignores base64-looking strings that are not zips, and reports a bare resourceUri", function()
    local res = { content = { { type = "text", text = vim.fn.json_encode({
      token = string.rep("QUJDRA", 20), resourceUri = "bc://profiles/big.zip" }) } } }
    local list, uri = P.extract_archives(res)
    eq(0, #list)
    eq("bc://profiles/big.zip", uri)
  end)
end)

local ONPREM = { authentication = "UserPassword", server = "http://bc2", serverInstance = "BC",
                 port = 7049, tenant = "default" }

describe("profile.proxy_args", function()
  it("uses the MCP service port, not the dev port, and the project's profile folder", function()
    local a = P.proxy_args("launchprofilingmcpproxy", ONPREM, "/p")
    eq("launchprofilingmcpproxy", a[1])
    ok(vim.tbl_contains(a, "7047"), "expected --port 7047, got " .. vim.inspect(a))
    ok(not vim.tbl_contains(a, "7049"), "dev port must not be passed to a proxy")
    ok(vim.tbl_contains(a, "--profilefolder"))
    ok(vim.tbl_contains(a, "/p/.profiles"))
  end)

  it("gives the snapshot proxy no profile folder", function()
    local a = P.proxy_args("launchsnapshotmcpproxy", ONPREM, "/p")
    ok(not vim.tbl_contains(a, "--profilefolder"))
  end)
end)

describe("profile.render_rows", function()
  it("renders one line per row after a three-line header", function()
    local lines = P.render_rows(P.parse_cpuprofile(PROFILE), "t")
    eq(6, #lines)
    ok(lines[4]:find("Slow", 1, true) and lines[4]:find("Slow.Codeunit.al:12", 1, true))
  end)
end)
