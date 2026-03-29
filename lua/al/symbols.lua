-- Download AL symbol packages (.app files) from the Business Central dev endpoint
-- into the project's .alpackages/ directory.
--
-- Each entry in app.json "dependencies" maps to one GET request:
--   <base>/dev/packages?publisher=<p>&appName=<n>&versionText=<v>&tenant=<t>
--
-- All downloads run in parallel via vim.fn.jobstart.

local M   = {}
local conn = require("al.connection")
local lsp  = require("al.lsp")

local function packages_url(base, dep, tenant)
  return string.format(
    "%s/dev/packages?publisher=%s&appName=%s&versionText=%s&tenant=%s",
    base,
    conn.urlencode(dep.publisher or ""),
    conn.urlencode(dep.name or ""),
    conn.urlencode(dep.version or ""),
    conn.urlencode(tenant))
end

-- Sanitise a string for use in a filename (replace path separators).
local function safe_name(s)
  return (s or "Unknown"):gsub("[/\\%?%%*:|\"<>]", "_")
end

-- Open a floating window listing all packages with live status indicators.
-- Returns (buf, win, first_pkg_line) where first_pkg_line is the 0-based line
-- index of the first package entry (used to update individual rows).
local function open_symbols_win(deps, base)
  -- Header + blank line, then one line per package
  local lines = { "  " .. base .. "  ", "" }
  for _, dep in ipairs(deps) do
    table.insert(lines, "  …  " .. (dep.publisher or "") .. " / " .. (dep.name or ""))
  end

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 4) end
  width = math.max(width, 52)
  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local ui  = vim.api.nvim_list_uis()[1]
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width  - width)  / 2)

  local win = vim.api.nvim_open_win(buf, false, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " AL: Downloading Symbols ",
    title_pos = "center",
    noautocmd = true,
  })
  vim.wo[win].wrap = false

  -- Highlight the header line dimly
  local ns = vim.api.nvim_create_namespace("al_symbols")
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 0, 0, -1)

  return buf, win, ns
end

-- Update a single package row: replace spinner with ✓ or ✗ and apply highlight.
local function set_pkg_status(buf, ns, line_idx, dep, ok)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local icon = ok and "✓" or "✗"
  local text = "  " .. icon .. "  " .. (dep.publisher or "") .. " / " .. (dep.name or "")
  vim.api.nvim_buf_set_lines(buf, line_idx, line_idx + 1, false, { text })
  vim.api.nvim_buf_add_highlight(buf, ns, ok and "DiagnosticOk" or "DiagnosticError",
    line_idx, 0, -1)
end

-- Append a summary line and close the window after a short delay.
local function finish_win(buf, win, ns, failed_count)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local summary, hl
  if failed_count == 0 then
    summary = "  All packages downloaded successfully"
    hl = "DiagnosticOk"
  else
    summary = string.format("  %d package(s) failed — see :messages", failed_count)
    hl = "DiagnosticError"
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", summary })
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_add_highlight(buf, ns, hl, last - 1, 0, -1)
  -- Resize window to fit the new line
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_height(win, last)
  end
  -- Auto-close after 3 s on success, leave open on failure so user can read it
  if failed_count == 0 then
    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, 3000)
  else
    -- Allow manual close with q / <Esc>
    vim.keymap.set("n", "q",     "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end
end

function M.download(root)
  root = root or lsp.get_root()
  if not root then
    vim.notify("AL: No project root found (missing app.json)", vim.log.levels.ERROR)
    return
  end

  local app = lsp.read_app_json(root)
  if not app then
    vim.notify("AL: Cannot read app.json", vim.log.levels.ERROR)
    return
  end

  local cfg = conn.read_launch(root)
  if not cfg then
    vim.notify("AL: No AL launch config found in .vscode/launch.json", vim.log.levels.ERROR)
    return
  end

  -- Build the download list from explicit dependencies plus implicit Microsoft
  -- base packages that are always required for full type resolution.
  local deps = {}
  local base_pkgs = {
    { publisher = "Microsoft", name = "System",              version = app.platform    or "0.0.0.0" },
    { publisher = "Microsoft", name = "System Application",  version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "Business Foundation", version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "Base Application",    version = app.application or "0.0.0.0" },
    { publisher = "Microsoft", name = "Application",         version = app.application or "0.0.0.0" },
  }
  for _, bp in ipairs(base_pkgs) do
    local found = false
    for _, d in ipairs(app.dependencies or {}) do
      if d.publisher == bp.publisher and d.name == bp.name then
        found = true; break
      end
    end
    if not found then table.insert(deps, bp) end
  end
  for _, d in ipairs(app.dependencies or {}) do
    table.insert(deps, d)
  end

  local pkgdir = root .. "/.alpackages"
  vim.fn.mkdir(pkgdir, "p")

  local base   = conn.base_url(cfg)
  local tenant = cfg.primaryTenantDomain or cfg.tenant or "default"
  local auth   = conn.curl_auth(cfg)

  -- Open the progress float (header + blank + one row per package)
  local buf, win, ns = open_symbols_win(deps, base)
  -- Package rows start at line index 2 (0-based)
  local PKG_LINE_OFFSET = 2

  local pending = #deps
  local failed  = {}

  for idx, dep in ipairs(deps) do
    local url     = packages_url(base, dep, tenant)
    local outfile = string.format("%s/%s_%s_%s.app",
      pkgdir, safe_name(dep.publisher), safe_name(dep.name), dep.version or "0.0.0.0")
    local line_idx = PKG_LINE_OFFSET + idx - 1  -- 0-based row for this package

    -- -sLS: silent progress but show errors; -L: follow redirects; --fail: non-zero on HTTP error
    local cmd = { "curl", "-sLS", "--fail" }
    vim.list_extend(cmd, auth)
    vim.list_extend(cmd, { "-o", outfile, url })

    local err_buf = {}
    vim.fn.jobstart(cmd, {
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(err_buf, line) end
        end
      end,
      on_exit = vim.schedule_wrap(function(_, code)
        pending = pending - 1
        local ok = code == 0
        set_pkg_status(buf, ns, line_idx, dep, ok)
        if not ok then
          local label  = (dep.publisher or "") .. " / " .. (dep.name or "")
          local detail = #err_buf > 0 and ("\n  " .. table.concat(err_buf, " ")) or ""
          table.insert(failed, label .. "\n  URL: " .. url .. detail)
          pcall(vim.uv.fs_unlink, outfile)
        end
        if pending == 0 then
          finish_win(buf, win, ns, #failed)
          if #failed > 0 then
            vim.notify(
              "AL: Failed to download:\n" .. table.concat(failed, "\n"),
              vim.log.levels.WARN)
          end
        end
      end),
    })
  end
end

return M
