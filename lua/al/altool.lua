-- Dotnet AL tool (`~/.dotnet/tools/al`) helpers beyond the LSP/MCP servers:
-- subcommand detection and a one-shot MCP client for tools the CLI does not
-- expose directly (e.g. al_downloadsymbols).
--
-- The tool is THE toolchain: compile (`al compile`), publish (`al publishapp`),
-- symbols (MCP al_downloadsymbols — global and server), LSP (launchlspserver),
-- MCP (launchmcpserver). There is no fallback to the VS Code extension for any
-- of these: a missing tool is reported via M.missing_msg(), not papered over by
-- quietly running the extension's alc. The extension is used only for what the
-- tool cannot do yet — EditorServices (formatting) and the DAP adapter
-- (interactive debugging; the MCP server has no breakpoint/step tools).

local M = {}
local platform = require("al.platform")

local PACKAGE = "microsoft.dynamics.businesscentral.development.tools"

-- Where `dotnet tool install -g` may have put the binary, most specific first.
--
-- `~` alone is not enough on Windows. The installer always writes under
-- %USERPROFILE%\.dotnet\tools, but Neovim expands `~` from $HOME — and a
-- corporate machine commonly sets HOME to a network drive. The tool is then
-- installed and on PATH, yet ~/.dotnet/tools/al.exe does not exist, and every
-- caller used to conclude "not installed" and fall back to the VS Code
-- extension's alc and DAP adapter.
local function candidates()
  local exe  = platform.is_windows and "al.exe" or "al"
  local out  = { vim.fn.expand("~") .. "/.dotnet/tools/" .. exe }
  local prof = vim.env.USERPROFILE
  if platform.is_windows and prof and prof ~= "" then
    out[#out + 1] = prof .. "/.dotnet/tools/" .. exe
  end
  -- Last: whatever `al` is on PATH. The installer adds the tools dir to PATH,
  -- so this also covers a custom --tool-path the user put there themselves.
  local on_path = vim.fn.exepath("al")
  if on_path ~= "" then out[#out + 1] = on_path end
  return out
end

-- Resolve the `al` dotnet tool binary. Returns the first candidate that is
-- executable, else the default location — so error messages can still name
-- the path that was expected. The one resolver: compile, publish, symbols, MCP
-- and the agentic LSP all spawn whatever this returns.
function M.binary()
  local list = candidates()
  for _, p in ipairs(list) do
    if vim.fn.executable(p) == 1 then return p end
  end
  return list[1]
end

function M.available()
  return vim.fn.executable(M.binary()) == 1
end

-- The one message for "the dotnet tool is needed and missing". ALNvim does not
-- fall back to the VS Code extension for tool operations, so this has to say
-- exactly where it looked and how to fix it.
function M.missing_msg(what)
  return ("AL: %s needs the AL dotnet tool, which was not found.\n"
    .. "  Looked in: %s\n"
    .. "  Install:   :ALInstallDotnetTool\n"
    .. "  or:        dotnet tool install -g %s --prerelease")
    :format(what or "this", table.concat(candidates(), ", "), PACKAGE)
end

-- True when the binary exists and its --help lists `subcommand`.
-- Cached per resolved binary, so installing or updating the tool mid-session
-- (which M.reset() also clears) is picked up.
local _help = { bin = nil, text = nil }
function M.has(subcommand)
  local bin = M.binary()
  if vim.fn.executable(bin) == 0 then return false end
  if _help.bin ~= bin or not _help.text then
    _help.bin, _help.text = bin, vim.fn.system({ bin, "--help" })
  end
  return _help.text:find(subcommand, 1, true) ~= nil
end

-- Drop cached probes — call after installing or updating the tool.
function M.reset()
  _help.bin, _help.text = nil, nil
end

-- ── Connection settings from a launch.json configuration ────────────────────
--
-- `al publishapp` takes these as CLI flags, the MCP tools as JSON arguments.
-- Both are built from this one mapping so a launch configuration means the
-- same server to every operation.

-- launch.json authentication values → the tool's accepted set.
local AUTH_MAP = {
  MicrosoftEntraID = "AAD", AAD = "AAD",
  UserPassword = "UserPassword", NavUserPassword = "UserPassword",
  Windows = "Windows",
}

-- Normalised connection fields for `cfg`, using the MCP tools' argument names.
function M.connection(cfg)
  local conn = require("al.connection")
  local c = {}
  c.authentication = AUTH_MAP[cfg.authentication or ""]
  local tenant = cfg.primaryTenantDomain or cfg.tenant
  if tenant and tenant ~= "" and tenant ~= "default" then c.tenant = tenant end
  if conn.is_cloud(cfg) then
    c.environmentName = cfg.environmentName
    c.environmentType = cfg.environmentType
  else
    c.serverUrl      = cfg.server
    c.serverInstance = cfg.serverInstance
    c.port           = cfg.port and tonumber(cfg.port) or nil
  end
  return c
end

-- Environment for a tool process: the tool reads UserPassword credentials from
-- BC_SERVER_USERNAME / BC_SERVER_PASSWORD. Resolved the same way ALNvim always
-- has (launch.json fields → AL_BC_* env → session-cached prompt), so switching
-- to the tool does not change where credentials come from.
function M.cred_env(cfg)
  local auth = cfg.authentication or ""
  if auth == "UserPassword" or auth == "NavUserPassword" then
    local user, pass = require("al.connection").user_password(cfg)
    if user and user ~= "" then
      return { BC_SERVER_USERNAME = user, BC_SERVER_PASSWORD = pass or "" }
    end
  end
  return nil
end

-- The same fields as `al publishapp` / `al downloadsymbols` CLI flags.
function M.connection_flags(cfg)
  local c = M.connection(cfg)
  local out = {}
  for _, f in ipairs({
    { "--authentication",  c.authentication },
    { "--tenant",          c.tenant },
    { "--environmentname", c.environmentName },
    { "--environmenttype", c.environmentType },
    { "--server",          c.serverUrl },
    { "--serverinstance",  c.serverInstance },
    { "--port",            c.port and tostring(c.port) },
  }) do
    if f[2] then vim.list_extend(out, { f[1], f[2] }) end
  end
  return out
end

-- ── Running tool commands ───────────────────────────────────────────────────

-- jobstart (without stdout_buffered) delivers output in chunks where data[1]
-- continues the previous chunk's trailing partial line and data[#data] is itself
-- partial. Appending chunks verbatim splits a line in two, so a diagnostic
-- renders garbled and never matches the quickfix pattern.
--
-- Returns (feed, flush): feed(data) hands on_lines only complete lines; flush()
-- emits the final partial line and must be called from on_exit.
function M.line_stream(on_lines)
  local carry = ""
  local function feed(data)
    if not data then return end
    local out = {}
    carry = carry .. (data[1] or "")
    for i = 2, #data do
      out[#out + 1] = carry
      carry = data[i]
    end
    if #out > 0 then on_lines(out) end
  end
  local function flush()
    if carry ~= "" then
      local last = carry
      carry = ""
      on_lines({ last })
    end
  end
  return feed, flush
end

-- Centered output float. Returns (buf, win, log) — log(lines) appends and
-- follows the tail, and is a no-op once the user has closed the window.
function M.output_float(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local w   = math.min(100, math.max(60, vim.o.columns - 8))
  local h   = math.min(18, math.max(8, math.floor(vim.o.lines * 0.4)))
  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = w,
    height    = h,
    row       = math.floor((vim.o.lines - h) / 2),
    col       = math.floor((vim.o.columns - w) / 2),
    style     = "minimal",
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[win].wrap = true
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end
  local function log(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
  return buf, win, log
end

-- Run `al <args>` with its output streamed live into a float.
--
-- Live, not collected: publishapp and downloadsymbols can stop to print an
-- interactive sign-in instruction (device code / browser URL) for AAD, and a
-- user who cannot see it just watches a job that never finishes.
--
-- opts: title, cwd, env. on_exit(ok, code, log, win) runs on the main loop.
function M.run(args, opts, on_exit)
  opts = opts or {}
  local cmd = { M.binary() }
  vim.list_extend(cmd, args)
  local _, win, log = M.output_float(opts.title or "AL tool")
  log({ "$ al " .. table.concat(args, " "), "" })

  local function consume(lines)
    local clean = {}
    for _, l in ipairs(lines) do
      l = l:gsub("\r", "")
      if l ~= "" then clean[#clean + 1] = l end
    end
    if #clean > 0 then vim.schedule(function() log(clean) end) end
  end
  -- Separate carries: stdout and stderr interleave, and sharing one would glue
  -- a partial stdout line onto the start of a stderr one.
  local feed_out, flush_out = M.line_stream(consume)
  local feed_err, flush_err = M.line_stream(consume)

  local job = vim.fn.jobstart(cmd, {
    cwd = opts.cwd,
    env = opts.env,
    on_stdout = function(_, d) feed_out(d) end,
    on_stderr = function(_, d) feed_err(d) end,
    on_exit = function(_, code)
      flush_out(); flush_err()
      vim.schedule(function()
        if on_exit then on_exit(code == 0, code, log, win) end
      end)
    end,
  })
  if job <= 0 then
    log({ "Failed to start " .. cmd[1] })
    if on_exit then vim.schedule(function() on_exit(false, -1, log, win) end) end
  end
end

-- Close an output float after a successful run; a failed one stays open so
-- the error is readable.
function M.close_later(win, ms)
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, ms or 2500)
end

-- One-shot MCP call: spawn `al launchmcpserver` for `root`, run the standard
-- initialize handshake, invoke `tool` with `args`, then kill the server.
-- MCP over stdio is newline-delimited JSON-RPC (no Content-Length framing).
--
-- cb(ok, text) is called on the main loop:
--   ok   — false on transport/tool error or result.isError
--   text — concatenated text content blocks, or an error message
-- opts.timeout_ms — default 600000 (symbol downloads can take minutes).
-- opts.env        — extra environment for the server process (credentials; see
--                   M.cred_env). Never put secrets in `args`: those are echoed
--                   back in tool errors.
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
      env = opts.env,
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

-- Internals reached by tests only — never call from plugin code.
M._test = { candidates = candidates }

return M
