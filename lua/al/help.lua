-- AL Help panel: left-side split running lynx pointed at MS Learn AL docs.
--
-- M.toggle()  –  open / close the panel  (<leader>ah / :ALHelp)
--
-- Lynx keyboard shortcuts (while panel is focused):
--   ↑ ↓          scroll / move between links
--   → / Enter    follow link
--   ←  / u       go back
--   g            go to URL
--   /            search on page
--   q            quit lynx (closes buffer)

local M = {}

local DEFAULT_URL =
  "https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-programming-in-al"

-- Panel state (persists across toggles so browsing position is remembered).
local state = { win = nil, buf = nil }

local function win_valid()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

-- ── Open ──────────────────────────────────────────────────────────────────────

local function open_panel(url)
  url = url or DEFAULT_URL

  if vim.fn.executable("lynx") == 0 then
    vim.notify(
      "ALHelp: lynx not found. Install with: sudo apt install lynx",
      vim.log.levels.ERROR)
    return
  end

  local prev_win = vim.api.nvim_get_current_win()

  -- Create a new buffer for the terminal the first time (or if the old one died).
  if not buf_valid() then
    -- Open left split first, then create the terminal buffer inside it.
    vim.cmd("topleft vsplit")
    state.win = vim.api.nvim_get_current_win()

    -- Cosmetic window settings
    vim.wo[state.win].number         = false
    vim.wo[state.win].relativenumber = false
    vim.wo[state.win].signcolumn     = "no"
    vim.wo[state.win].winfixwidth    = true
    vim.api.nvim_win_set_width(state.win, 85)

    -- Start lynx in a terminal buffer
    local buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    vim.api.nvim_win_set_buf(state.win, buf)
    vim.bo[buf].bufhidden = "hide"   -- keep process alive when window is closed

    vim.fn.termopen({ "lynx", "-accept_all_cookies=yes", url }, {
      on_exit = function()
        -- lynx exited: clean up state so next toggle starts fresh.
        if buf_valid() then
          vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        state.buf = nil
        state.win = nil
      end,
    })

    vim.api.nvim_buf_set_name(buf, "ALHelp")
  else
    -- Buffer already running — just open a new window for it.
    vim.cmd("topleft vsplit")
    state.win = vim.api.nvim_get_current_win()
    vim.wo[state.win].number         = false
    vim.wo[state.win].relativenumber = false
    vim.wo[state.win].signcolumn     = "no"
    vim.wo[state.win].winfixwidth    = true
    vim.api.nvim_win_set_width(state.win, 85)
    vim.api.nvim_win_set_buf(state.win, state.buf)
  end

  -- Return focus to the window the user was editing.
  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
end

-- ── Close ─────────────────────────────────────────────────────────────────────

local function close_panel()
  if win_valid() then
    vim.api.nvim_win_close(state.win, false)
  end
  state.win = nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Toggle the help panel. Optionally accepts a URL to open on first launch.
function M.toggle(url)
  if win_valid() then
    close_panel()
  else
    open_panel(url)
  end
end

-- Open the panel at a specific URL (always opens/re-uses the panel).
function M.open(url)
  if win_valid() then
    close_panel()
  end
  open_panel(url)
end

return M
