-- ids.lua — free object IDs across idRanges.
--
-- free_ids walks every range in app.json order and skips IDs already used in
-- the project. Two ranges with gaps in both is the case the wizard and
-- completion depend on: the first free ID is not range1.from when that is
-- taken, and range2 is still offered once range1 is exhausted.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok
local free_ids = require("al.ids")._test.free_ids
local obj_type_from_line = require("al.ids")._test.obj_type_from_line

local function ids(results)
  local out = {}
  for _, r in ipairs(results) do out[#out + 1] = r.id end
  return out
end

describe("ids.free_ids", function()
  local ranges = { { from = 50100, to = 50102 }, { from = 70000, to = 70002 } }

  it("skips used IDs and spans both ranges", function()
    local used = { [50100] = true, [50102] = true, [70001] = true }
    eq({ 50101, 70000, 70002 }, ids(free_ids(ranges, used, 5, "")))
  end)

  it("caps the count per range, not overall", function()
    eq({ 50100, 50101, 70000, 70001 }, ids(free_ids(ranges, {}, 2, "")))
  end)

  it("reports usage per range in the menu label", function()
    local used = { [50100] = true, [50102] = true }
    local r = free_ids(ranges, used, 5, "")
    eq("[50100-50102 · 2 used]", r[1].menu)
    eq("[70000-70002 · 0 used]", r[2].menu)
  end)

  it("filters by the typed prefix", function()
    eq({ 70000, 70001, 70002 }, ids(free_ids(ranges, {}, 5, "70")))
  end)

  it("returns nothing when every ID is taken", function()
    local used = {}
    for id = 50100, 50102 do used[id] = true end
    for id = 70000, 70002 do used[id] = true end
    eq({}, ids(free_ids(ranges, used, 5, "")))
  end)
end)

describe("ids.obj_type_from_line", function()
  it("reads the object type keyword", function()
    eq("tableextension", obj_type_from_line("tableextension 50100 "))
    eq("codeunit", obj_type_from_line("  codeunit 5"))
  end)
  it("ignores types without IDs", function()
    ok(not obj_type_from_line("interface IFoo"))
    ok(not obj_type_from_line("var"))
  end)
end)
