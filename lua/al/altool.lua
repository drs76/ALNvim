-- Dotnet AL tool (`~/.dotnet/tools/al`) helpers beyond the LSP/MCP servers:
-- subcommand detection and a one-shot MCP client for tools the CLI does not
-- expose directly (e.g. al_downloadsymbols).
--
-- The tool is the primary extension-free toolchain: compile (`al compile`),
-- publish (`al publishapp`), symbols (MCP al_downloadsymbols), LSP
-- (launchlspserver), MCP (launchmcpserver). The VSCode extension remains only
-- for EditorServices LSP + the DAP debug adapter.

local M = {}
local platform = require("al.platform")

-- Resolve the `al` dotnet tool binary (~/.dotnet/tools/al[.exe]).
function M.binary()
  local base = vim.fn.expand("~/.dotnet/tools/al")
  return platform.is_windows and (base .. ".exe") or base
end

-- True when the binary exists and its --help lists `subcommand`.
-- Help output cached for the session (tool updates require a restart anyway).
local _help_cache = nil
function M.has(subcommand)
  if vim.fn.executable(M.binary()) == 0 then return false end
  if not _help_cache then
    _help_cache = vim.fn.system({ M.binary(), "--help" })
  end
  return _help_cache:find(subcommand, 1, true) ~= nil
end

-- One-shot MCP call: spawn `al launchmcpserver` for `root`, run the standard
-- initialize handshake, invoke `tool` with `args`, then kill the server.
-- MCP over stdio is newline-delimited JSON-RPC (no Content-Length framing).
--
-- cb(ok, text) is called on the main loop:
--   ok   — false on transport/tool error or result.isError
--   text — concatenated text content blocks, or an error message
-- opts.timeout_ms — default 600000 (symbol downloads can take minutes).
function M.mcp_call(root, tool, args, cb, opts)
  opts = opts or {}
  local bin = M.binary()
  if vim.fn.executable(bin) == 0 then
    vim.schedule(function() cb(false, "al binary not found at " .. bin) end)
    return
  end

  local job
  local carry    = ""
  local finished = false
  local timeout  = vim.uv.new_timer()

  local function finish(ok, text)
    if finished then return end
    finished = true
    timeout:stop()
    timeout:close()
    pcall(vim.fn.jobstop, job)
    vim.schedule(function() cb(ok, text) end)
  end

  local function send(msg)
    pcall(vim.fn.chansend, job, vim.fn.json_encode(msg) .. "\n")
  end

  local function handle(msg)
    if msg.id == 1 then
      -- initialize response → announce initialized, fire the tool call
      send({ jsonrpc = "2.0", method = "notifications/initialized" })
      send({ jsonrpc = "2.0", id = 2, method = "tools/call",
             params = { name = tool, arguments = args or vim.empty_dict() } })
    elseif msg.id == 2 then
      if msg.error then
        finish(false, msg.error.message or vim.fn.json_encode(msg.error))
        return
      end
      local res   = msg.result or {}
      local parts = {}
      for _, c in ipairs(res.content or {}) do
        if c.type == "text" and c.text then parts[#parts + 1] = c.text end
      end
      finish(res.isError ~= true, table.concat(parts, "\n"))
    end
  end

  job = vim.fn.jobstart(
    { bin, "launchmcpserver", "--transport", "stdio", "--disableTelemetry", root },
    {
      on_stdout = function(_, data)
        if finished then return end
        -- jobstart chunking: data[1] continues the previous partial line,
        -- data[#data] may itself be partial — carry it to the next callback.
        carry = carry .. (data[1] or "")
        for i = 2, #data do
          local line = carry
          carry = data[i]
          if line ~= "" then
            local ok, msg = pcall(vim.fn.json_decode, line)
            if ok and type(msg) == "table" then handle(msg) end
          end
        end
      end,
      on_exit = function(_, code)
        finish(false, "al launchmcpserver exited (code " .. code .. ") before responding")
      end,
    })

  if job <= 0 then
    finish(false, "failed to start al launchmcpserver")
    return
  end

  timeout:start(opts.timeout_ms or 600000, 0, vim.schedule_wrap(function()
    finish(false, "timed out waiting for " .. tool)
  end))

  send({ jsonrpc = "2.0", id = 1, method = "initialize", params = {
    protocolVersion = "2024-11-05",
    capabilities    = vim.empty_dict(),
    clientInfo      = { name = "ALNvim", version = "1.0" },
  } })
end

return M
