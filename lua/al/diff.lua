-- Git diff explorer for ALNvim.
-- Lists all files with uncommitted changes (git status --porcelain) and lets
-- the user inspect or vimdiff each one.
--
-- Telescope (when available):
--   Picker lists changed files with status icons.
--   Preview pane shows the unified diff (or file content for new/deleted files).
--   <CR>    open file in editor
--   <C-d>   open side-by-side vimdiff (HEAD vs working)
--
-- Fallback panel (no Telescope):
--   Left-side panel listing changed files — follows the compile.lua panel pattern.
--   <CR>    open side-by-side vimdiff
--   o       open file without diff
--   r       refresh the list
--   q / <Esc>  close panel + turn off diff mode

local M   = {}
local lsp = require("al.lsp")

-- ── git helpers ───────────────────────────────────────────────────────────────

local function git_root(dir)
  local r = vim.trim(vim.fn.system(
    "git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null"))
  return (vim.v.shell_error == 0 and r ~= "") and r or nil
end

-- Parse `git status --porcelain` into a list of {status, file, abs} entries.
local function get_changed_files(git_r)
  local lines = vim.fn.systemlist(
    "git -C " .. vim.fn.shellescape(git_r) .. " status --porcelain 2>/dev/null")
  if vim.v.shell_error ~= 0 then return nil end
  local entries = {}
  for _, line in ipairs(lines) do
    if #line >= 4 then
      local xy   = line:sub(1, 2)
      local path = vim.trim(line:sub(4))
      path = path:match("^.+ %-> (.+)$") or path   -- handle renames
      local idx_s = xy:sub(1, 1)
      local wrk_s = xy:sub(2, 2)
      local status = (idx_s ~= " " and idx_s ~= "?") and idx_s or wrk_s
      table.insert(entries, {
        status = status == "?" and "?" or status,
        file   = path,
        abs    = git_r .. "/" .. path,
      })
    end
  end
  return entries
end

local function read_head(git_r, file)
  local out = vim.fn.systemlist(
    "git -C " .. vim.fn.shellescape(git_r) ..
    " show HEAD:" .. vim.fn.shellescape(file) .. " 2>/dev/null")
  return vim.v.shell_error == 0 and out or nil
end

local function read_diff(git_r, file)
  return vim.fn.systemlist(
    "git -C " .. vim.fn.shellescape(git_r) ..
    " diff HEAD -- " .. vim.fn.shellescape(file) .. " 2>/dev/null")
end

-- ── status display ────────────────────────────────────────────────────────────

local ICON = { M = "~", A = "+", D = "-", R = "»", ["?"] = "?" }
local HL   = {
  M = "DiagnosticWarn",
  A = "DiagnosticOk",
  D = "DiagnosticError",
  R = "DiagnosticInfo",
  ["?"] = "Comment",
}

-- ── vimdiff opener ────────────────────────────────────────────────────────────

-- Tracks the HEAD diff window so it can be closed before opening a new one.
local _head_win = nil

-- Open a side-by-side diff for `entry`.  Must be called with the target (right)
-- window already focused; leaves the cursor in the working-file window.
local function open_vifdiff(git_r, entry)
  -- Close any existing HEAD window from a previous diff
  if _head_win and vim.api.nvim_win_is_valid(_head_win) then
    vim.api.nvim_win_close(_head_win, true)
    _head_win = nil
  end
  vim.cmd("diffoff!")

  local head = read_head(git_r, entry.file)

  if entry.status == "D" then
    -- Deleted: show HEAD content in current window (no working file exists)
    local del_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, del_buf)
    vim.bo[del_buf].buftype    = "nofile"
    vim.bo[del_buf].bufhidden  = "wipe"
    vim.bo[del_buf].swapfile   = false
    vim.bo[del_buf].modifiable = true
    vim.api.nvim_buf_set_lines(del_buf, 0, -1, false, head or {})
    local ext = entry.file:match("%.([^.]+)$")
    if ext then pcall(function() vim.bo[del_buf].filetype = ext end) end
    vim.bo[del_buf].modifiable = false
    vim.wo[0].winbar = "  HEAD:" .. entry.file .. "  [deleted — read-only]"
    return
  end

  -- Open working file in the current (right) window
  vim.cmd("edit " .. vim.fn.fnameescape(entry.abs))
  vim.cmd("diffthis")

  -- HEAD version in a new split to the left of the working file
  vim.cmd("leftabove vsplit")
  _head_win = vim.api.nvim_get_current_win()
  local head_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(_head_win, head_buf)
  vim.bo[head_buf].buftype    = "nofile"
  vim.bo[head_buf].bufhidden  = "wipe"
  vim.bo[head_buf].swapfile   = false
  vim.bo[head_buf].modifiable = true
  if head then
    vim.api.nvim_buf_set_lines(head_buf, 0, -1, false, head)
    local ext = entry.file:match("%.([^.]+)$")
    if ext then pcall(function() vim.bo[head_buf].filetype = ext end) end
    vim.wo[_head_win].winbar = "  HEAD:" .. entry.file .. "  [read-only]"
  else
    vim.wo[_head_win].winbar = "  (new file — not in HEAD)  "
  end
  vim.bo[head_buf].modifiable = false
  vim.cmd("diffthis")

  -- Leave cursor in the working-file window (to the right)
  vim.cmd("wincmd l")
end

-- ── Telescope picker ──────────────────────────────────────────────────────────

local function telescope_explore(git_r, entries)
  local pickers    = require("telescope.pickers")
  local finders    = require("telescope.finders")
  local conf       = require("telescope.config").values
  local actions    = require("telescope.actions")
  local act_state  = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local previewer = previewers.new_buffer_previewer({
    title = "Diff",
    define_preview = function(self, entry_tbl)
      local e     = entry_tbl.value
      local lines, ft
      if e.status == "D" then
        lines = read_head(git_r, e.file) or {}
        ft    = e.file:match("%.([^.]+)$") or "text"
      elseif e.status == "?" then
        local f = io.open(e.abs, "r")
        if f then
          lines = vim.split(f:read("*a"), "\n")
          f:close()
        else
          lines = {}
        end
        ft = e.file:match("%.([^.]+)$") or "text"
      else
        lines = read_diff(git_r, e.file)
        ft    = "diff"
      end
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines or {})
      pcall(function() vim.bo[self.state.bufnr].filetype = ft end)
    end,
  })

  pickers.new({}, {
    prompt_title = string.format(
      "AL Git Changes (%d)  [<CR> open  ·  <C-d> vimdiff]", #entries),
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        return {
          value    = e,
          display  = string.format("  %s  %s", ICON[e.status] or "·", e.file),
          ordinal  = e.file,
          filename = e.abs,
          lnum     = 1,
        }
      end,
    }),
    sorter    = conf.generic_sorter({}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local sel = act_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel and sel.value.status ~= "D" then
          vim.cmd("edit " .. vim.fn.fnameescape(sel.value.abs))
        end
      end)
      map({ "i", "n" }, "<C-d>", function()
        local sel = act_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then open_vifdiff(git_r, sel.value) end
      end)
      return true
    end,
  }):find()
end

-- ── Fallback panel ────────────────────────────────────────────────────────────

local function panel_explore(git_r, entries)
  local file_win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  vim.cmd("topleft vsplit")
  local panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, buf)
  vim.api.nvim_win_set_width(panel_win, math.max(38, math.floor(vim.o.columns * 0.28)))

  vim.wo[panel_win].wrap        = false
  vim.wo[panel_win].cursorline  = true
  vim.wo[panel_win].number      = false
  vim.wo[panel_win].signcolumn  = "no"
  vim.wo[panel_win].winfixwidth = true
  vim.wo[panel_win].winbar =
    "  Git Changes  [<CR> vimdiff · o open · r refresh · q close]"

  local ns = vim.api.nvim_create_namespace("al_diff_panel")

  local function render()
    vim.bo[buf].modifiable = true
    local lines = {}
    for _, e in ipairs(entries) do
      table.insert(lines, string.format("  %s  %s", ICON[e.status] or "·", e.file))
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, e in ipairs(entries) do
      vim.api.nvim_buf_add_highlight(buf, ns, HL[e.status] or "Normal", i - 1, 0, -1)
    end
    vim.bo[buf].modifiable = false
  end

  render()
  vim.api.nvim_win_set_cursor(panel_win, { 1, 0 })

  local function cur_entry()
    return entries[vim.api.nvim_win_get_cursor(panel_win)[1]]
  end

  -- Return the window to use for opening files/diffs (right side of panel).
  local function right_win()
    if vim.api.nvim_win_is_valid(file_win) then return file_win end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= panel_win and vim.api.nvim_win_get_config(w).relative == "" then
        return w
      end
    end
    -- No other window — open one
    vim.api.nvim_win_call(panel_win, function() vim.cmd("rightbelow vsplit") end)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= panel_win and vim.api.nvim_win_get_config(w).relative == "" then
        return w
      end
    end
  end

  local function close()
    vim.cmd("diffoff!")
    if _head_win and vim.api.nvim_win_is_valid(_head_win) then
      vim.api.nvim_win_close(_head_win, true)
      _head_win = nil
    end
    if vim.api.nvim_win_is_valid(panel_win) then
      vim.api.nvim_win_close(panel_win, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    local e = cur_entry()
    if not e then return end
    local rw = right_win()
    if rw then vim.api.nvim_set_current_win(rw) end
    open_vifdiff(git_r, e)
    if vim.api.nvim_win_is_valid(panel_win) then
      vim.api.nvim_set_current_win(panel_win)
    end
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set("n", "o", function()
    local e = cur_entry()
    if not e or e.status == "D" then return end
    local rw = right_win()
    if rw then
      vim.api.nvim_win_call(rw, function()
        vim.cmd("edit " .. vim.fn.fnameescape(e.abs))
      end)
    end
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set("n", "r", function()
    local new = get_changed_files(git_r)
    if new then
      entries = new
      render()
      if #entries == 0 then
        vim.notify("AL: No more uncommitted changes", vim.log.levels.INFO)
        close()
      end
    end
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
end

-- ── public entry point ────────────────────────────────────────────────────────

function M.explore(root)
  root = root or lsp.get_root() or vim.fn.getcwd()
  local git_r = git_root(root) or git_root(vim.fn.getcwd())
  if not git_r then
    vim.notify("AL: Not inside a git repository", vim.log.levels.ERROR)
    return
  end

  local entries = get_changed_files(git_r)
  if not entries then
    vim.notify("AL: git error", vim.log.levels.ERROR)
    return
  end
  if #entries == 0 then
    vim.notify("AL: No uncommitted changes", vim.log.levels.INFO)
    return
  end

  if pcall(require, "telescope") then
    telescope_explore(git_r, entries)
  else
    panel_explore(git_r, entries)
  end
end

return M
