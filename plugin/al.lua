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

-- vim.lsp.config/enable does not support on_new_config (nvim-lspconfig concept only),
-- so init_options cannot be set dynamically that way. Use a FileType autocmd with
-- vim.lsp.start instead, where root_dir is resolved before the client is created.
vim.api.nvim_create_autocmd("FileType", {
  pattern  = "al",
  group    = vim.api.nvim_create_augroup("ALNvimLsp", { clear = true }),
  callback = function(args)
    local root = vim.fs.root(args.buf, "app.json")
    if not root then return end
    vim.lsp.start({
      name     = "al_language_server",
      cmd      = { lsp_bin },
      root_dir = root,
      flags    = { debounce_text_changes = 300 },
      init_options = {
        workspacePath = root,
        alResourceConfigurationSettings = {
          packageCachePaths      = { root .. "/.alpackages" },
          assemblyProbingPaths   = { root .. "/.netpackages" },
          enableCodeAnalysis     = true,
          backgroundCodeAnalysis = "Project",
          enableCodeActions      = true,
          incrementalBuild       = true,
        },
      },
    }, { bufnr = args.buf })
  end,
})

-- After the AL language server attaches we need to:
--  1. Send al/setActiveWorkspace — without this the server never loads the project/symbols.
--  2. Override gd — the server uses al/gotodefinition instead of textDocument/definition
--     (definitionProvider = false in capabilities is intentional).
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("ALNvimLspAttach", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client or client.name ~= "al_language_server" then return end

    local root = client.root_dir
    if not root then return end

    -- Tell the server which workspace is active and what its settings are.
    -- This is the trigger for the server to start indexing packages and source files.
    client:request("al/setActiveWorkspace", {
      currentWorkspaceFolderPath = root,
      settings = {
        workspacePath          = root,
        packageCachePaths      = { root .. "/.alpackages" },
        assemblyProbingPaths   = { root .. "/.netpackages" },
        enableCodeAnalysis     = true,
        backgroundCodeAnalysis = "Project",
        enableCodeActions      = true,
        incrementalBuild       = true,
      },
    }, function(err, result)
      if err then
        vim.notify("AL: setActiveWorkspace error: " .. vim.inspect(err), vim.log.levels.WARN)
      elseif result and result.success == false then
        vim.notify("AL: setActiveWorkspace returned success=false", vim.log.levels.WARN)
      end
    end, args.buf)

    -- gd: use the server's custom al/gotodefinition instead of textDocument/definition.
    vim.keymap.set("n", "gd", function()
      local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
      client:request("al/gotodefinition", {
        textDocumentPositionParams = params,
      }, function(err, result)
        if err or not result then return end
        vim.lsp.util.jump_to_location(result, client.offset_encoding)
      end, args.buf)
    end, { buffer = args.buf, desc = "AL: Go to definition" })
  end,
})

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

vim.api.nvim_create_user_command("ALClearCredentials", function()
  require("al.connection").clear_credentials()
end, { desc = "Clear cached BC credentials (username/password or Entra token)" })

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
