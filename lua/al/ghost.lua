-- Inline AI ghost-text completions via an Ollama FIM endpoint.
-- Uses fill-in-middle (FIM) via /api/generate with prefix+suffix context.
-- Toggle: :ALGhostToggle / <leader>aI
-- Accept: <M-l> (insert mode, buffer-local in AL files)

local M = {}
local api = vim.api

local _ns      = api.nvim_create_namespace("al_ghost")
local _enabled = false
local _last    = nil   -- { text, row, col, bufnr } of visible ghost

-- ── Defaults (override via require("al").setup({ ghost = { ... } })) ─────────

-- Inline FIM ghost completions from an Ollama server. Override via
-- require("al").setup({ ghost = { endpoint = ..., model = ... } }).
local DEFAULTS = {
  endpoint    = "http://localhost:11434",  -- Ollama /api/generate base (point at your server)
  model       = "qwen2.5-coder",           -- any FIM-capable code model on that server
  debounce_ms = 600,
  max_tokens  = 80,
  temperature = 0.1,
  insecure    = false,  -- set true if endpoint is HTTPS with a self-signed/local-CA cert
}

local function cfg()
  return vim.tbl_extend("force", DEFAULTS, (require("al").config.ghost or {}))
end

-- ── Ghost text display ────────────────────────────────────────────────────────

local function clear()
  if _last and api.nvim_buf_is_valid(_last.bufnr) then
    api.nvim_buf_clear_namespace(_last.bufnr, _ns, 0, -1)
  end
  _last = nil
end

local function show(bufnr, row, col, text)
  clear()
  if text == "" then return end
  local parts = vim.split(text, "\n", { plain = true })
  local virt_lines = {}
  for i = 2, #parts do
    virt_lines[#virt_lines + 1] = { { parts[i], "Comment" } }
  end
  api.nvim_buf_set_extmark(bufnr, _ns, row, col, {
    virt_text     = { { parts[1], "Comment" } },
    virt_text_pos = "inline",
    virt_lines    = #virt_lines > 0 and virt_lines or nil,
    hl_mode       = "combine",
  })
  _last = { text = text, row = row, col = col, bufnr = bufnr }
end

-- ── Accept ────────────────────────────────────────────────────────────────────

function M.accept()
  if not _last then return false end
  local g    = _last
  local bufnr = api.nvim_get_current_buf()
  if bufnr ~= g.bufnr then return false end
  local cur_row, cur_col = unpack(api.nvim_win_get_cursor(0))
  if (cur_row - 1) ~= g.row or cur_col ~= g.col then return false end

  clear()

  local lines    = vim.split(g.text, "\n", { plain = true })
  local cur_line = (api.nvim_buf_get_lines(bufnr, g.row, g.row + 1, false))[1] or ""
  local new_first = cur_line:sub(1, g.col) .. lines[1] .. cur_line:sub(g.col + 1)
  local new_lines = { new_first }
  for i = 2, #lines do new_lines[#new_lines + 1] = lines[i] end

  api.nvim_buf_set_lines(bufnr, g.row, g.row + 1, false, new_lines)

  local new_row = g.row + #lines - 1
  local new_col = (#lines == 1) and (g.col + #lines[1]) or #lines[#lines]
  api.nvim_win_set_cursor(0, { new_row + 1, new_col })
  return true
end

-- ── Completion request ────────────────────────────────────────────────────────

local _pending = nil

local function request(bufnr)
  if not _enabled or vim.fn.mode() ~= "i" then return end

  local row, col = unpack(api.nvim_win_get_cursor(0))
  row = row - 1  -- 0-based for extmarks

  local all = api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Build prefix: everything up to cursor
  local pre = {}
  for i = 1, row do pre[#pre + 1] = all[i] end
  pre[#pre + 1] = (all[row + 1] or ""):sub(1, col)

  -- Build suffix: rest of cursor line + next 5 lines
  local suf = { (all[row + 1] or ""):sub(col + 1) }
  for i = row + 2, math.min(#all, row + 6) do suf[#suf + 1] = all[i] end

  local prefix = table.concat(pre, "\n")
  local suffix = table.concat(suf, "\n")
  if #prefix < 10 then return end

  if _pending then pcall(vim.fn.jobstop, _pending); _pending = nil end

  local c       = cfg()
  local payload = vim.fn.json_encode({
    model   = c.model,
    prompt  = prefix,
    suffix  = suffix,
    options = {
      temperature = c.temperature,
      num_predict = c.max_tokens,
      stop        = { "\n\n" },
    },
    stream  = false,
  })

  local curl_args = { "curl", "-s", "-X", "POST" }
  if c.insecure then table.insert(curl_args, "-k") end  -- self-signed/local-CA HTTPS
  vim.list_extend(curl_args, {
    c.endpoint .. "/api/generate",
    "-H", "Content-Type: application/json",
    "-d", payload,
    "--max-time", "8" })

  local out = {}
  _pending  = vim.fn.jobstart(
    curl_args,
    {
      stdout_buffered = true,
      on_stdout = function(_, data)
        for _, chunk in ipairs(data) do
          if chunk ~= "" then out[#out + 1] = chunk end
        end
      end,
      on_exit = function(_, code)
        _pending = nil
        if code ~= 0 or #out == 0 then return end
        vim.schedule(function()
          if not _enabled or vim.fn.mode() ~= "i" then return end
          if api.nvim_get_current_buf() ~= bufnr then return end
          -- Cursor must not have moved since we fired
          local r2, c2 = unpack(api.nvim_win_get_cursor(0))
          if (r2 - 1) ~= row or c2 ~= col then return end
          local ok, resp = pcall(vim.fn.json_decode, table.concat(out))
          if not ok or type(resp) ~= "table" then return end
          local text = vim.trim(resp.response or "")
          if text == "" then return end
          -- Don't clash with nvim-cmp popup
          local ok_cmp, cmp = pcall(require, "cmp")
          if ok_cmp and cmp.visible() then return end
          show(bufnr, row, col, text)
        end)
      end,
    }
  )
end

-- ── Debounce ──────────────────────────────────────────────────────────────────

local _timer = nil

local function trigger()
  if not _enabled then return end
  clear()
  if _timer then _timer:stop(); _timer:close(); _timer = nil end
  local bufnr = api.nvim_get_current_buf()
  local c     = cfg()
  local t = vim.uv.new_timer()
  _timer = t
  t:start(c.debounce_ms, 0, vim.schedule_wrap(function()
    -- Identity check, not `if _timer then`. A newer trigger() may have replaced
    -- (and closed) this timer between the uv callback firing and this scheduled
    -- function running; the nil check would then close the *replacement*,
    -- silently killing the new debounce so no completion ever arrived.
    if _timer ~= t then return end
    _timer = nil
    if not t:is_closing() then t:close() end
    request(bufnr)
  end))
end

local function cancel()
  clear()
  if _timer then _timer:stop(); _timer:close(); _timer = nil end
  if _pending then pcall(vim.fn.jobstop, _pending); _pending = nil end
end

-- ── Autocmds ─────────────────────────────────────────────────────────────────

local function setup_autocmds()
  local grp = api.nvim_create_augroup("ALGhost", { clear = true })
  api.nvim_create_autocmd("TextChangedI", {
    group = grp, pattern = "*.al",
    callback = function() trigger() end,
  })
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = grp, pattern = "*.al",
    callback = function() cancel() end,
  })
end

local function teardown_autocmds()
  api.nvim_create_augroup("ALGhost", { clear = true })
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.toggle()
  _enabled = not _enabled
  if _enabled then
    setup_autocmds()
    vim.notify("AL Ghost: ON  [" .. cfg().model .. "]", vim.log.levels.INFO)
  else
    cancel()
    teardown_autocmds()
    vim.notify("AL Ghost: OFF", vim.log.levels.INFO)
  end
end

function M.is_enabled() return _enabled end

return M
