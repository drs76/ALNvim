-- AL Help panel: left-side split showing MS Learn AL docs as Markdown.
--
-- Docs are fetched from the MicrosoftDocs GitHub repo (raw Markdown).
-- No browser or JS needed — content renders natively with filetype=markdown.
--
-- M.toggle()   – <leader>ah / :ALHelp         open/close panel
-- M.topics()   – <leader>aH / :ALHelpTopics   pick a topic from the curated list
--
-- Keymaps inside the panel:
--   <CR>   follow a markdown link (relative .md links open in the panel)
--   q      close the panel
--   r      reload the current page
--   t      open the topic picker

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

-- Panel state (persists across toggles so reading position is remembered).
local state = {
  win  = nil,
  buf  = nil,
  slug = nil,        -- currently displayed slug
  hist = {},         -- navigation history (list of slugs)
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function win_valid()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
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

-- ── Fetch and display ─────────────────────────────────────────────────────────

local function set_buf_content(lines)
  if not buf_valid() then return end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified   = false
end

local function fetch_and_show(slug)
  if not slug then return end
  local url = RAW_BASE .. slug .. ".md"

  set_buf_content({ "  Loading " .. slug .. "…" })
  if win_valid() then
    vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
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
        if not buf_valid() then return end
        if code ~= 0 or #lines == 0 then
          set_buf_content({
            "  ✗  Failed to fetch: " .. url,
            "",
            "  Check your internet connection or try :ALHelpTopics to pick another page.",
          })
          return
        end
        -- Check for a 404 response (GitHub returns a plain "404: Not Found" body)
        if #lines == 1 and lines[1]:find("404") then
          set_buf_content({
            "  ✗  Page not found: " .. slug,
            "",
            "  Press t to pick a topic, or try :ALHelpTopics.",
          })
          return
        end
        -- Strip YAML front matter (--- … ---) and [!INCLUDE ...] directives
        local clean = {}
        local in_fm = false
        local fm_done = false
        for _, l in ipairs(lines) do
          if not fm_done then
            if l == "---" then
              if not in_fm then in_fm = true
              else fm_done = true end
              goto continue
            end
            if in_fm then goto continue end
          end
          -- Replace [!INCLUDE [...]] with nothing (internal doc includes)
          l = l:gsub("%[!INCLUDE %[.-%]%(.-%)]", "")
          table.insert(clean, l)
          ::continue::
        end
        state.slug = slug
        set_buf_content(clean)
        if win_valid() then
          vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
        end
      end)
    end,
  })
end

-- ── Window management ─────────────────────────────────────────────────────────

local function apply_win_opts(win)
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = "no"
  vim.wo[win].winfixwidth    = true
  vim.wo[win].wrap           = true
  vim.wo[win].linebreak      = true
  vim.wo[win].conceallevel   = 2
  vim.api.nvim_win_set_width(win, 85)
end

local function setup_buf_keymaps(buf)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, desc = desc })
  end

  -- q: close panel
  map("q", function() M.toggle() end, "ALHelp: close panel")

  -- r: reload current page
  map("r", function()
    if state.slug then fetch_and_show(state.slug) end
  end, "ALHelp: reload page")

  -- t: topic picker
  map("t", function() M.topics() end, "ALHelp: topic picker")

  -- u / <BS>: back in history
  local function go_back()
    if #state.hist > 0 then
      local prev = table.remove(state.hist)
      fetch_and_show(prev)
    else
      vim.notify("ALHelp: no previous page", vim.log.levels.INFO)
    end
  end
  map("u",     go_back, "ALHelp: go back")
  map("<BS>",  go_back, "ALHelp: go back")

  -- <CR>: follow a relative markdown link on the current line
  map("<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local col  = vim.api.nvim_win_get_cursor(0)[2] + 1  -- 1-based

    -- Find the link target under/near the cursor in a markdown link [text](target)
    local target
    -- Scan all links on the line and find one whose span contains the cursor
    for text_s, text_e, link in line:gmatch("()%[.-%]()(%(([^)]+)%))")  do
      -- text_s..text_e covers [text], link covers (...)
      local full_s = text_s
      local full_e = text_e + #"(" .. #link + #")"
      if col >= full_s and col <= full_e then
        target = link:match("^%((.-)%)$") or link
        break
      end
    end
    -- Simpler fallback: just grab any (link) on the line closest to cursor
    if not target then
      target = line:match("%(([%w%-%.]+%.md[^)]*)")
                or line:match("%(([devenv][%w%-]+)%)")
    end

    if not target then
      vim.notify("ALHelp: no link here", vim.log.levels.INFO)
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
    fetch_and_show(slug)
  end, "ALHelp: follow link")
end

local function ensure_buf()
  if buf_valid() then return end
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

local function open_panel(slug)
  local prev_win = vim.api.nvim_get_current_win()
  ensure_buf()

  -- Open a new left split showing the buffer
  vim.cmd("topleft vsplit")
  state.win = vim.api.nvim_get_current_win()
  apply_win_opts(state.win)
  vim.api.nvim_win_set_buf(state.win, state.buf)

  -- Fetch content if this is a new page or buffer was just created
  local target = to_slug(slug) or state.slug or TOPICS[1][2]
  if target ~= state.slug or vim.api.nvim_buf_line_count(state.buf) <= 1 then
    fetch_and_show(target)
  end

  -- Return focus to the editor
  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end
end

local function close_panel()
  if win_valid() then
    vim.api.nvim_win_close(state.win, false)
  end
  state.win = nil
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
        fetch_and_show(t[2])
        return
      end
    end
  end)
end

return M
