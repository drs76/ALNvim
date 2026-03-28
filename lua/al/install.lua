-- AL Extension Installer
-- Downloads the MS AL VSCode extension from the marketplace without requiring VS Code.
-- Entry point: M.install()  →  :ALInstallExtension
--
-- Requirements: curl (built into Windows 10+, standard on Linux/macOS),
--               unzip (Linux/macOS) or tar.exe (Windows 10+)
-- Install target: ~/.vscode/extensions/ms-dynamics-smb.al-{version}/

local M = {}
local platform = require("al.platform")

local PUBLISHER = "ms-dynamics-smb"
local EXT_ID    = "al"
local GALLERY   = "https://marketplace.visualstudio.com/_apis/public/gallery"
local EXT_DIR   = vim.fn.expand("~/.vscode/extensions")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Query the VS Code marketplace gallery API for the latest published version.
local function fetch_version(cb)
  local url  = GALLERY .. "/extensionquery"
  local body = vim.fn.json_encode({
    filters = { { criteria = { { filterType = 7, value = PUBLISHER .. "." .. EXT_ID } } } },
    flags   = 514,
  })
  local out = {}
  vim.fn.jobstart({
    "curl", "-s", "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-H", "Accept: application/json;api-version=6.1-preview.1",
    "-H", "X-Market-Client-Id: VSCode",
    "--data", body,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do out[#out + 1] = line end
    end,
    on_exit = function()
      local ok, parsed = pcall(vim.fn.json_decode, table.concat(out, ""))
      local ver
      if ok and type(parsed) == "table" then
        local r = parsed.results
        ver = r and r[1] and r[1].extensions and r[1].extensions[1]
          and r[1].extensions[1].versions and r[1].extensions[1].versions[1]
          and r[1].extensions[1].versions[1].version
      end
      vim.schedule(function() cb(ver) end)
    end,
  })
end

-- VS Code uses the vsassets.io CDN, not the marketplace web URL.
-- Format: https://{publisher}.gallery.vsassets.io/_apis/public/gallery/publisher/
--           {publisher}/extension/{ext}/{version}/assetbyname/
--           Microsoft.VisualStudio.Services.VSIXPackage
local function vsix_url(version)
  return string.format(
    "https://%s.gallery.vsassets.io/_apis/public/gallery/publisher/%s/extension/%s/%s"
    .. "/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage",
    PUBLISHER, PUBLISHER, EXT_ID, version)
end

-- Return true when the file at path starts with the ZIP magic bytes "PK".
local function is_zip(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local magic = f:read(2)
  f:close()
  return magic == "PK"
end

-- Download the VSIX for a given version.
-- Uses --fail so curl exits non-zero on HTTP errors (catches HTML error pages).
-- Uses --silent --show-error to suppress the progress bar (which floods the window
-- with \r-terminated partial lines) while still reporting real errors.
local function download_vsix(version, log, cb)
  local url = vsix_url(version)
  -- Predictable cache path avoids any tempname() directory creation edge cases.
  local tmpfile = vim.fn.stdpath("cache") .. "/alnvim_al_" .. version .. ".vsix"

  log("Downloading v" .. version .. "  (~300–700 MB — this may take several minutes)")
  log("  " .. url)

  local err_lines = {}
  vim.fn.jobstart({
    "curl", "-L", "--fail", "--silent", "--show-error",
    "-H", "Accept: application/octet-stream;api-version=6.1-preview.1",
    "-H", "X-Market-Client-Id: VSCode",
    "-H", "User-Agent: VSCode/1.86.2 (X11; Linux x86_64)",
    "-o", tmpfile,
    url,
  }, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then err_lines[#err_lines + 1] = line end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          log("ERROR: download failed (curl exit " .. code .. ")")
          for _, l in ipairs(err_lines) do log("  " .. l) end
          log("Hint: check your internet connection, or that the version exists.")
          cb(nil)
          return
        end
        local size = vim.fn.getfsize(tmpfile)
        if size <= 0 then
          log("ERROR: downloaded file is empty — CDN may have blocked the request.")
          cb(nil)
          return
        end
        -- Verify ZIP magic bytes (PK) — catches HTML/JSON error pages saved as .vsix
        if not is_zip(tmpfile) then
          log(string.format("ERROR: downloaded file (%d MB) is not a ZIP archive", math.floor(size / 1048576)))
          log("  The CDN returned an error response instead of the VSIX.")
          log("  Delete the cached file and retry:  " .. tmpfile)
          local f = io.open(tmpfile, "r")
          if f then
            local first = f:read("*l")
            f:close()
            if first then log("  Starts with: " .. first:sub(1, 120)) end
          end
          cb(nil)
          return
        end
        log(string.format("Download complete: %.0f MB", size / 1048576))
        cb(tmpfile)
      end)
    end,
  })
end

-- Extract VSIX (zip) and install to EXT_DIR/ms-dynamics-smb.al-{version}/.
-- Extracts everything (no glob filter) for maximum compatibility, then moves
-- the extension/ subdirectory to the final location.
local function extract_vsix(tmpfile, version, log, cb)
  local target = EXT_DIR .. "/" .. PUBLISHER .. "." .. EXT_ID .. "-" .. version
  local tmpdir = vim.fn.stdpath("cache") .. "/alnvim_al_extract_" .. version
  vim.fn.delete(tmpdir, "rf")   -- clean any previous failed attempt
  vim.fn.mkdir(tmpdir, "p")
  log("Extracting…  (may take a minute)")

  local extract_cmd = platform.is_windows
    and { "tar", "-xf", tmpfile, "-C", tmpdir }
    or  { "unzip", "-q", "-o", tmpfile, "-d", tmpdir }

  vim.fn.jobstart(extract_cmd, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then log("  " .. line) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local src = tmpdir .. "/extension"

        -- unzip exits 1 as a non-fatal warning (e.g. one glob matched nothing).
        -- Anything >= 2 is a real error; always verify the output dir exists.
        if code >= 2 and vim.fn.isdirectory(src) == 0 then
          log("ERROR: extraction failed (exit " .. code .. ")")
          log("  The VSIX may be corrupt. Delete the cached file and retry:")
          log("  " .. tmpfile)
          vim.fn.delete(tmpdir, "rf")
          cb(false)
          return
        end

        if vim.fn.isdirectory(src) == 0 then
          log("ERROR: extension/ directory not found inside VSIX")
          log("  VSIX contents may use an unexpected layout.")
          vim.fn.delete(tmpdir, "rf")
          cb(false)
          return
        end

        vim.fn.mkdir(EXT_DIR, "p")

        -- Prefer os.rename (atomic); falls back to cp -r for cross-device moves.
        local renamed = os.rename(src, target)
        if not renamed then
          log("  (cross-device — copying…)")
          platform.copy_dir(src, target)
        end
        vim.fn.delete(tmpdir, "rf")

        if vim.fn.isdirectory(target) == 0 then
          log("ERROR: target directory was not created: " .. target)
          cb(false)
          return
        end

        -- Ensure the AL binaries are executable on Linux/macOS (no-op on Windows).
        local bin_subdir = platform.bin_subdir()
        for _, name in ipairs({ "alc", "altool", "aldoc",
                                 "Microsoft.Dynamics.Nav.EditorServices.Host" }) do
          local bin = target .. "/bin/" .. bin_subdir .. "/" .. platform.exe(name)
          if vim.fn.filereadable(bin) == 1 then
            platform.ensure_executable(bin)
          end
        end

        os.remove(tmpfile)
        log("Installed: " .. target)
        cb(true, target)
      end)
    end,
  })
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.install()
  -- Floating progress window (same style as compile.lua).
  local buf    = vim.api.nvim_create_buf(false, true)
  local width  = math.min(90, vim.o.columns - 4)
  local height = math.min(22, vim.o.lines - 4)
  local win    = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = math.floor((vim.o.lines   - height) / 2),
    col       = math.floor((vim.o.columns - width)  / 2),
    style     = "minimal",
    border    = "rounded",
    title     = " AL Extension Installer ",
    title_pos = "center",
  })
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].modifiable = false

  local function log(line)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { tostring(line) })
      vim.bo[buf].modifiable = false
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      end
    end)
  end

  local function done(success)
    vim.schedule(function()
      log("")
      log(success
        and "Done.  Open an .al file to verify LSP attaches, or run :ALInfo."
        or  "FAILED — see messages above.")
      for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, "<cmd>bdelete!<CR>", { buffer = buf, silent = true })
      end
    end)
  end

  log("AL Extension Installer")
  log(string.rep("─", width - 2))
  log("Querying VS Code marketplace…")

  fetch_version(function(version)
    if not version then
      log("ERROR: marketplace query failed — check network and try again.")
      done(false)
      return
    end
    log("Latest version: " .. version)

    local target = EXT_DIR .. "/" .. PUBLISHER .. "." .. EXT_ID .. "-" .. version
    if vim.fn.isdirectory(target) == 1 then
      log("Already installed:")
      log("  " .. target)
      done(true)
      return
    end

    download_vsix(version, log, function(tmpfile)
      if not tmpfile then
        done(false)
        return
      end
      extract_vsix(tmpfile, version, log, function(ok)
        if ok then
          local ok2, ext_path = pcall(function() return require("al.ext").reload() end)
          if ok2 and ext_path then
            log("Extension path: " .. ext_path)
          end
          -- Trigger LSP start for any AL buffers already open in this session
          vim.schedule(function()
            local triggered = 0
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "al" then
                vim.api.nvim_buf_call(bufnr, function()
                  pcall(vim.cmd, "doautocmd FileType al")
                end)
                triggered = triggered + 1
              end
            end
            if triggered > 0 then
              log(string.format("LSP start triggered for %d open AL buffer(s).", triggered))
            end
          end)
        end
        done(ok)
      end)
    end)
  end)
end

return M
