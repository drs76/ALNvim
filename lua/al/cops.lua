-- AL Code Cop selector — per-project cop configuration with live apply.
-- Config is stored in <root>/.vscode/alnvim.json so it can be git-ignored
-- or committed alongside .vscode/launch.json.
local M = {}

local COPS = {
  { token = "${CodeCop}",               name = "CodeCop",               short = "CC",  desc = "General AL coding guidelines" },
  { token = "${PerTenantExtensionCop}", name = "PerTenantExtensionCop", short = "PTE", desc = "Per-tenant extension rules" },
  { token = "${UICop}",                 name = "UICop",                 short = "UI",  desc = "UI / control add-in rules" },
  { token = "${AppSourceCop}",          name = "AppSourceCop",          short = "AS",  desc = "AppSource submission rules (strict)" },
}

-- Map from token → short abbreviation for statusline display.
local TOKEN_SHORT = {}
for _, c in ipairs(COPS) do TOKEN_SHORT[c.token] = c.short end

-- Return a compact string of active cop abbreviations, e.g. "CC·PTE·UI".
function M.short_names(tokens)
  if not tokens or #tokens == 0 then return "no cops" end
  local out = {}
  for _, t in ipairs(tokens) do
    out[#out + 1] = TOKEN_SHORT[t] or (t:match("%{(.-)%}") or t)
  end
  return table.concat(out, "·")
end

-- Default: all cops except AppSourceCop, which is project-specific.
local DEFAULT_COPS = { "${CodeCop}", "${PerTenantExtensionCop}", "${UICop}" }

local function config_path(root)
  return root .. "/.vscode/alnvim.json"
end

-- Read active cop tokens from per-project config, falling back to DEFAULT_COPS.
function M.get_active(root)
  local path = config_path(root)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return DEFAULT_COPS end
  local ok2, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok2 or type(data) ~= "table" or not data.codeAnalyzers then
    return DEFAULT_COPS
  end
  return data.codeAnalyzers
end

-- Persist cop selection for a project.
function M.set_active(root, cops)
  local path = config_path(root)
  vim.fn.mkdir(root .. "/.vscode", "p")
  -- Preserve any other keys already in alnvim.json
  local data = {}
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and lines and #lines > 0 then
    local ok2, existing = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
    if ok2 and type(existing) == "table" then data = existing end
  end
  data.codeAnalyzers = cops
  vim.fn.writefile({ vim.fn.json_encode(data) }, path)
end

-- Re-send al/setActiveWorkspace with updated cops so changes take effect
-- immediately without restarting the LSP server.
-- Pass silent=true to suppress the "AL cops: ..." notification (used for auto-sends).
function M.apply(root, cops, silent)
  local clients = vim.lsp.get_clients({ name = "al_language_server" })
  local client
  for _, c in ipairs(clients) do
    if c.config.root_dir == root then client = c; break end
  end
  if not client then
    if not silent then
      vim.notify("AL cops: no active LSP client for " .. root, vim.log.levels.WARN)
    end
    return
  end

  local app_json = require("al.lsp").read_app_json(root)
  local proj_refs = {}
  for _, dep in ipairs((app_json and app_json.dependencies) or {}) do
    if dep.id then
      proj_refs[#proj_refs + 1] = {
        appId     = dep.id,
        name      = dep.name      or "",
        publisher = dep.publisher or "",
        version   = dep.version   or "0.0.0.0",
      }
    end
  end

  client:request("al/setActiveWorkspace", {
    currentWorkspaceFolderPath = {
      uri   = "file://" .. root,
      name  = vim.fn.fnamemodify(root, ":t"),
      index = 0,
    },
    settings = {
      workspacePath = root,
      alResourceConfigurationSettings = {
        packageCachePaths      = { root .. "/.alpackages" },
        assemblyProbingPaths   = {},
        codeAnalyzers          = cops,
        enableCodeAnalysis     = true,
        backgroundCodeAnalysis = "Project",
        enableCodeActions      = true,
        incrementalBuild       = true,
      },
      setActiveWorkspace                  = true,
      dependencyParentWorkspacePath       = vim.NIL,
      expectedProjectReferenceDefinitions = proj_refs,
      activeWorkspaceClosure              = {},
    },
  }, function() end, 0)

  if not silent then
    local names = vim.tbl_map(function(t) return t:match("%{(.-)%}") or t end, cops)
    vim.notify("AL cops: " .. (#cops > 0 and table.concat(names, ", ") or "none"), vim.log.levels.INFO)
  end
  require("al.status").set_cops(cops)
end

-- ── Pickers ────────────────────────────────────────────────────────────────

local function apply_selection(root, selected_tokens)
  M.set_active(root, selected_tokens)
  M.apply(root, selected_tokens)
end

-- Telescope multi-select picker.
local function telescope_picker(root, active_set)
  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "AL Code Cops  (<Tab> toggle, <CR> apply)",
    finder = finders.new_table({
      results = COPS,
      entry_maker = function(cop)
        local mark = active_set[cop.token] and "[x]" or "[ ]"
        return {
          value   = cop.token,
          display = mark .. "  " .. cop.name .. "  —  " .. cop.desc,
          ordinal = cop.name,
          -- pre-select active cops so they show as selected on open
          _active = active_set[cop.token] or false,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      -- Apply on <CR>
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        -- If nothing multi-selected, treat the current entry as toggled
        if #selections == 0 then
          local entry = action_state.get_selected_entry()
          if entry then selections = { entry } end
        end
        actions.close(prompt_bufnr)
        local tokens = vim.tbl_map(function(s) return s.value end, selections)
        apply_selection(root, tokens)
      end)

      map({ "i", "n" }, "<Tab>", actions.toggle_selection + actions.move_selection_next)
      return true
    end,
  }):find()
end

-- Fallback: iterative vim.ui.select toggle (no Telescope required).
local function simple_picker(root, active_set)
  local state = vim.deepcopy(active_set)

  local function show()
    local items = {}
    for _, cop in ipairs(COPS) do
      items[#items + 1] = (state[cop.token] and "[x]  " or "[ ]  ") .. cop.name .. " — " .. cop.desc
    end
    items[#items + 1] = "─── Apply ───"
    items[#items + 1] = "─── Cancel ───"

    vim.ui.select(items, { prompt = "AL Code Cops (select to toggle):" }, function(choice, idx)
      if not choice or idx == #items then return end  -- Cancel
      if idx == #items - 1 then                       -- Apply
        local tokens = {}
        for _, cop in ipairs(COPS) do
          if state[cop.token] then tokens[#tokens + 1] = cop.token end
        end
        apply_selection(root, tokens)
        return
      end
      -- Toggle the selected cop and re-show
      local cop = COPS[idx]
      state[cop.token] = not state[cop.token]
      show()
    end)
  end

  show()
end

-- ── Browser setting ────────────────────────────────────────────────────────
-- Stored in .vscode/alnvim.json as { "browser": "<cmd>" }.
-- Empty string means "system default" (xdg-open / open / start).

-- Platform-appropriate browser choices.
local function browser_choices()
  local p = require("al.platform")
  if p.is_windows then
    return {
      { label = "Default (system)",  value = "" },
      { label = "Google Chrome",     value = "chrome" },
      { label = "Microsoft Edge",    value = "msedge" },
      { label = "Firefox",           value = "firefox" },
      { label = "Custom…",           value = nil },
    }
  elseif p.is_mac then
    return {
      { label = "Default (system)",  value = "" },
      { label = "Google Chrome",     value = "Google Chrome" },
      { label = "Microsoft Edge",    value = "Microsoft Edge" },
      { label = "Firefox",           value = "Firefox" },
      { label = "Chromium",          value = "Chromium" },
      { label = "Custom…",           value = nil },
    }
  else
    return {
      { label = "Default (system)",  value = "" },
      { label = "Google Chrome",     value = "google-chrome" },
      { label = "Chromium",          value = "chromium" },
      { label = "Microsoft Edge",    value = "microsoft-edge" },
      { label = "Firefox",           value = "firefox" },
      { label = "Custom…",           value = nil },
    }
  end
end

-- Read the configured browser for a project ("" = system default).
function M.get_browser(root)
  if not root then return "" end
  local path = config_path(root)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return "" end
  local ok2, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok2 or type(data) ~= "table" then return "" end
  return data.browser or ""
end

-- Persist the browser choice for a project.
function M.set_browser(root, browser)
  local path = config_path(root)
  vim.fn.mkdir(root .. "/.vscode", "p")
  local data = {}
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and lines and #lines > 0 then
    local ok2, existing = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
    if ok2 and type(existing) == "table" then data = existing end
  end
  data.browser = browser
  vim.fn.writefile({ vim.fn.json_encode(data) }, path)
end

-- Public entry point: `:ALSelectBrowser`
function M.select_browser()
  local root = require("al.lsp").get_root()
  if not root then
    vim.notify("AL browser: no project root (app.json) found", vim.log.levels.WARN)
    return
  end

  local current = M.get_browser(root)
  local choices = browser_choices()

  local labels = vim.tbl_map(function(c)
    local mark = (c.value == current) and "  ◆  " or "     "
    return mark .. c.label
  end, choices)

  vim.ui.select(labels, { prompt = "AL: Select browser for BC launch:" }, function(_, idx)
    if not idx then return end
    local chosen = choices[idx]
    if not chosen then return end

    if chosen.value == nil then
      -- Custom — prompt for executable
      vim.ui.input({
        prompt = "Browser executable / path: ",
        default = current,
      }, function(input)
        if input == nil then return end
        M.set_browser(root, input)
        local display = input == "" and "system default" or input
        vim.notify("AL browser: set to " .. display, vim.log.levels.INFO)
      end)
    else
      M.set_browser(root, chosen.value)
      local display = chosen.value == "" and "system default" or chosen.value
      vim.notify("AL browser: set to " .. display, vim.log.levels.INFO)
    end
  end)
end

-- Public entry point: `:ALSelectCops`
function M.picker()
  local root = require("al.lsp").get_root()
  if not root then
    vim.notify("AL cops: no project root (app.json) found", vim.log.levels.WARN)
    return
  end

  local active = M.get_active(root)
  local active_set = {}
  for _, t in ipairs(active) do active_set[t] = true end

  if pcall(require, "telescope") then
    telescope_picker(root, active_set)
  else
    simple_picker(root, active_set)
  end
end

return M
