-- AL Explorer: Telescope pickers for AL objects and procedures.
--
-- M.objects(root)    – all AL object declarations across project + symbol packages
-- M.procedures()     – procedures/triggers in the current file
--
-- Symbol packages (.app files in .alpackages/) are zip archives containing
-- src/*.al stubs. They are extracted once to a version-stamped cache dir and
-- re-extracted only when the .app file is newer than the cache.

local M   = {}
local lsp = require("al.lsp")

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

-- ── Symbol package cache ───────────────────────────────────────────────────────

-- Extract src/*.al from a .app symbol package into the cache.
-- Returns the cache dir (whether or not extraction happened) or nil on failure.
local function ensure_extracted(app_path)
  -- Sanitise key: remove spaces so the cache path never contains spaces
  local key   = vim.fn.fnamemodify(app_path, ":t:r"):gsub("%s+", "_")
  local dir   = CACHE .. "/" .. key
  local stamp = dir .. "/.ok"

  local app_mtime   = (vim.uv.fs_stat(app_path) or {}).mtime
  local stamp_mtime = (vim.uv.fs_stat(stamp)    or {}).mtime
  if app_mtime and stamp_mtime and stamp_mtime.sec >= app_mtime.sec then
    return dir  -- already up-to-date
  end

  vim.fn.mkdir(dir, "p")
  vim.fn.system(string.format(
    "unzip -q -o %s 'src/*.al' 'src/*.AL' -d %s",
    vim.fn.shellescape(app_path), vim.fn.shellescape(dir)))

  -- Don't rely on vim.v.shell_error (unreliable for unzip exit 1 warnings).
  -- Check whether src/ was actually created instead.
  if vim.fn.isdirectory(dir .. "/src") == 0 then
    -- Package has no AL source stubs (e.g. thin wrapper with only SymbolReference.json).
    -- Write stamp anyway so we don't re-attempt on every open.
    vim.fn.writefile({ "0" }, stamp)
    return nil
  end

  vim.fn.writefile({ tostring(os.time()) }, stamp)
  return dir
end

-- ── Telescope helpers ─────────────────────────────────────────────────────────

local function require_telescope()
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("AL Explorer: telescope.nvim not installed", vim.log.levels.ERROR)
    return false
  end
  return true
end

local function open_picker(opts)
  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = opts.title,
    finder = finders.new_table({
      results     = opts.entries,
      entry_maker = function(e)
        return {
          value    = e,
          display  = e.display,
          ordinal  = e.ordinal,
          filename = e.filename,
          lnum     = e.lnum,
          col      = 1,
        }
      end,
    }),
    sorter    = conf.generic_sorter({}),
    previewer = conf.grep_previewer({}),
    attach_mappings = function(prompt_bufnr)
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
      return true
    end,
  }):find()
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Telescope picker: all AL object declarations in the project and its symbol packages.
function M.objects(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root", vim.log.levels.ERROR)
    return
  end
  if not require_telescope() then return end

  -- Build search dirs: project root + extracted symbol caches
  local search_dirs  = { root }
  local sym_count    = 0
  local pkg_dir      = root .. "/.alpackages"
  local apps         = vim.fn.glob(pkg_dir .. "/*.app", false, true)

  for _, app in ipairs(apps) do
    local d = ensure_extracted(app)
    if d then
      table.insert(search_dirs, d)
      sym_count = sym_count + 1
    end
  end

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
    -- rg output: /path/to/file.al:42:  codeunit 50100 "My Object"
    local file, lnum, text = line:match("^(.-)%:(%d+)%:(.+)$")
    if file and lnum then
      local typ, id, rest = text:match("^%s*([%a][%a%s]-[%a])%s+(%d+)%s*(.*)")
      if typ then
        local name = (rest or ""):match('^"([^"]+)"') or (rest or ""):match("^'([^']+)'") or rest or ""
        name = name:gsub("%s+$", "")
        -- Label symbol cache paths for clarity
        local is_sym  = file:find(CACHE, 1, true)
        local src_tag = is_sym and "[sym] " or "[src] "
        local fname   = vim.fn.fnamemodify(file, ":t")
        table.insert(entries, {
          filename = file,
          lnum     = tonumber(lnum),
          ordinal  = string.format("%s %s", typ:lower():gsub("%s+", ""), name:lower()),
          display  = string.format("%s%-22s %6s  %-45s %s",
            src_tag, typ:lower(), id, name, fname),
        })
      end
    end
  end

  if #entries == 0 then
    vim.notify("AL Explorer: no objects found", vim.log.levels.WARN)
    return
  end

  open_picker({
    title   = string.format("AL Objects (%d) — %d symbol pkg(s)", #entries, sym_count),
    entries = entries,
  })
end

-- Telescope picker: procedures and triggers in the current file.
function M.procedures()
  if not require_telescope() then return end

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
      -- e.g.  "    procedure LoadPackages(FeedSetup: Record ...)"
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

  open_picker({
    title   = "AL Procedures — " .. vim.fn.fnamemodify(file, ":t"),
    entries = entries,
  })
end

return M
