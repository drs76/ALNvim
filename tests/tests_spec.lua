-- Test running through the AL dotnet tool (lua/al/tests.lua): the two output
-- parsers, the runtests argument builder and the web-client object URL.
--
-- The listtests fixture is the verbatim output of `al listtests --appfile` on a
-- two-codeunit test app, tool 30.0.42. The runtests fixtures are verbatim
-- `al runtests --raw` output from that app published to BC 28.5 (pcp-dev2).

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

-- Verbatim `al runtests 50130 --raw` against BC 28.5 (pcp-dev2): everything
-- after the SignalR line arrived on stderr behind "Test run failed: ". The
-- error text keeps its \r, the callstack lines are not indented, and the
-- codeunit itself appears as a nameless FAIL that the tool counts.
local RAW = {
  "Running tests in codeunit 50130...",
  "Targeting server 'http://192.168.0.191', server instance 'BC' and tenant 'default'.",
  "Test hub connected.",
  "SignalR hub connection established with context [TKgp_xttVWtezRjt-wnptA]",
  "Test run failed: ===== Codeunit 50130 =====",
  "Test run completed: 1 passed, 2 failed, 0 skipped.",
  "",
  "Results:",
  "  PASS PassingTest (14ms)",
  "  FAIL FailingTest (26ms)",
  "       deliberate failure\r",
  "AL Callstack:\r",
  '"My Tests"(CodeUnit 50130).FailingTest line 2 - ALTest by Default publisher version 1.0.0.0',
  "  FAIL  (40ms)",
  "       deliberate failure\r",
  "AL Callstack:\r",
  '"My Tests"(CodeUnit 50130).FailingTest line 2 - ALTest by Default publisher version 1.0.0.0',
  "",
  "Test run completed: 1 passed, 2 failed, 0 skipped.",
}

-- `al runtests 50131 --raw --testmethods WithHandler`, all on stdout, exit 0.
local RAW_OK = {
  "SignalR hub connection established with context [-TYPCDq8URVlg6wmYg6PkA]",
  "===== Codeunit 50131 =====",
  "Test run completed: 2 passed, 0 failed, 0 skipped.",
  "",
  "Results:",
  "  PASS WithHandler (10ms)",
  "  PASS  (10ms)",
  "",
  "Test run completed: 2 passed, 0 failed, 0 skipped.",
}

describe("tests.parse_runtests", function()
  it("collects each method result with codeunit, status and duration, dropping the codeunit phantom", function()
    local r = tests.parse_runtests(RAW)
    eq(2, #r.results)
    eq({ codeunit = 50130, method = "PassingTest", status = "PASS", ms = 14 }, r.results[1])
    eq({ 50130, "FailingTest", "FAIL", 26 },
       { r.results[2].codeunit, r.results[2].method, r.results[2].status, r.results[2].ms })
  end)

  it("keeps the error text and the unindented callstack as the failure output, \\r stripped", function()
    local out = tests.parse_runtests(RAW).results[2].output
    eq('deliberate failure AL Callstack: "My Tests"(CodeUnit 50130).FailingTest line 2'
       .. ' - ALTest by Default publisher version 1.0.0.0', out)
  end)

  it("counts methods, not the tool's totals (which include the phantom)", function()
    local r = tests.parse_runtests(RAW)
    eq({ 1, 1, 0 }, { r.passed, r.failed, r.skipped })
    local o = tests.parse_runtests(RAW_OK)
    eq({ 1, 0, 0 }, { o.passed, o.failed, o.skipped })
    eq("WithHandler", o.results[1].method)
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
    eq(0, r.failed)
  end)

  it("reads a quoted method name and does not attach output to a PASS", function()
    local r = tests.parse_runtests({ "===== Codeunit 1 =====", "Results:",
      '  FAIL "Posting Date" (5ms)', "       Expected 1", "  PASS Other (1ms)", "stray log" })
    eq('"Posting Date"', r.results[1].method)
    eq("Expected 1", r.results[1].output)
    eq(nil, r.results[2].output)
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
