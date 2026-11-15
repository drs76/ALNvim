-- CPU profiling and snapshot capture through the AL tool's MCP proxies
-- (tool 30+): `al launchprofilingmcpproxy` and `al launchsnapshotmcpproxy`.
--
--   :ALProfileCapture   arm a profiling schedule on a BC session id
--   :ALProfileCollect   stop it, save the .alcpuprofile archive, open the viewer
--   :ALProfileOpen      viewer for a .alcpuprofile (hot functions, <CR> jumps)
--   :ALSnapshotCapture  arm snapshot debugging (proxy route)
--   :ALSnapshotCollect  stop it, save the archive + summary under .snapshots
--
-- Both proxies are two-phase by design: the arm call collects nothing, the
-- user reproduces the slow/failing scenario in the BC client, and the stop
-- call returns what was captured. So each surfaces as a command pair, with the
-- armed state kept in M._profile / M._snapshot for the collect call. Every call
-- is a one-shot altool.mcp_call_server: a fresh proxy process per call, so the
-- state that matters (scheduleId / debuggingContext) is BC's, not the proxy's.
--
-- Tool names were discovered with tools/list on 30.0.42 (fixtured in the side
-- session notes as phase2b-*-tools-list.json); there is no list-sessions tool,
-- so the session id is prompted for. The response shapes of the stop calls are
-- NOT verified live (bc2 was down): the archive is found by scanning the
-- result for base64 whose decoded bytes start with the ZIP magic "PK", in a
-- `resource` block's blob or any string inside the JSON text block.
--
-- .alcpuprofile is Chromium / V8 DevTools "Profile" v1 JSON:
--   nodes[]      { id, callFrame { functionName, url, lineNumber, columnNumber },
--                  children[] }
--   samples[]    node id sampled at each tick
--   timeDeltas[] µs since the previous sample
-- parse_cpuprofile aggregates self (own samples) and total (self + descendants)
-- time per call frame.

local M = {}

local altool   = require("al.altool")
local lsp      = require("al.lsp")
local conn     = require("al.connection")
local platform = require("al.platform")

M._profile  = nil   -- { root, cfg, session, schedule_id }
M._snapshot = nil   -- { root, cfg, context, host_id }

local PROFILING = "launchprofilingmcpproxy"
local SNAPSHOT  = "launchsnapshotmcpproxy"

-- ── Pure helpers ────────────────────────────────────────────────────────────

-- Chrome cpuprofile (table or JSON string) → rows sorted by self time:
--   { name, url, line, self_us, total_us, hits }
-- Nodes sharing a call frame (same function reached by different paths) are
-- merged. timeDeltas[i] is attributed to samples[i]; a profile without
-- timeDeltas counts each sample as one µs so ordering still holds.
local function parse_cpuprofile(data)
  if type(data) == "string" then
    local s = data:find("{", 1, true)
    if not s then return nil, "not a cpuprofile: no JSON object" end
    local ok, dec = pcall(vim.fn.json_decode, data:sub(s))
    if not ok or type(dec) ~= "table" then return nil, "not a cpuprofile: invalid JSON" end
    data = dec
  end
  if type(data) ~= "table" then return nil, "not a cpuprofile" end
  if type(data.nodes) ~= "table" and type(data.profile) == "table" then data = data.profile end
  if type(data.nodes) ~= "table" then return nil, "not a cpuprofile: no nodes[]" end

  local nodes, children = {}, {}
  for _, n in ipairs(data.nodes) do
    nodes[n.id] = n
    children[n.id] = n.children or {}
  end
  -- Some writers give parent instead of children.
  for _, n in ipairs(data.nodes) do
    if n.parent and nodes[n.parent] and not vim.tbl_contains(children[n.parent], n.id) then
      table.insert(children[n.parent], n.id)
    end
  end

  local self_us = {}
  local deltas  = data.timeDeltas or {}
  for i, id in ipairs(data.samples or {}) do
    local d = deltas[i]
    if d == nil then d = 1 end
    self_us[id] = (self_us[id] or 0) + d
  end

  local total_us = {}
  local function total(id, seen)
    if total_us[id] then return total_us[id] end
    if seen[id] then return 0 end
    seen[id] = true
    local t = self_us[id] or 0
    for _, c in ipairs(children[id] or {}) do t = t + total(c, seen) end
    total_us[id] = t
    return t
  end
  for id in pairs(nodes) do total(id, {}) end

  local rows, by_key = {}, {}
  for id, n in pairs(nodes) do
    local cf   = n.callFrame or {}
    local name = cf.functionName or ""
    local url  = cf.url or ""
    local line = tonumber(cf.lineNumber)
    local key  = name .. "\0" .. url .. "\0" .. tostring(line)
    local row  = by_key[key]
    if not row then
      row = { name = name, url = url, line = line, self_us = 0, total_us = 0, hits = 0 }
      by_key[key] = row
      rows[#rows + 1] = row
    end
    row.self_us  = row.self_us + (self_us[id] or 0)
    row.total_us = row.total_us + (total_us[id] or 0)
    row.hits     = row.hits + 1
  end
  table.sort(rows, function(a, b)
    if a.self_us ~= b.self_us then return a.self_us > b.self_us end
    if a.total_us ~= b.total_us then return a.total_us > b.total_us end
    return a.name < b.name
  end)
  return rows
end

-- Where a call frame points. The url of an AL frame is not documented; this
-- recognises the three shapes it could take and lets the caller try each:
--   path   — a file:// URI or a path ending in .al → open it (by basename when
--            it is not readable here: the server's path is not ours)
--   kind+id / kind+name — "codeunit 50100", "Codeunit/50100/…", 'Page "Foo"'
--   member — the procedure to land on inside the object (functionName with
--            any Object::/Object. qualifier removed)
local function frame_location(url, name)
  url  = url or ""
  name = name or ""
  local loc = { member = name:match("[^%.:]+$") or name }
  loc.member = loc.member:gsub('^"(.-)"$', "%1")
  local path = url:gsub("^file://", "")
  if path:lower():match("%.al$") then
    loc.path = path
    loc.basename = vim.fn.fnamemodify(path, ":t")
  end
  -- Lua patterns have no alternation: try each kind, longest first so
  -- "tableextension" is not read as "table".
  local kind, rest
  local low = url:lower()
  for _, k in ipairs({ "tableextension", "pageextension", "reportextension", "enumextension",
                       "table", "page", "codeunit", "report", "query", "xmlport", "enum" }) do
    local r = low:match("%f[%a]" .. k .. "[%s/_:%-]+(.*)")
    if r then kind, rest = k, r; break end
  end
  if kind then
    loc.kind = kind
    local id = rest:match("^(%d+)")
    if id then loc.id = tonumber(id) end
    local qn = url:match('"([^"]+)"')
    if qn then loc.name = qn end
  end
  if not loc.path and not loc.kind and url ~= "" then loc.basename = vim.fn.fnamemodify(url, ":t") end
  return loc
end

-- First JSON object in `text` → table, or nil. Tolerates log lines before it.
local function json_in(text)
  if type(text) ~= "string" then return nil end
  local s = text:find("{", 1, true)
  if not s then return nil end
  local ok, dec = pcall(vim.fn.json_decode, text:sub(s))
  if ok and type(dec) == "table" then return dec end
  return nil
end

-- Depth-first search of `t` for the first key whose lower-cased name is in
-- `names`; returns its value. Response field names are not documented, so the
-- callers ask for every plausible spelling at once.
local function find_field(t, names, depth)
  depth = depth or 0
  if type(t) ~= "table" or depth > 8 then return nil end
  local want = {}
  for _, n in ipairs(names) do want[n:lower()] = true end
  for k, v in pairs(t) do
    if type(k) == "string" and want[k:lower()] and v ~= vim.NIL and v ~= "" then return v end
  end
  for _, v in pairs(t) do
    local r = find_field(v, names, depth + 1)
    if r ~= nil then return r end
  end
  return nil
end

-- Base64 of a ZIP archive? Decodes and checks the "PK" magic. Whitespace in
-- the encoding is tolerated.
local function zip_bytes(s)
  if type(s) ~= "string" or #s < 32 then return nil end
  local clean = s:gsub("%s", "")
  if not clean:match("^[A-Za-z0-9+/]+=?=?$") then return nil end
  local ok, bytes = pcall(vim.base64.decode, clean)
  if ok and type(bytes) == "string" and bytes:sub(1, 2) == "PK" then return bytes end
  return nil
end

-- Every ZIP archive carried inline in a tools/call result: `resource` blocks
-- with a blob, and any string anywhere in the JSON of a text block. Returns a
-- list of { bytes, name } plus the first resource URI seen (an archive too
-- large to inline is referenced instead of embedded).
local function extract_archives(result)
  local out, uri = {}, nil
  local function scan(v, depth)
    if depth > 8 then return end
    if type(v) == "string" then
      local b = zip_bytes(v)
      if b then out[#out + 1] = { bytes = b } end
    elseif type(v) == "table" then
      for k, x in pairs(v) do
        if type(k) == "string" and k:lower():match("uri$") and type(x) == "string" and not uri then
          uri = x
        end
        scan(x, depth + 1)
      end
    end
  end
  for _, c in ipairs((result or {}).content or {}) do
    if c.type == "resource" and type(c.resource) == "table" then
      local b = zip_bytes(c.resource.blob)
      if b then out[#out + 1] = { bytes = b, name = c.resource.uri } end
      if c.resource.uri and not uri then uri = c.resource.uri end
    elseif c.type == "text" then
      local j = json_in(c.text)
      if j then scan(j, 0) else
        local b = zip_bytes(c.text)
        if b then out[#out + 1] = { bytes = b } end
      end
    end
  end
  return out, uri
end

local function timestamp()
  return os.date("%Y%m%d-%H%M%S")
end

local function fmt_ms(us)
  return string.format("%9.1f", (us or 0) / 1000)
end

-- Viewer lines for rows. Header first; one row per frame.
local function render_rows(rows, title)
  local lines = {
    title,
    string.format("%9s  %9s  %5s  %s", "self ms", "total ms", "hits", "function  —  url:line"),
    string.rep("─", 72),
  }
  for _, r in ipairs(rows) do
    local where = r.url ~= "" and (r.url .. (r.line and (":" .. r.line) or "")) or ""
    lines[#lines + 1] = string.format("%s  %s  %5d  %s%s", fmt_ms(r.self_us), fmt_ms(r.total_us),
      r.hits, r.name ~= "" and r.name or "(anonymous)", where ~= "" and ("  —  " .. where) or "")
  end
  return lines
end

-- ── Proxy plumbing ──────────────────────────────────────────────────────────

-- Tool 30+ guard: notify and return false when `subcommand` is missing.
local function need(subcommand, what)
  if not altool.available() then
    vim.notify(altool.missing_msg(what), vim.log.levels.ERROR)
    return false
  end
  if not altool.has(subcommand) then
    vim.notify(("AL: %s needs `al %s` (AL dotnet tool 30+) — update: :ALInstallDotnetTool")
      :format(what, subcommand), vim.log.levels.ERROR)
    return false
  end
  return true
end

-- Server args for a proxy against launch config `cfg`: the subcommand plus the
-- connection flags on the MCP service port, never the dev port.
local function proxy_args(subcommand, cfg, root)
  local args = { subcommand }
  vim.list_extend(args, altool.connection_flags(cfg, { port = "mcp" }))
  if subcommand == PROFILING and root then
    vim.list_extend(args, { "--profilefolder", root .. "/.profiles" })
  end
  args[#args + 1] = "--nolog"
  return args
end

-- Call `tool` on the proxy, after confirming (once per session, cached) that
-- the proxy really exposes it — a renamed tool in a newer tool version then
-- fails with the list of what it does have instead of an opaque error.
local function proxy_call(subcommand, cfg, root, tool, params, cb)
  local args = proxy_args(subcommand, cfg, root)
  local env  = altool.cred_env(cfg)
  altool.mcp_tools(args, function(ok, tools)
    if ok and altool.mcp_has_tool(subcommand, tool) == false then
      local names = {}
      for _, t in ipairs(tools) do names[#names + 1] = t.name end
      cb(false, ("al %s has no tool '%s' (has: %s)"):format(subcommand, tool, table.concat(names, ", ")))
      return
    end
    -- A failed tools/list is not fatal: the call itself reports the problem.
    altool.mcp_call_server(args, tool, params, cb, { env = env, timeout_ms = 300000 })
  end, { env = env })
end

local function with_root(dir, cb)
  local root = dir or lsp.get_root()
  if not root then
    vim.notify("AL: no project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end
  cb(root)
end

-- ── Profiling ───────────────────────────────────────────────────────────────

-- Arm a profiling schedule: pick launch config, prompt for the NST session id,
-- `schedule_profiling`. The user then exercises the slow scenario in the BC
-- client; :ALProfileCollect fetches what was captured.
function M.capture(dir)
  if not need(PROFILING, "Profiling") then return end
  with_root(dir, function(root)
    if M._profile then
      vim.notify(("AL: a profiling schedule is already armed on session %s — run :ALProfileCollect first")
        :format(M._profile.session), vim.log.levels.WARN)
      return
    end
    conn.pick_launch(root, function(cfg)
      vim.ui.input({ prompt = "BC session id to profile (web client ? → Help → Session ID): " },
        function(input)
          local session = tonumber(input)
          if not session or session <= 0 then
            if input and input ~= "" then
              vim.notify("AL: session id must be a positive integer", vim.log.levels.WARN)
            end
            return
          end
          vim.ui.input({ prompt = "Profile window in seconds [300]: ", default = "300" }, function(secs)
            local duration = tonumber(secs) or 300
            vim.notify("AL: arming profiling schedule on session " .. session .. "…", vim.log.levels.INFO)
            proxy_call(PROFILING, cfg, root, "schedule_profiling",
              { targetSessionId = session, durationSeconds = duration,
                description = "ALNvim " .. timestamp() },
              function(ok, text)
                if not ok then
                  vim.notify("AL: schedule_profiling failed:\n" .. text, vim.log.levels.ERROR)
                  return
                end
                local j   = json_in(text) or {}
                local sid = find_field(j, { "scheduleId", "schedule_id", "id" })
                M._profile = { root = root, cfg = cfg, session = session,
                               schedule_id = sid and tostring(sid) or nil }
                local next_step = find_field(j, { "nextStep" })
                vim.notify(("AL: profiling armed on session %d for %ds%s\n%s\nReproduce the slow scenario in BC, then :ALProfileCollect (<leader>adP)")
                  :format(session, duration, sid and (" (schedule " .. tostring(sid) .. ")") or "",
                          type(next_step) == "string" and next_step or ""),
                  vim.log.levels.INFO)
              end)
          end)
        end)
    end)
  end)
end

-- Save archives from a stop result under `dir`/<ts>: the zip, its extracted
-- files, and the overview JSON when inlined. Returns the folder and the list
-- of extracted .alcpuprofile paths.
local function save_archives(result, text, dir, ext)
  local archives, uri = extract_archives(result)
  local folder = dir .. "/" .. timestamp()
  vim.fn.mkdir(folder, "p")
  local files = {}
  for i, a in ipairs(archives) do
    local zip = folder .. (i == 1 and "/archive.zip" or ("/archive-" .. i .. ".zip"))
    local f = io.open(zip, "wb")
    if f then f:write(a.bytes); f:close() end
    platform.extract_zip(zip, folder)
  end
  local j = json_in(text)
  if j then
    local overview = find_field(j, { "profilesOverview", "overview" })
    if type(overview) == "table" then
      require("al.json").write(folder .. "/performance-profiles-overview.json", overview)
    end
  end
  -- The proxy's own summary text, kept beside the data.
  if text and text ~= "" then
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), folder .. "/response.md")
  end
  if ext then
    files = vim.fn.glob(folder .. "/**/*." .. ext, false, true)
  end
  return folder, files, uri
end

-- Stop the armed schedule, save everything it captured and open the viewer on
-- the first profile.
function M.collect(dir)
  if not need(PROFILING, "Profiling") then return end
  local st = M._profile
  if not st then
    vim.notify("AL: no profiling schedule armed — run :ALProfileCapture first", vim.log.levels.WARN)
    return
  end
  local root = dir or st.root
  local params = { targetSessionId = st.session }
  if st.schedule_id then params.scheduleId = st.schedule_id end
  vim.notify("AL: collecting profiles from session " .. st.session .. "…", vim.log.levels.INFO)
  proxy_call(PROFILING, st.cfg, root, "stop_schedule_and_get_profiles", params,
    function(ok, text, result)
      if not ok then
        vim.notify("AL: stop_schedule_and_get_profiles failed:\n" .. text, vim.log.levels.ERROR)
        return
      end
      M._profile = nil
      local folder, files, uri = save_archives(result, text, root .. "/.profiles", "alcpuprofile")
      if #files == 0 then
        vim.notify("AL: no .alcpuprofile in the response — saved what came back to " .. folder
          .. (uri and ("\nArchive referenced as " .. uri .. " (not inlined; fetch it with the proxy from Claude Code)") or ""),
          vim.log.levels.WARN)
        vim.cmd("edit " .. vim.fn.fnameescape(folder .. "/response.md"))
        return
      end
      table.sort(files)
      vim.notify(("AL: %d profile%s saved under %s"):format(#files, #files == 1 and "" or "s",
        vim.fn.fnamemodify(folder, ":~:.")), vim.log.levels.INFO)
      M.open(files[1], root)
    end)
end

-- Jump to the frame under the cursor in the viewer.
local function jump(row, root)
  local loc  = frame_location(row.url, row.name)
  local dirs = require("al.explorer").build_search_dirs(root)

  local function open_at(file, lnum)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    if lnum then
      pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    elseif loc.member and loc.member ~= "" then
      local ml = require("al.basedef").member_line(
        vim.api.nvim_buf_get_lines(0, 0, -1, false), loc.member)
      if ml then vim.api.nvim_win_set_cursor(0, { ml, 0 }) end
    end
    vim.cmd("normal! zz")
  end

  -- 1. a readable path, or the same basename somewhere in root + symbol sources
  if loc.path and vim.fn.filereadable(loc.path) == 1 then
    return open_at(loc.path, row.line)
  end
  if loc.basename then
    local hits = vim.fn.globpath(table.concat(dirs, ","), "**/" .. loc.basename, false, true)
    if #hits > 0 then return open_at(hits[1], row.line) end
  end
  -- 2. an object by kind + id / name
  if loc.kind and (loc.id or loc.name) then
    local pat = loc.id and ("^\\s*" .. loc.kind .. "\\s+" .. loc.id .. "\\b")
      or ("^\\s*" .. loc.kind .. "\\s+\\d+\\s+\"?" .. vim.fn.escape(loc.name, "\\.()[]{}*+?|^$") .. "\"?\\b")
    local cmd = { "rg", "-n", "-i", "-m", "1", "--no-heading", "--glob", "*.{al,AL}", "-e", pat }
    vim.list_extend(cmd, dirs)
    require("al.explorer").rg_async(cmd, function(lines)
      local file = lines[1] and lines[1]:match("^(.-):%d+:")
      if file then open_at(file, nil) else
        vim.notify("AL: no source for " .. loc.kind .. " " .. tostring(loc.id or loc.name), vim.log.levels.WARN)
      end
    end, "profile frame")
    return
  end
  vim.notify("AL: cannot resolve frame location '" .. (row.url ~= "" and row.url or row.name) .. "'",
    vim.log.levels.WARN)
end

-- Viewer: hot functions sorted by self time. <CR> jumps, q closes.
function M.open(file, root)
  root = root or lsp.get_root()
  if not file or file == "" then
    local dir = root and (root .. "/.profiles")
    local list = dir and vim.fn.glob(dir .. "/**/*.alcpuprofile", false, true) or {}
    if #list == 0 then
      vim.notify("AL: no .alcpuprofile under " .. tostring(dir) .. " — :ALProfileCapture first, or :ALProfileOpen <file>",
        vim.log.levels.WARN)
      return
    end
    local function mtime(f)
      local st = vim.uv.fs_stat(f)
      return st and st.mtime.sec or 0
    end
    table.sort(list, function(a, b)
      local ma, mb = mtime(a), mtime(b)
      if ma ~= mb then return ma > mb end
      return a > b
    end)
    file = list[1]   -- newest
  end
  local okr, lines = pcall(vim.fn.readfile, file)
  if not okr then
    vim.notify("AL: cannot read " .. file, vim.log.levels.ERROR)
    return
  end
  local rows, err = parse_cpuprofile(table.concat(lines, "\n"))
  if not rows then
    vim.notify("AL: " .. file .. ": " .. err, vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local w = math.min(120, math.max(70, vim.o.columns - 6))
  local h = math.min(#rows + 4, math.max(10, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    style = "minimal", border = "rounded",
    title = " AL profile — " .. vim.fn.fnamemodify(file, ":t") .. " ", title_pos = "center",
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    render_rows(rows, ("%d frames — <CR> jump to source, q close"):format(#rows)))
  vim.bo[buf].modifiable = false
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { math.min(4, #rows + 3), 0 })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set("n", "<CR>", function()
    local idx = vim.api.nvim_win_get_cursor(0)[1] - 3
    local row = rows[idx]
    if not row then return end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    jump(row, root)
  end, { buffer = buf, nowait = true, silent = true, desc = "AL: jump to frame" })
end

-- ── Snapshot (proxy route) ──────────────────────────────────────────────────

-- Arm snapshot debugging: pick launch config, optional session id (empty = wait
-- for the next web-client session), `initialize_snapshot_debugging`.
function M.snapshot_capture(dir)
  if not need(SNAPSHOT, "Snapshot capture") then return end
  with_root(dir, function(root)
    if M._snapshot then
      vim.notify("AL: a snapshot run is already armed — run :ALSnapshotCollect first", vim.log.levels.WARN)
      return
    end
    conn.pick_launch(root, function(cfg)
      vim.ui.input({ prompt = "BC session id to bind (empty = wait for next web-client session): " },
        function(input)
          if input == nil then return end
          local params = { clientType = "WebClient" }
          local session = tonumber(input)
          if session and session > 0 then params.sessionId = session end
          vim.notify("AL: arming snapshot debugging…", vim.log.levels.INFO)
          proxy_call(SNAPSHOT, cfg, root, "initialize_snapshot_debugging", params,
            function(ok, text)
              if not ok then
                vim.notify("AL: initialize_snapshot_debugging failed:\n" .. text, vim.log.levels.ERROR)
                return
              end
              local j   = json_in(text) or {}
              local ctx = find_field(j, { "debuggingContext", "debugging_context", "context" })
              if not ctx then
                vim.notify("AL: no debuggingContext in the response:\n" .. text, vim.log.levels.ERROR)
                return
              end
              M._snapshot = { root = root, cfg = cfg, context = tostring(ctx),
                              host_id = find_field(j, { "hostId" }) }
              local next_step = find_field(j, { "nextStep" })
              vim.notify("AL: snapshot debugging armed.\n"
                .. (type(next_step) == "string" and (next_step .. "\n") or "")
                .. "Reproduce the scenario in BC, then :ALSnapshotCollect (<leader>adF)", vim.log.levels.INFO)
            end)
        end)
    end)
  end)
end

-- Stop the armed run and save the archive plus the proxy's decoded summary
-- under <root>/.snapshots/<ts>/.
function M.snapshot_collect(dir)
  if not need(SNAPSHOT, "Snapshot capture") then return end
  local st = M._snapshot
  if not st then
    vim.notify("AL: no snapshot run armed — run :ALSnapshotCapture first", vim.log.levels.WARN)
    return
  end
  local root = dir or st.root
  local params = { debuggingContext = st.context }
  -- A fresh proxy process has forgotten the owning NST node; pass it back.
  if st.host_id and st.host_id ~= "" then params.hostId = tostring(st.host_id) end
  vim.notify("AL: stopping snapshot debugging…", vim.log.levels.INFO)
  proxy_call(SNAPSHOT, st.cfg, root, "stop_snapshot_debugging", params,
    function(ok, text, result)
      if not ok then
        vim.notify("AL: stop_snapshot_debugging failed:\n" .. text, vim.log.levels.ERROR)
        return
      end
      M._snapshot = nil
      local folder, _, uri = save_archives(result, text, root .. "/.snapshots", nil)
      vim.notify("AL: snapshot saved under " .. vim.fn.fnamemodify(folder, ":~:.")
        .. (uri and (" (archive referenced as " .. uri .. ")") or ""), vim.log.levels.INFO)
      vim.cmd("edit " .. vim.fn.fnameescape(folder .. "/response.md"))
    end)
end

M._test = {
  parse_cpuprofile = parse_cpuprofile,
  frame_location   = frame_location,
  find_field       = find_field,
  json_in          = json_in,
  extract_archives = extract_archives,
  proxy_args       = proxy_args,
  render_rows      = render_rows,
}

return M
