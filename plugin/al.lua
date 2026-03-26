-- ALNvim – auto-loaded plugin entry point
-- Runs once per Neovim session when the plugin is on the packpath.
if vim.g.vscode or vim.g.alnvim_loaded then return end
vim.g.alnvim_loaded = true

-- ── AL Language Server (Microsoft.Dynamics.Nav.EditorServices.Host) ──────────
-- The binary communicates via standard LSP over stdio.
-- It must be executable; we set that here because the VSCode extension ships
-- it without the exec bit on Linux.
local ext_path  = require("al.ext").path
if not ext_path then return end   -- ext.lua already notified the user
local lsp_bin   = ext_path .. "/bin/linux/Microsoft.Dynamics.Nav.EditorServices.Host"

-- Make both binaries executable (best-effort; errors are silent)
for _, bin in ipairs({ lsp_bin, ext_path .. "/bin/linux/alc" }) do
  local stat = vim.uv.fs_stat(bin)
  if stat and bit.band(stat.mode, 73) == 0 then
    vim.uv.fs_chmod(bin, bit.bor(stat.mode, 73))
  end
end

vim.lsp.config("al_language_server", {
  cmd        = { lsp_bin },
  filetypes  = { "al" },
  -- Root is the directory that contains app.json
  root_markers = { "app.json" },
  settings   = {},
  -- The AL server is sometimes slow to start; give it extra time.
  flags      = { debounce_text_changes = 300 },
})

vim.lsp.enable("al_language_server")

-- ── User commands ─────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("ALCompile", function(opts)
  require("al.compile").compile(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = "dir",
  desc  = "Compile the AL project with alc",
})

vim.api.nvim_create_user_command("ALPublish", function(opts)
  require("al.publish").publish(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = "dir",
  desc  = "Compile then publish the AL app to Business Central",
})

vim.api.nvim_create_user_command("ALPublishOnly", function(opts)
  require("al.publish").publish(opts.args ~= "" and opts.args or nil, true)
end, {
  nargs = "?",
  complete = "dir",
  desc  = "Publish existing .app to Business Central (skip compile)",
})

vim.api.nvim_create_user_command("ALDownloadSymbols", function(opts)
  require("al.symbols").download(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = "dir",
  desc  = "Download AL symbol packages (.app) from Business Central",
})

vim.api.nvim_create_user_command("ALSnapshotStart", function()
  require("al.debug").snapshot_start()
end, { desc = "Start a BC snapshot debugging session" })

vim.api.nvim_create_user_command("ALSnapshotFinish", function()
  require("al.debug").snapshot_finish()
end, { desc = "Finish snapshot session and download the snapshot file" })

vim.api.nvim_create_user_command("ALDebugSetup", function()
  require("al.debug").setup_dap()
end, { desc = "Configure nvim-dap for AL live attach debugging" })

vim.api.nvim_create_user_command("ALOpenAppJson", function()
  require("al.compile").open_app_json()
end, { desc = "Open the project's app.json" })

vim.api.nvim_create_user_command("ALOpenLaunchJson", function()
  require("al.compile").open_launch_json()
end, { desc = "Open .vscode/launch.json for the AL project" })

vim.api.nvim_create_user_command("ALReloadSnippets", function()
  require("al.snippets").reload()
end, { desc = "Reload AL LuaSnip snippets" })

vim.api.nvim_create_user_command("ALInfo", function()
  local lsp = require("al.lsp")
  local root = lsp.get_root()
  local app  = lsp.read_app_json(root)
  local lines = {
    "ALNvim info",
    "──────────────────────────────────",
    "Extension : " .. ext_path,
    "LSP binary: " .. lsp_bin,
    "Project   : " .. (root or "(not found)"),
  }
  if app then
    table.insert(lines, string.format("App       : %s – %s (v%s)",
      app.publisher or "?", app.name or "?", app.version or "?"))
  end
  print(table.concat(lines, "\n"))
end, { desc = "Show ALNvim / project information" })
