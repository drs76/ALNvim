-- The tool's language server reads .alpackages once, at startup. A package
-- downloaded or replaced later stayed invisible (a dependency's new table was
-- "missing" in Neovim while VS Code offered it), so ALNvim restarts the client.

local T = require("tests.harness")
local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local A = require("al.agentic_lsp")

-- Fake vim.lsp clients for one test; returns the list of M.start calls.
local function with_clients(clients, fn)
  local orig_get, orig_start = vim.lsp.get_clients, A.start
  local starts = {}
  vim.lsp.get_clients = function(f)
    return vim.tbl_filter(function(c) return not f or not f.name or c.name == f.name end, clients)
  end
  A.start = function(b, r) starts[#starts + 1] = { b, r } end
  local okk, err = pcall(fn, starts)
  vim.lsp.get_clients, A.start = orig_get, orig_start
  if not okk then error(err, 0) end
end

local function client(root, bufs)
  local c = { name = "al_agentic_lsp", root_dir = root, attached_buffers = {}, stopped = false,
              rpc = { handle = { get_pid = function() return nil end } } }
  for _, b in ipairs(bufs) do c.attached_buffers[b] = true end
  function c:stop() self.stopped = true end
  function c:is_stopped() return self.stopped end
  return c
end

describe("agentic_lsp.restart", function()
  it("stops the root's client and starts a fresh one on its buffers", function()
    local b = vim.api.nvim_create_buf(true, false)
    vim.fn.bufload(b)
    local mine, other = client("/p/app", { b }), client("/p/other", { b })
    with_clients({ mine, other }, function(starts)
      eq(true, A.restart("/p/app/", "test"))       -- trailing slash: same root
      eq(true, mine.stopped)
      eq(false, other.stopped)
      vim.wait(2000, function() return #starts > 0 end)
      eq({ { b, "/p/app/" } }, starts)
    end)
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("waits until the old client has stopped before starting", function()
    local b = vim.api.nvim_create_buf(true, false)
    vim.fn.bufload(b)
    local c = client("/p/app", { b })
    function c:stop() end                      -- still shutting down
    with_clients({ c }, function(starts)
      A.restart("/p/app", "test")
      vim.wait(400)
      eq(0, #starts)
      c.stopped = true
      vim.wait(1000, function() return #starts > 0 end)
      eq(1, #starts)
    end)
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("returns false when nothing runs for the root", function()
    with_clients({ client("/p/other", {}) }, function(starts)
      eq(false, A.restart("/p/app", "test"))
      eq(0, #starts)
    end)
  end)
end)

describe("symbol download reloads the language server", function()
  it("restarts once after a successful download and keeps the watcher quiet meanwhile", function()
    local altool = require("al.altool")
    local saved = { available = altool.available, has = altool.has, run = altool.run,
                    close_later = altool.close_later, restart = A.restart }
    local finish_run, restarts, suspended_during = nil, {}, nil
    altool.available = function() return true end
    altool.has = function(s) return s == "downloadsymbols" end
    altool.close_later = function() end
    altool.run = function(_, _, cb)
      suspended_during = A.suspended["/p/app"]
      finish_run = cb
    end
    A.restart = function(root, why) restarts[#restarts + 1] = { root, why } end
    local okk, err = pcall(function()
      require("al.symbols").download_global("/p/app")
      eq(true, suspended_during)
      eq(0, #restarts)
      finish_run(true, 0, function() end, nil)
      eq({ { "/p/app", "symbols downloaded" } }, restarts)
      eq(nil, A.suspended["/p/app"])
      -- a failed download leaves the server alone
      require("al.symbols").download_global("/p/app")
      finish_run(false, 1, function() end, nil)
      eq(1, #restarts)
      eq(nil, A.suspended["/p/app"])
    end)
    for k, v in pairs(saved) do if k == "restart" then A.restart = v else altool[k] = v end end
    if not okk then error(err, 0) end
  end)
end)

describe("agentic_lsp.watch_packages", function()
  it("restarts after a .app in the cache changes, debounced", function()
    local root = vim.fn.tempname()
    local cache = root .. "/.alpackages"
    vim.fn.mkdir(cache, "p")
    local saved_restart, saved_ms = A.restart, A.RELOAD_DEBOUNCE_MS
    local restarts = 0
    A.restart = function() restarts = restarts + 1 end
    A.RELOAD_DEBOUNCE_MS = 200
    local okk, err = pcall(function()
      A.watch_packages(root, cache)
      ok(A.watchers[root], "no watcher")
      vim.fn.writefile({ "x" }, cache .. "/notes.txt")          -- not a package
      vim.wait(500)
      eq(0, restarts)
      vim.fn.writefile({ "a" }, cache .. "/A_B_1.0.0.0.app")
      vim.fn.writefile({ "b" }, cache .. "/C_D_1.0.0.0.app")
      vim.wait(1500, function() return restarts > 0 end)
      vim.wait(300)
      eq(1, restarts)
    end)
    A.restart, A.RELOAD_DEBOUNCE_MS = saved_restart, saved_ms
    if A.watchers[root] then A.watchers[root]:close(); A.watchers[root] = nil end
    if not okk then error(err, 0) end
  end)
end)
