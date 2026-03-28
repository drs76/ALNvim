-- AL Extension Installer
-- Downloads the MS AL VSCode extension from the marketplace without requiring VS Code.
-- Entry point: M.install()  →  :ALInstallExtension
--
-- Requirements: curl, unzip (standard on Linux)
-- Install target: ~/.vscode/extensions/ms-dynamics-smb.al-{version}/

local M = {}

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
    "--data", body,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        out[#out + 1] = line
      end
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

-- Download the VSIX for a given version to a temp file.
-- curl --progress-bar sends its progress to stderr; we forward it to the log window.
local function download_vsix(version, log, cb)
  local url     = GALLERY .. "/publishers/" .. PUBLISHER
                  .. "/vsextensions/" .. EXT_ID .. "/" .. version .. "/vspackage"
  local tmpfile = vim.fn.tempname() .. ".vsix"
  log("Downloading v" .. version .. "  (~683 MB — this will take a while…)")
  log("From: " .. url)

  vim.fn.jobstart({
    "curl", "-L", "--progress-bar", "-o", tmpfile, url,
  }, {
    stderr_buffered = false,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then log(line) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 and vim.fn.getfsize(tmpfile) > 0 then
          cb(tmpfile)
        else
          cb(nil)
        end
      end)
    end,
  })
end

-- Extract VSIX (zip) and install to EXT_DIR/ms-dynamics-smb.al-{version}/.
-- VSIX contents are rooted under extension/ inside the zip.
local function extract_vsix(tmpfile, version, log, cb)
  local target = EXT_DIR .. "/" .. PUBLISHER .. "." .. EXT_ID .. "-" .. version
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  log("Extracting…")

  vim.fn.jobstart({
    "unzip", "-q", "-o", tmpfile, "extension/*", "-d", tmpdir,
  }, {
    on_exit = function(_, code)
      vim.schedule(function()
        local src = tmpdir .. "/extension"
        -- unzip exits 1 as a warning when a glob pattern matches nothing — not fatal.
        -- Check for the extracted directory instead.
        if vim.fn.isdirectory(src) == 0 then
          log("ERROR: unzip failed (exit " .. code .. ") — src dir not found")
          vim.fn.delete(tmpdir, "rf")
          cb(false)
          return
        end

        vim.fn.mkdir(EXT_DIR, "p")

        -- Prefer os.rename (atomic, zero-copy); falls back to cp -r on cross-device moves.
        local ok = os.rename(src, target)
        if not ok then
          log("(cross-device move — copying…)")
          vim.fn.system({ "cp", "-r", src .. "/.", target })
        end
        vim.fn.delete(tmpdir, "rf")

        if vim.fn.isdirectory(target) == 0 then
          log("ERROR: installation directory not created")
          cb(false)
          return
        end

        -- Set execute bit on the AL binaries (they ship without it).
        local bins = {
          target .. "/bin/linux/alc",
          target .. "/bin/linux/altool",
          target .. "/bin/linux/aldoc",
          target .. "/bin/linux/Microsoft.Dynamics.Nav.EditorServices.Host",
        }
        for _, bin in ipairs(bins) do
          if vim.fn.filereadable(bin) == 1 then
            vim.uv.fs_chmod(bin, 73)  -- octal 0o111 in decimal
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
      log(success
        and "✓ Done.  Restart Neovim or run :ALInfo to confirm."
        or  "✗ FAILED — see output above.")
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
      log("Already installed at:")
      log("  " .. target)
      done(true)
      return
    end

    download_vsix(version, log, function(tmpfile)
      if not tmpfile then
        log("ERROR: download failed — check network / disk space.")
        done(false)
        return
      end

      extract_vsix(tmpfile, version, log, function(ok)
        if ok then
          -- Refresh ext.lua path cache so LSP/compile work without a restart.
          local new_path = require("al.ext").reload()
          if new_path then
            log("Extension path updated: " .. new_path)
          end
        end
        done(ok)
      end)
    end)
  end)
end

return M
