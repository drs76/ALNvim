-- AL Explorer: Telescope pickers for AL objects and procedures.
--
-- M.objects(root)    – all AL object declarations across project + symbol packages
-- M.procedures()     – procedures/triggers in the current file
-- M.search(root)     – live grep across all AL files (project + symbol packages)
--
-- Inside the objects picker:
--   <C-s>  cycle sort mode: type → id → publisher → name
--   <C-f>  jump to live grep across all AL files

local M        = {}
local lsp      = require("al.lsp")
local platform = require("al.platform")

-- Check once at load time; warn clearly rather than hanging on missing rg.
local function check_rg()
  if vim.fn.executable("rg") == 0 then
    vim.notify(
      "AL Explorer: ripgrep (rg) not found on PATH.\n"
      .. "Install from https://github.com/BurntSushi/ripgrep/releases",
      vim.log.levels.ERROR)
    return false
  end
  return true
end

local CACHE = vim.fn.stdpath("cache") .. "/alnvim/symbols"

local OBJ_PAT = table.concat({
  "^\\s*(",
  "table|tableextension|page|pageextension|pagecustomization|",
  "codeunit|report|reportextension|query|xmlport|",
  "enum|enumextension|interface|permissionset|permissionsetextension|",
  "profile|profileextension|controladdin",
  ")\\s+[0-9]+",
}, "")

local PROC_PAT =
  "^\\s*(procedure|trigger|local procedure|internal procedure|" ..
  "protected procedure|public procedure)\\s+[A-Za-z_]"

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Extract publisher from a .app filename.
-- Format: "Publisher_Name_Major.Minor.Build.Rev.app"
-- e.g.  "Continia Software_Continia Document Capture_10.0.1.55527.app" → "Continia Software"
local function publisher_from_app(app_path)
  local base = vim.fn.fnamemodify(app_path, ":t:r")
  -- Strip trailing version segment  _N.N.N.N
  local without_ver = base:gsub("_%d+%.%d+%.%d+%.%d+$", "")
  -- Publisher is everything before the first underscore
  return without_ver:match("^([^_]+)") or "Unknown"
end

-- ── Symbol package cache ──────────────────────────────────────────────────────

local function ensure_extracted(app_path)
  local key   = vim.fn.fnamemodify(app_path, ":t:r"):gsub("%s+", "_")
  local dir   = CACHE .. "/" .. key
  local stamp = dir .. "/.ok"

  local app_mtime   = (vim.uv.fs_stat(app_path) or {}).mtime
  local stamp_mtime = (vim.uv.fs_stat(stamp)    or {}).mtime
  if app_mtime and stamp_mtime and stamp_mtime.sec >= app_mtime.sec then
    return vim.fn.isdirectory(dir .. "/src") == 1 and dir or nil
  end

  vim.fn.mkdir(dir, "p")
  platform.extract_zip(app_path, dir, { "src/*.al", "src/*.AL" })

  -- Check whether src/ was actually created rather than relying on exit code
  -- (unzip returns 1 as a warning when one glob matches nothing — not a failure;
  --  tar on Windows extracts fully so src/ will be present if the app has AL sources)
  if vim.fn.isdirectory(dir .. "/src") == 0 then
    vim.fn.writefile({ "0" }, stamp)  -- stamp to skip future retries
    return nil
  end

  vim.fn.writefile({ tostring(os.time()) }, stamp)
  return dir
end

-- ── Entry builder ─────────────────────────────────────────────────────────────

local function make_entry(e)
  return {
    value    = e,
    display  = e.display,
    ordinal  = e.ordinal,
    filename = e.filename,
    lnum     = e.lnum,
    col      = 1,
  }
end

-- ── Sort ─────────────────────────────────────────────────────────────────────

local SORT_MODES = { "type", "id", "publisher", "name" }

local sort_fns = {
  type = function(a, b)
    if a.obj_type ~= b.obj_type then return a.obj_type < b.obj_type end
    return a.obj_name < b.obj_name
  end,
  id = function(a, b)
    return (a.obj_id or 0) < (b.obj_id or 0)
  end,
  publisher = function(a, b)
    if a.publisher ~= b.publisher then return a.publisher < b.publisher end
    return a.obj_name < b.obj_name
  end,
  name = function(a, b)
    return a.obj_name < b.obj_name
  end,
}

-- ── Shared: build search dirs from project root + symbol caches ───────────────

-- Returns: search_dirs (list), sym_map (dir→publisher), sym_count (int)
local function build_search_dirs(root)
  local search_dirs = { root }
  local sym_map     = {}
  local sym_count   = 0
  local apps        = vim.fn.glob(root .. "/.alpackages/*.app", false, true)
  for _, app in ipairs(apps) do
    local d = ensure_extracted(app)
    if d then
      table.insert(search_dirs, d)
      sym_map[d]  = publisher_from_app(app)
      sym_count   = sym_count + 1
    end
  end
  return search_dirs, sym_map, sym_count
end

-- Expose so wizard.lua can reuse the same search-dir logic.
M.build_search_dirs = build_search_dirs

-- ── Public API ────────────────────────────────────────────────────────────────

function M.objects(root)
  if not check_rg() then return end
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root", vim.log.levels.ERROR)
    return
  end

  local ok_tel, _ = pcall(require, "telescope")
  if not ok_tel then
    vim.notify("AL Explorer: telescope.nvim not installed", vim.log.levels.ERROR)
    return
  end

  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- Build search dirs: project root + extracted symbol caches
  local search_dirs, sym_map, sym_count = build_search_dirs(root)

  -- Project publisher from app.json
  local app_json         = lsp.read_app_json(root)
  local project_publisher = (app_json and app_json.publisher) or "Project"

  -- Run rg across all dirs
  local cmd = {
    "rg", "--line-number", "--no-heading", "--color=never",
    "--glob", "*.al", "--glob", "*.AL",
    "-e", OBJ_PAT,
  }
  vim.list_extend(cmd, search_dirs)

  local raw     = vim.fn.systemlist(cmd)
  local entries = {}

  for _, line in ipairs(raw) do
    local file, lnum, text = line:match("^(.-)%:(%d+)%:(.+)$")
    if file and lnum then
      local typ, id, rest = text:match("^%s*([%a][%a%s]-[%a])%s+(%d+)%s*(.*)")
      if typ then
        local name = rest:match('^"([^"]+)"') or rest:match("^'([^']+)'") or rest:gsub("%s+$","")
        local obj_id = tonumber(id) or 0

        -- Determine publisher: check if file is under any sym cache dir
        local publisher = project_publisher
        local is_sym    = false
        for sym_dir, pub in pairs(sym_map) do
          if file:sub(1, #sym_dir) == sym_dir then
            publisher = pub
            is_sym    = true
            break
          end
        end

        local src_tag  = is_sym and "[sym]" or "[src]"
        local fname    = vim.fn.fnamemodify(file, ":t")
        local typ_norm = typ:lower():gsub("%s+", "")

        table.insert(entries, {
          filename  = file,
          lnum      = tonumber(lnum),
          publisher = publisher,
          obj_type  = typ_norm,
          obj_id    = obj_id,
          obj_name  = name,
          ordinal   = string.format("%s %s %d %s", publisher:lower(), typ_norm, obj_id, name:lower()),
          display   = string.format("%s %-20s %-18s %6d  %-45s %s",
            src_tag, publisher, typ_norm, obj_id, name, fname),
        })
      end
    end
  end

  if #entries == 0 then
    vim.notify("AL Explorer: no objects found", vim.log.levels.WARN)
    return
  end

  -- Default sort: by object type then name
  local sort_idx = 1
  table.sort(entries, sort_fns.type)

  local function make_finder()
    return finders.new_table({ results = entries, entry_maker = make_entry })
  end

  pickers.new({}, {
    prompt_title  = string.format("AL Objects (%d) — %d symbol pkg(s)  [<C-s> sort]", #entries, sym_count),
    finder        = make_finder(),
    sorter        = conf.generic_sorter({}),
    previewer     = conf.grep_previewer({}),
    layout_config = {
      preview_width = 0.35,   -- preview takes 35% of width; results get the rest
    },
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then
          if vim.api.nvim_buf_get_name(0) ~= sel.filename then
            vim.cmd("edit " .. vim.fn.fnameescape(sel.filename))
          end
          vim.api.nvim_win_set_cursor(0, { sel.lnum, 0 })
          vim.cmd("normal! zz")
        end
      end)

      -- <C-s>: cycle sort mode and refresh picker
      map({ "i", "n" }, "<C-s>", function()
        sort_idx = (sort_idx % #SORT_MODES) + 1
        local mode = SORT_MODES[sort_idx]
        table.sort(entries, sort_fns[mode])
        local picker = action_state.get_current_picker(prompt_bufnr)
        picker:refresh(make_finder(), { reset_prompt = false })
        vim.notify("AL Explorer: sort by " .. mode, vim.log.levels.INFO)
      end)

      -- <C-f>: jump to live grep across all AL files (search within objects)
      map({ "i", "n" }, "<C-f>", function()
        actions.close(prompt_bufnr)
        M.search(root)
      end)

      -- Horizontal scroll: <S-Left>/<S-Right> scroll the results list;
      -- <A-Left>/<A-Right> scroll the preview pane.
      map({ "i", "n" }, "<S-Left>",  actions.results_scrolling_left)
      map({ "i", "n" }, "<S-Right>", actions.results_scrolling_right)
      map({ "i", "n" }, "<A-Left>",  actions.preview_scrolling_left)
      map({ "i", "n" }, "<A-Right>", actions.preview_scrolling_right)

      return true
    end,
  }):find()
end

-- Telescope picker: procedures and triggers in the current file.
function M.procedures()
  if not check_rg() then return end
  local ok_tel, _ = pcall(require, "telescope")
  if not ok_tel then
    vim.notify("AL Explorer: telescope.nvim not installed", vim.log.levels.ERROR)
    return
  end

  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("AL: Buffer has no file", vim.log.levels.ERROR)
    return
  end

  local raw     = vim.fn.systemlist({ "rg", "--line-number", "--no-heading",
                                       "--color=never", "-e", PROC_PAT, file })
  local entries = {}

  for _, line in ipairs(raw) do
    local lnum, text = line:match("^(%d+)%:(.+)$")
    if lnum then
      local kind, name = text:match("^%s*(.-)%s+([%w_]+)%(")
      if name then
        table.insert(entries, {
          filename = file,
          lnum     = tonumber(lnum),
          ordinal  = name:lower(),
          display  = string.format("%-40s  %s", name, (kind or ""):gsub("%s+", " ")),
        })
      end
    end
  end

  if #entries == 0 then
    vim.notify("AL Explorer: no procedures found in this file", vim.log.levels.WARN)
    return
  end

  pickers.new({}, {
    prompt_title = "AL Procedures — " .. vim.fn.fnamemodify(file, ":t"),
    finder = finders.new_table({ results = entries, entry_maker = make_entry }),
    sorter    = conf.generic_sorter({}),
    previewer = conf.grep_previewer({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then
          vim.api.nvim_win_set_cursor(0, { sel.lnum, 0 })
          vim.cmd("normal! zz")
        end
      end)
      return true
    end,
  }):find()
end

-- Telescope live-grep across all AL files (project + symbol packages).
function M.search(root)
  if not check_rg() then return end
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root", vim.log.levels.ERROR)
    return
  end

  local ok_tel, _ = pcall(require, "telescope")
  if not ok_tel then
    vim.notify("AL Explorer: telescope.nvim not installed", vim.log.levels.ERROR)
    return
  end

  local builtin = require("telescope.builtin")
  local search_dirs = build_search_dirs(root)

  builtin.live_grep({
    prompt_title  = "AL Search",
    search_dirs   = search_dirs,
    glob_pattern  = { "*.al", "*.AL" },
    additional_args = { "--smart-case" },
  })
end

return M
