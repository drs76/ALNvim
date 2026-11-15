-- Test running through the AL dotnet tool (lua/al/tests.lua): the two output
-- parsers, the runtests argument builder and the web-client object URL.
--
-- The listtests fixture is the verbatim output of `al listtests --appfile` on a
-- two-codeunit test app, tool 30.0.42. The runtests fixture follows the
-- TestRunService formatter in the tool (Microsoft.Dynamics.Nav.LanguageModelTools
-- .dll, FormatResponse): "===== Codeunit N =====", "  PASS Name (Nms)", a
-- 7-space-indented error line under a FAIL, and the "Test run completed:"
-- totals — printed to stderr behind "Test run failed: " when anything failed.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local tests = require("al.tests")._test

local LISTTESTS = '{"appId":"4e65006f-39ad-4d40-a3b7-ca375609d74d","appName":"ALTest",'
  .. '"appPublisher":"Default publisher","appVersion":"1.0.0.0","codeunits":[{"id":50130,'
  .. '"name":"My Tests","namespace":"","methods":[{"name":"FailingTest","isDataDriven":false},'
  .. '{"name":"PassingTest","isDataDriven":false}]},{"id":50131,"name":"Other Tests",'
  .. '"namespace":"","methods":[{"name":"WithHandler","isDataDriven":false}]}]}'

describe("tests.parse_listtests", function()
  it("returns codeunits with id, name and method names", function()
    local list = tests.parse_listtests(LISTTESTS)
    eq({
      { codeunitId = 50130, name = "My Tests",    methods = { "FailingTest", "PassingTest" } },
      { codeunitId = 50131, name = "Other Tests", methods = { "WithHandler" } },
    }, list)
  end)

  it("skips log lines printed before the JSON document", function()
    local list = tests.parse_listtests("Resolving app...\nDone.\n" .. LISTTESTS)
    eq(2, #list)
    eq(50130, list[1].codeunitId)
  end)

  it("handles an app with no tests", function()
    eq({}, tests.parse_listtests('{"appId":"x","codeunits":[]}'))
  end)

  it("refuses output without JSON", function()
    local list, err = tests.parse_listtests("Test discovery failed: boom")
    eq(nil, list)
    ok(err:find("JSON"), err)
  end)
end)

local RAW = {
  "Running tests in codeunit 50130...",
  "MergeFromLaunchJson: Looking for launch.json in project: /p",
  "Targeting server 'http://bc2' and server instance 'BC'.",
  "Test run failed: ===== Codeunit 50130 =====",
  "Test run completed: 1 passed, 1 failed, 0 skipped.",
  "",
  "Results:",
  "  PASS PassingTest (12ms)",
  "  FAIL FailingTest (3ms)",
  "       deliberate failure",
  "",
  "===== Codeunit 50131 =====",
  "Test run completed: 0 passed, 0 failed, 1 skipped.",
  "",
  "Results:",
  "  SKIP WithHandler (0ms)",
  "",
  "Test run completed: 1 passed, 1 failed, 1 skipped.",
}

describe("tests.parse_runtests", function()
  it("collects every method result with its codeunit, status and duration", function()
    local r = tests.parse_runtests(RAW)
    eq({
      { codeunit = 50130, method = "PassingTest", status = "PASS", ms = 12 },
      { codeunit = 50130, method = "FailingTest", status = "FAIL", ms = 3, output = "deliberate failure" },
      { codeunit = 50131, method = "WithHandler", status = "SKIP", ms = 0 },
    }, r.results)
  end)

  it("takes the totals from the final summary line, not a per-codeunit one", function()
    local r = tests.parse_runtests(RAW)
    eq({ 1, 1, 1 }, { r.passed, r.failed, r.skipped })
  end)

  it("strips the stderr 'Test run failed:' prefix from the first summary line", function()
    local r = tests.parse_runtests({ "Test run failed: ===== Codeunit 7 =====",
                                     "Results:", "  FAIL X (1ms)" })
    eq(7, r.results[1].codeunit)
  end)

  it("ignores server log lines that are not results", function()
    local r = tests.parse_runtests({ "Running tests in codeunit 1...", "  some indented log",
                                     "Test run completed successfully." })
    eq({}, r.results)
  end)

  it("reads a quoted method name and a multi-line failure message", function()
    local r = tests.parse_runtests({ "===== Codeunit 1 =====", "Results:",
      '  FAIL "Posting Date" (5ms)', "       Expected 1", "       Actual 2" })
    eq('"Posting Date"', r.results[1].method)
    eq("Expected 1 Actual 2", r.results[1].output)
  end)
end)

local ONPREM = { authentication = "UserPassword", server = "http://bc2", serverInstance = "BC",
                 port = 14149, tenant = "default", environmentType = "OnPrem" }
local CLOUD  = { environmentType = "Sandbox", environmentName = "Dev",
                 tenant = "11111111-2222-3333-4444-555555555555", authentication = "MicrosoftEntraID" }

describe("tests.build_runtests_args", function()
  it("runs the codeunit raw against the project with on-prem connection flags", function()
    eq({ "runtests", "50130", "--project", "/p", "--raw",
         "--authentication", "UserPassword", "--server", "http://bc2",
         "--serverinstance", "BC", "--port", "14149" },
       tests.build_runtests_args("/p", 50130, nil, ONPREM))
  end)

  it("repeats --testmethods per method", function()
    local a = tests.build_runtests_args("/p", 50130, { "A", "B" }, nil)
    eq({ "runtests", "50130", "--project", "/p", "--raw",
         "--testmethods", "A", "--testmethods", "B" }, a)
  end)

  it("emits cloud flags and no --server for a cloud configuration", function()
    local a = tests.build_runtests_args("/p", 1, {}, CLOUD)
    ok(vim.tbl_contains(a, "--environmentname"), vim.inspect(a))
    ok(vim.tbl_contains(a, "Dev"), vim.inspect(a))
    ok(not vim.tbl_contains(a, "--server"), vim.inspect(a))
    ok(not vim.tbl_contains(a, "--serverinstance"), vim.inspect(a))
  end)
end)

describe("tests.object_url", function()
  it("opens a page on-prem with the tenant, replacing the startup object", function()
    local cfg = vim.tbl_extend("force", ONPREM, { startupObjectId = 22, startupObjectType = "Page" })
    eq("http://bc2/BC/WebClient/?page=50100&tenant=default", tests.object_url(cfg, "page", 50100))
  end)

  it("opens a report", function()
    eq("http://bc2/BC/WebClient/?report=50101&tenant=default", tests.object_url(ONPREM, "report", 50101))
  end)

  it("opens a table in the cloud web client without a tenant parameter", function()
    eq("https://businesscentral.dynamics.com/11111111-2222-3333-4444-555555555555/Dev/?table=18",
       tests.object_url(CLOUD, "table", 18))
  end)

  it("refuses object types the web client cannot open", function()
    local url, err = tests.object_url(ONPREM, "pageextension", 1)
    eq(nil, url)
    ok(err:find("pageextension"), err)
  end)
end)

describe("tests.parse_obj_header / test_method_at", function()
  it("reads kind, id and name from an object declaration", function()
    eq({ "codeunit", 50130, "My Tests" }, { tests.parse_obj_header('codeunit 50130 "My Tests"') })
    eq({ "page", 50100, "MyPage" },       { tests.parse_obj_header("page 50100 MyPage") })
  end)

  local SRC = {
    'codeunit 50130 "My Tests"',
    "{",
    "    Subtype = Test;",
    "",
    "    [Test]",
    "    [HandlerFunctions('MsgHandler')]",
    "    procedure WithHandler()",
    "    begin",
    "        Message('hi');",
    "    end;",
    "",
    "    procedure NotATest()",
    "    begin",
    "    end;",
    "}",
  }

  it("finds the [Test] procedure enclosing the cursor through other attributes", function()
    eq("WithHandler", tests.test_method_at(SRC, 9))
  end)

  it("refuses a procedure without [Test]", function()
    local name, err = tests.test_method_at(SRC, 13)
    eq(nil, name)
    ok(err:find("NotATest"), err)
  end)
end)
