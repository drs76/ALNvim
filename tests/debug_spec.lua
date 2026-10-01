-- On-prem debugging credentials.
--
-- On-prem :ALLaunch with UserPassword never worked: the adapter answered
-- "Could not publish the package to the server" (after "An internal error has
-- occurred") on Linux and Windows alike. It only ever received credentials via
-- al/saveUsernamePassword on the EditorServices language server. The adapter's
-- deployment code reads BC_SERVER_USERNAME / BC_SERVER_PASSWORD from its
-- environment — the same variables `al publishapp` uses — so they now go there.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local D        = require("al.debug")._test
local platform = require("al.platform")

local function has(env, entry)
  for _, e in ipairs(env or {}) do if e == entry then return true end end
  return false
end

local function count_prefix(env, prefix)
  local n = 0
  for _, e in ipairs(env or {}) do if e:sub(1, #prefix) == prefix then n = n + 1 end end
  return n
end

describe("debug.adapter_creds", function()
  it("maps UserPassword and NavUserPassword to the BC_SERVER_* variables", function()
    eq({ BC_SERVER_USERNAME = "admin", BC_SERVER_PASSWORD = "pw" },
      D.adapter_creds({ authentication = "UserPassword" }, "admin", "pw"))
    eq({ BC_SERVER_USERNAME = "admin", BC_SERVER_PASSWORD = "pw" },
      D.adapter_creds({ authentication = "NavUserPassword" }, "admin", "pw"))
  end)

  it("adds nothing for other auth types or a missing user", function()
    eq(nil, D.adapter_creds({ authentication = "MicrosoftEntraID" }, "admin", "pw"))
    eq(nil, D.adapter_creds({ authentication = "Windows" }, "admin", "pw"))
    eq(nil, D.adapter_creds({ authentication = "UserPassword" }, "", "pw"))
  end)
end)

describe("debug adapter environment", function()
  local creds = { BC_SERVER_USERNAME = "admin", BC_SERVER_PASSWORD = "pw" }

  it("carries the credentials on Linux/macOS", function()
    local saved = platform.is_windows
    platform.is_windows = false
    local env = D.make_adapter_env(creds)
    platform.is_windows = saved
    ok(has(env, "BC_SERVER_USERNAME=admin"), vim.inspect(env))
    ok(has(env, "BC_SERVER_PASSWORD=pw"))
    ok(count_prefix(env, "PATH=") == 1, "the minimal environment must still be there")
  end)

  it("adds nothing when there are no credentials", function()
    local saved = platform.is_windows
    platform.is_windows = false
    local env = D.make_adapter_env(nil)
    platform.is_windows = saved
    eq(0, count_prefix(env, "BC_SERVER_"))
  end)

  it("on Windows, inherits the full environment plus the credentials", function()
    -- nil means "inherit" and is what Windows gets without credentials; a
    -- table replaces the whole environment, so it must carry everything.
    local saved, saved_user = platform.is_windows, vim.env.BC_SERVER_USERNAME
    platform.is_windows = true
    vim.env.BC_SERVER_USERNAME = "stale"     -- an inherited value must not win
    local without = D.make_adapter_env(nil)
    local env     = D.make_adapter_env(creds)
    platform.is_windows = saved
    vim.env.BC_SERVER_USERNAME = saved_user

    eq(nil, without)
    ok(has(env, "BC_SERVER_USERNAME=admin"), "credentials missing")
    eq(1, count_prefix(env, "BC_SERVER_USERNAME="))
    ok(count_prefix(env, "PATH=") == 1 or count_prefix(env, "Path=") == 1,
      "inherited environment missing")
  end)
end)

-- One fake nvim-dap for the whole file, like the single real module in a
-- Neovim session: debug.lua registers its event listeners once per session,
-- so a fresh fake per test would leave every test after the first with none.
local function auto() return setmetatable({}, { __index = function(t, k)
  local v = {}; rawset(t, k, v); return v end }) end
local FAKE_DAP = {
  listeners = { before = auto(), after = auto() },
  session = function() return nil end,
}

-- Run debug.launch() for an on-prem UserPassword config against a fake
-- nvim-dap that records the adapter and launch request instead of spawning
-- anything. Returns the fake dap and the request dap.run received.
-- `extra` overrides launch.json fields.
local function launch_with_fake_dap(extra)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.vscode", "p")
  vim.fn.writefile({ vim.fn.json_encode({ name = "T", publisher = "P", version = "1.0.0.0" }) },
    root .. "/app.json")
  local cfg = vim.tbl_extend("force", {
    name = "onprem", type = "al", request = "launch", environmentType = "OnPrem",
    server = "http://bc", port = 7049, serverInstance = "BC", authentication = "UserPassword",
  }, extra or {})
  vim.fn.writefile({ vim.fn.json_encode({ version = "0.2.0", configurations = { cfg } }) },
    root .. "/.vscode/launch.json")

  local ran
  local fake = FAKE_DAP
  fake.adapters, fake.configurations = {}, {}
  fake.run = function(c) ran = c end

  local saved = {
    dap = package.loaded["dap"], compile = require("al.compile").compile,
    find_app = require("al.publish").find_app, host = require("al.ext").host_cmd,
    notify = vim.notify, win = platform.is_windows,
    user = vim.env.AL_BC_USERNAME, pass = vim.env.AL_BC_PASSWORD,
  }
  package.loaded["dap"]           = fake
  require("al.compile").compile   = function(_, _, cb) cb() end
  require("al.publish").find_app  = function() return root .. "/P_T_1.0.0.0.app" end
  require("al.ext").host_cmd      = function() return { "dotnet", "/x/Host.dll" } end
  vim.notify                      = function() end
  platform.is_windows             = false
  -- Credentials from the environment, not launch.json: the launch request
  -- must not acquire them, only the adapter's environment.
  require("al.connection").clear_credentials()
  vim.env.AL_BC_USERNAME, vim.env.AL_BC_PASSWORD = "admin", "pw"

  local okc, err = pcall(require("al.debug").launch, root)

  package.loaded["dap"]           = saved.dap
  require("al.compile").compile   = saved.compile
  require("al.publish").find_app  = saved.find_app
  require("al.ext").host_cmd      = saved.host
  vim.notify                      = saved.notify
  platform.is_windows             = saved.win
  vim.env.AL_BC_USERNAME, vim.env.AL_BC_PASSWORD = saved.user, saved.pass
  require("al.connection").clear_credentials()
  if not okc then error(err, 0) end
  return fake, ran
end

-- Fire the adapter's events at the listeners debug.launch() registered, with
-- open_url recorded. Deferred callbacks (the 5s fallback) run after all the
-- events, the way real time orders them: al/openUri arrives about half a
-- second after the publish. Returns the URLs opened, in order.
local function fire(fake, events)
  local opened = {}
  local orig_open, orig_defer, orig_notify = platform.open_url, vim.defer_fn, vim.notify
  local orig_win = platform.is_windows
  platform.open_url = function(url) opened[#opened + 1] = url end
  local deferred = {}
  vim.defer_fn      = function(f) deferred[#deferred + 1] = f end
  vim.notify        = function() end
  platform.is_windows = false
  local okc, err = pcall(function()
    for _, ev in ipairs(events) do
      for _, fn in pairs(fake.listeners.before[ev.name]) do fn(nil, ev.body or {}) end
    end
    for _, f in ipairs(deferred) do f() end
  end)
  platform.open_url, vim.defer_fn, vim.notify = orig_open, orig_defer, orig_notify
  platform.is_windows = orig_win
  if not okc then error(err, 0) end
  return opened
end

local URI = "http://bc:14180/BC/?page=22&debuggingcontext=CTX"

describe(":ALLaunch on-prem", function()
  it("starts the adapter with the UserPassword credentials in its environment", function()
    local fake, ran = launch_with_fake_dap({ launchBrowser = false })
    ok(ran, "dap.run was never called")
    local env = fake.adapters.al and fake.adapters.al.options.env
    ok(has(env, "BC_SERVER_USERNAME=admin"), "adapter env lacks the user: " .. vim.inspect(env))
    ok(has(env, "BC_SERVER_PASSWORD=pw"), "adapter env lacks the password")
    eq(nil, ran.userName, "ALNvim must not add credentials to the launch request")
    eq(nil, ran.password)
  end)

  it("opens the adapter's debugging-context URL once, not the fallback too", function()
    -- Regression, twice over: the fallback listener opened a second tab on the
    -- wrong port with no debug context; and once the flags were added, they
    -- were declared below the listener that used them — so they were globals
    -- there, the debugging-context URL never opened, and only the fallback did.
    -- A browser session without the debugging context never hits a breakpoint.
    local fake = launch_with_fake_dap({ launchBrowser = true })
    eq({ URI }, fire(fake, {
      { name = "event_al/refreshExplorerObjects" },
      { name = "event_al/openUri", body = { uri = URI } },
    }))
    eq(nil, rawget(_G, "_want_browser"), "browser flag leaked as a global")
    eq(nil, rawget(_G, "_uri_opened"),   "browser flag leaked as a global")
  end)

  it("falls back to the web client URL only when the adapter sends none", function()
    local fake = launch_with_fake_dap({ launchBrowser = true })
    local opened = fire(fake, { { name = "event_al/refreshExplorerObjects" } })
    eq(1, #opened)
    ok(opened[1]:find("WebClient", 1, true), "expected the fallback URL, got " .. vim.inspect(opened))
  end)

  it("opens nothing when launch.json says launchBrowser = false", function()
    local fake = launch_with_fake_dap({ launchBrowser = false })
    eq({}, fire(fake, {
      { name = "event_al/refreshExplorerObjects" },
      { name = "event_al/openUri", body = { uri = URI } },
    }))
    -- And the fallback alone: no al/openUri arrives to suppress it.
    fake = launch_with_fake_dap({ launchBrowser = false })
    eq({}, fire(fake, { { name = "event_al/refreshExplorerObjects" } }))
  end)
end)
