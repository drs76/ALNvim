-- AL Help panel: left-side split showing MS Learn AL docs.
--
-- Docs are fetched from the MicrosoftDocs GitHub repo (raw Markdown).
--
-- Rendering:
--   • If `smd` is on $PATH: renders through smd in a terminal buffer (ANSI colours).
--     Install: curl -fsSL https://codeberg.org/raw/johann1764/smd/branch/main/smd \
--              -o ~/.local/bin/smd && chmod +x ~/.local/bin/smd
--   • Otherwise: displays raw Markdown in a nofile buffer (render-markdown.nvim if present).
--
-- M.toggle()   – <leader>ah / :ALHelp         open/close panel
-- M.topics()   – <leader>aH / :ALHelpTopics   pick a topic from the curated list
--
-- Keymaps inside the panel:
--   <CR>   follow a markdown link (relative .md links open in the panel)
--   q      close the panel
--   r      reload the current page
--   t      open the topic picker
--   u / <BS>  go back in history

local M = {}

local RAW_BASE =
  "https://raw.githubusercontent.com/MicrosoftDocs/dynamics365smb-devitpro-pb/main/dev-itpro/developer/"

local LEARN_PREFIX =
  "https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/"

-- Curated topic list  { display label, slug }
-- Slugs match the final path segment of the MS Learn URL.
local TOPICS = {
  -- ── Language fundamentals ──────────────────────────────────────────────────
  { "Programming in AL",                  "devenv-programming-in-al" },
  { "AL Code Guidelines",                 "devenv-al-code-guidelines" },
  { "Variables and Constants",            "devenv-variables-and-constants" },
  { "Data Types Overview",                "devenv-data-types-overview" },
  { "Simple Statements",                  "devenv-al-simple-statements" },
  { "Compound Statements",                "devenv-al-compound-statements" },
  { "Procedures and Triggers",            "devenv-al-procedures-and-triggers" },
  { "Error Handling",                     "devenv-al-error-handling" },
  -- ── Objects ────────────────────────────────────────────────────────────────
  { "Table Object",                       "devenv-table-object" },
  { "Table Extension Object",             "devenv-table-extension-object" },
  { "Page Object",                        "devenv-page-object" },
  { "Page Extension Object",              "devenv-page-extension-object" },
  { "Page Customization Object",          "devenv-page-customization-object" },
  { "Codeunit Object",                    "devenv-codeunit-object" },
  { "Report Object",                      "devenv-report-object" },
  { "Report Extension Object",            "devenv-report-extension-object" },
  { "Query Object",                       "devenv-query-object" },
  { "XmlPort Object",                     "devenv-xmlport-object" },
  { "Enum Object",                        "devenv-enum-object" },
  { "Enum Extension Object",              "devenv-enum-extension-object" },
  { "Interface Object",                   "devenv-interface-object" },
  { "Permission Set Object",              "devenv-permissionset-object" },
  -- ── Events ─────────────────────────────────────────────────────────────────
  { "Events in AL",                       "devenv-events-in-al" },
  { "Publishing Events",                  "devenv-event-types" },
  { "Subscribing to Events",              "devenv-subscribing-to-events" },
  { "Raising Events",                     "devenv-raising-events" },
  -- ── Pages and UI ───────────────────────────────────────────────────────────
  { "Pages Overview",                     "devenv-pages-overview" },
  { "Page Types and Layouts",             "devenv-page-types-and-layouts" },
  { "Actions Overview",                   "devenv-actions-overview" },
  { "FlowFields",                         "devenv-flowfields" },
  -- ── API / Integration ──────────────────────────────────────────────────────
  { "API Pages",                          "devenv-api-pages" },
  { "Web Services Overview",              "devenv-web-services" },
  -- ── Testing ────────────────────────────────────────────────────────────────
  { "Testing AL Code",                    "devenv-testing-application" },
  { "Test Codeunits and Methods",         "devenv-test-codeunits-and-test-methods" },
}

-- Panel state (persists across toggles).
local state = {
  win       = nil,
  buf       = nil,   -- current display buffer (terminal or nofile)
  slug      = nil,   -- currently displayed slug
  hist      = {},    -- navigation history (list of slugs)
  raw_lines = {},    -- original fetched markdown, used for link-following fallback
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function win_valid()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

local function smd_ok()
  return vim.fn.executable("smd") == 1
end

-- Extract a slug from either a bare slug, a relative .md filename, or a full
-- MS Learn URL.
local function to_slug(input)
  if not input or input == "" then return nil end
  -- Full MS Learn URL: extract last path segment
  local from_url = input:match(LEARN_PREFIX:gsub("%-", "%%-") .. "([%w%-]+)")
  if from_url then return from_url end
  -- Relative .md link from a markdown page: devenv-foo.md → devenv-foo
  local from_md = input:match("^([%w%-]+)%.md$")
  if from_md then return from_md end
  -- Bare slug: devenv-foo
  if input:match("^devenv%-") then return input end
  return nil
end

-- ── Window / buffer options ───────────────────────────────────────────────────

local function apply_win_opts(win)
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].winfixwidth    = true
  vim.wo[win].wrap           = true
  vim.wo[win].linebreak      = true
  vim.api.nvim_win_set_width(win, 85)
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

-- Rewrite internal devenv links so their slug survives smd rendering.
-- [text](devenv-foo.md) → [text (→devenv-foo)](devenv-foo.md)
-- smd still styles the link (underline/colour) but hides the URL.
-- The slug "(→devenv-foo)" is now part of the display text — it appears
-- in the rendered terminal line and follow_link's Try 0 extracts it.
local function preprocess_links_for_smd(lines)
  local result = {}
  for _, line in ipairs(lines) do
    local out = line:gsub("%[([^%]]+)%]%(([^)]+)%)", function(text, url)
      if url:match("^https?://") or url:match("^#") then
        return "[" .. text .. "](" .. url .. ")"
      end
      local slug = url:gsub("#.*", ""):gsub("%?.*", "")
      slug = slug:match("([^/]+)$") or slug
      slug = slug:gsub("%.md$", "")
      if slug:match("^devenv%-") then
        -- Embed slug inside the display text; keep real URL so smd treats it as a link.
        return "[" .. text .. " (→" .. slug .. ")](" .. url .. ")"
      end
      return "[" .. text .. "](" .. url .. ")"
    end)
    result[#result + 1] = out
  end
  return result
end

-- follow_link: extract URL from current panel line and navigate.
local function follow_link()
  local line = vim.api.nvim_get_current_line()
  local col  = vim.api.nvim_win_get_cursor(0)[2] + 1  -- 1-based

  local target

  -- Try 0: smd path — slug embedded by preprocess_links_for_smd as (→devenv-slug)
  local slug0 = line:match("%(→(devenv%-[^)]+)%)")
  if slug0 then
    if state.slug then table.insert(state.hist, state.slug) end
    M._fetch(slug0)
    return
  end

  -- Try 1: standard [text](url) markdown syntax present in line (nofile path)
  for s, url, e in line:gmatch("()%[[^%]]*%]%(([^)]+)%)()") do
    if col >= s and col < e then
      target = url
      break
    end
    if not target then target = url end  -- keep first as fallback
  end

  if not target then
    vim.notify("ALHelp: no link here", vim.log.levels.INFO)
    return
  end

  -- Pure in-page anchor (e.g. #variable-declarations) — nothing to navigate to.
  if target:match("^#") then
    vim.notify("ALHelp: in-page anchor — " .. target, vim.log.levels.INFO)
    return
  end
  -- Strip anchors and query strings
  target = target:gsub("#.*", ""):gsub("%?.*", "")
  local slug = to_slug(target)
  if not slug then
    vim.notify("ALHelp: external link — " .. target, vim.log.levels.INFO)
    return
  end
  if state.slug then
    table.insert(state.hist, state.slug)
  end
  -- fetch_and_show is defined below — use a forward reference via M
  M._fetch(slug)
end

local function setup_buf_keymaps(buf)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, desc = desc })
  end

  map("q", function() M.toggle() end, "ALHelp: close panel")

  map("r", function()
    if state.slug then M._fetch(state.slug) end
  end, "ALHelp: reload page")

  map("t", function() M.topics() end, "ALHelp: topic picker")

  local function go_back()
    if #state.hist > 0 then
      M._fetch(table.remove(state.hist))
    else
      vim.notify("ALHelp: no previous page", vim.log.levels.INFO)
    end
  end
  map("u",    go_back, "ALHelp: go back")
  map("<BS>", go_back, "ALHelp: go back")

  map("<CR>", follow_link, "ALHelp: follow link")
end

-- ── nofile fallback path ──────────────────────────────────────────────────────

local function ensure_nofile_buf()
  if buf_valid() and vim.bo[state.buf].buftype == "nofile" then return end
  state.buf  = vim.api.nvim_create_buf(false, true)
  state.hist = {}
  vim.bo[state.buf].buftype    = "nofile"
  vim.bo[state.buf].bufhidden  = "hide"
  vim.bo[state.buf].swapfile   = false
  vim.bo[state.buf].filetype   = "markdown"
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_set_name(state.buf, "ALHelp")
  setup_buf_keymaps(state.buf)
end

local function set_buf_content(lines)
  if not buf_valid() then return end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified   = false
  -- nvim_buf_set_lines does not fire TextChanged; trigger render-markdown explicitly.
  local ok, rm_api = pcall(require, "render-markdown.api")
  if ok then
    rm_api.render({ buf = state.buf })
  end
end

-- ── smd terminal-buffer path ──────────────────────────────────────────────────

local function show_with_smd(clean)
  local smd_lines = preprocess_links_for_smd(clean)
  local tmpfile = vim.fn.tempname() .. ".md"
  vim.fn.writefile(smd_lines, tmpfile)

  local old_buf = state.buf
  local new_buf = vim.api.nvim_create_buf(false, true)
  state.buf = new_buf

  -- nvim_open_term: terminal channel buffer with no attached job.
  -- The user enters this buffer in Normal mode — no terminal-mode issues.
  local chan = vim.api.nvim_open_term(new_buf, {})

  if win_valid() then
    vim.api.nvim_win_set_buf(state.win, new_buf)
  end

  -- jobstart (no PTY) → stdout is a pipe → smd auto-selects cat → full output.
  -- stdout_buffered collects all output then calls on_stdout once.
  local stdout_received = false
  vim.fn.jobstart({ "bash", "-c", "smd " .. vim.fn.shellescape(tmpfile) .. " 2>/dev/null" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      stdout_received = true
      vim.schedule(function()
        -- Join lines with \r\n for correct terminal display.
        vim.fn.chansend(chan, table.concat(data, "\r\n"))
        pcall(vim.fn.chanclose, chan)
        vim.fn.delete(tmpfile)
        if vim.api.nvim_buf_is_valid(new_buf) then
          setup_buf_keymaps(new_buf)
        end
        if win_valid() and vim.api.nvim_win_get_buf(state.win) == new_buf then
          pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
        end
      end)
    end,
    on_exit = function()
      vim.schedule(function()
        if not stdout_received then
          pcall(vim.fn.chanclose, chan)
          vim.fn.delete(tmpfile)
        end
      end)
    end,
  })

  -- Delete the old buffer after a short delay to avoid flicker.
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(old_buf) then
        vim.api.nvim_buf_delete(old_buf, { force = true })
      end
    end, 100)
  end
end

-- ── Fetch and display ─────────────────────────────────────────────────────────

-- Forward-declared so keymaps can call it before it is defined.
function M._fetch(slug)
  if not slug then return end
  local url = RAW_BASE .. slug .. ".md"

  -- Show "loading" only on the nofile path (terminal buffer is blank until smd runs).
  if not smd_ok() and buf_valid() then
    set_buf_content({ "  Loading " .. slug .. "…" })
    if win_valid() then
      pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
    end
  end

  local lines = {}
  vim.fn.jobstart({ "curl", "-s", "--max-time", "15", url }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(lines, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local function err(msgs)
          if smd_ok() then
            -- For the terminal path, write a temp markdown error file and run smd on it.
            local tmpfile = vim.fn.tempname() .. ".md"
            vim.fn.writefile(msgs, tmpfile)
            local new_buf = vim.api.nvim_create_buf(false, true)
            local old_buf = state.buf
            state.buf = new_buf
            if win_valid() then
              vim.api.nvim_win_set_buf(state.win, new_buf)
              vim.api.nvim_win_call(state.win, function()
                vim.fn.termopen("PAGER=cat smd " .. vim.fn.shellescape(tmpfile) .. " 2>/dev/null", {
                  on_exit = function()
                    vim.schedule(function()
                      vim.fn.delete(tmpfile)
                      if vim.api.nvim_buf_is_valid(new_buf) then
                        setup_buf_keymaps(new_buf)
                      end
                    end)
                  end,
                })
              end)
            end
            if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
              vim.defer_fn(function()
                if vim.api.nvim_buf_is_valid(old_buf) then
                  vim.api.nvim_buf_delete(old_buf, { force = true })
                end
              end, 100)
            end
          else
            set_buf_content(msgs)
          end
        end

        if code ~= 0 or #lines == 0 then
          err({
            "# Fetch failed",
            "",
            "Could not fetch: " .. url,
            "",
            "Check your internet connection or press `t` to pick another topic.",
          })
          return
        end

        -- Check for a 404 response (GitHub returns "404: Not Found")
        if #lines == 1 and lines[1]:find("404") then
          err({
            "# Page not found",
            "",
            "Slug not found: **" .. slug .. "**",
            "",
            "Press `t` to pick a topic.",
          })
          return
        end

        -- Strip YAML front matter (--- … ---) and [!INCLUDE ...] directives.
        local clean = {}
        local in_fm, fm_done = false, false
        for _, l in ipairs(lines) do
          if not fm_done then
            if l == "---" then
              if not in_fm then in_fm = true
              else fm_done = true end
              goto continue
            end
            if in_fm then goto continue end
          end
          l = l:gsub("%[!INCLUDE %[.-%]%(.-%)]", "")
          table.insert(clean, l)
          ::continue::
        end

        state.slug      = slug
        state.raw_lines = clean  -- stored for link-following fallback

        if smd_ok() then
          show_with_smd(clean)
        else
          if not buf_valid() then ensure_nofile_buf() end
          set_buf_content(clean)
          if win_valid() then
            pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
          end
        end
      end)
    end,
  })
end

-- ── Window management ─────────────────────────────────────────────────────────

local function close_panel()
  if win_valid() then
    vim.api.nvim_win_close(state.win, false)
  end
  state.win = nil
end

local function open_panel(slug)
  local prev_win = vim.api.nvim_get_current_win()

  vim.cmd("topleft vsplit")
  state.win = vim.api.nvim_get_current_win()
  apply_win_opts(state.win)

  if smd_ok() then
    -- Terminal-buffer path: each fetch_and_show creates its own buffer.
    -- Seed the panel with an empty scratch buffer until content arrives.
    if not buf_valid() then
      state.buf = vim.api.nvim_create_buf(false, true)
    end
    vim.api.nvim_win_set_buf(state.win, state.buf)
    local target = to_slug(slug) or state.slug or TOPICS[1][2]
    M._fetch(target)
  else
    -- nofile path: reuse persistent buffer.
    ensure_nofile_buf()
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.wo[state.win].conceallevel = 3
    local target = to_slug(slug) or state.slug or TOPICS[1][2]
    if target ~= state.slug or vim.api.nvim_buf_line_count(state.buf) <= 1 then
      M._fetch(target)
    end
  end

  -- Return focus to the editor.
  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.toggle(url)
  if win_valid() then
    close_panel()
  else
    open_panel(url)
  end
end

function M.topics()
  local labels = {}
  for _, t in ipairs(TOPICS) do
    table.insert(labels, t[1])
  end
  vim.ui.select(labels, { prompt = "AL Help — select topic:" }, function(choice)
    if not choice then return end
    for _, t in ipairs(TOPICS) do
      if t[1] == choice then
        if state.slug then table.insert(state.hist, state.slug) end
        if not win_valid() then open_panel(t[2]); return end
        M._fetch(t[2])
        return
      end
    end
  end)
end

return M
