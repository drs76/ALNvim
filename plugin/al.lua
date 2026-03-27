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
    -- assemblyProbingPaths must be a non-null array; omitting it crashes the server.
    -- The default in the VSCode extension is ['./.netpackages'], but probing a
    -- network-mounted path blocks indefinitely. Send an empty array — the server
    -- skips .NET assembly probing, which is correct for Cloud-target projects.
    -- Users who need on-prem .NET assembly probing can add paths via config.
    local res_cfg = {
      packageCachePaths      = { root .. "/.alpackages" },
      assemblyProbingPaths   = {},
      enableCodeAnalysis     = true,
      backgroundCodeAnalysis = "Project",
      enableCodeActions      = true,
      incrementalBuild       = true,
    }

    vim.lsp.start({
      name     = "al_language_server",
      cmd      = { lsp_bin },
      root_dir = root,
      init_options = {
        workspacePath = root,
        alResourceConfigurationSettings = res_cfg,
      },
    }, { bufnr = args.buf })
  end,
})

-- The server sends al/activeProjectLoaded as a REQUEST (not notification) when it has
-- finished loading the active project. Without a handler Neovim responds with an error
-- and the server stays in a broken state. Respond with null and notify the user.
vim.lsp.handlers["al/activeProjectLoaded"] = function(err, result, ctx)
  if not err then
    vim.notify("AL: project loaded — gd and K ready", vim.log.levels.WARN)
  end
  return vim.NIL  -- server-initiated request: must respond with null
end

-- Show loading progress so the user knows the server is working.
-- al/progressNotification is a server notification: { owner=string, percent=number, cancel=bool }
vim.lsp.handlers["al/progressNotification"] = function(err, result, ctx)
  if result and result.percent then
    vim.notify(string.format("AL: loading… %d%%", result.percent), vim.log.levels.INFO)
  end
end

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

    -- The AL server sends completion labels as { label = "..." } objects instead of strings.
    -- nvim-cmp calls client:request("textDocument/completion", ..., its_own_callback), so the
    -- response bypasses vim.lsp.handlers entirely and arrives straight into its callback.
    -- Patch client.request once to wrap any completion callback and normalise labels first.
    if not client._al_completion_patched then
      client._al_completion_patched = true
      local _orig = client.request
      client.request = function(self, method, params, callback, bufnr_)
        if method == "textDocument/completion" and type(callback) == "function" then
          local _cb = callback
          callback = function(err, result, ...)
            if not err and result then
              local items = (type(result) == "table" and result.items) or result
              if type(items) == "table" then
                for _, item in ipairs(items) do
                  if type(item.label) == "table" then
                    item.label = item.label.label or ""
                  end
                end
              end
            end
            return _cb(err, result, ...)
          end
        end
        return _orig(self, method, params, callback, bufnr_)
      end
    end

    -- assemblyProbingPaths must be a non-null JSON array (omitting it crashes the server).
    -- Use empty array — avoids hanging on network-mounted .netpackages directories.
    local ws_cfg = {
      packageCachePaths      = { root .. "/.alpackages" },
      assemblyProbingPaths   = {},
      enableCodeAnalysis     = true,
      backgroundCodeAnalysis = "Project",
      enableCodeActions      = true,
      incrementalBuild       = true,
    }

    -- Tell the server which workspace is active and what its settings are.
    -- This is the trigger for the server to start indexing packages and source files.
    -- Structure mirrors what the VSCode AL extension sends: workspacePath at top level,
    -- settings nested under alResourceConfigurationSettings, setActiveWorkspace = true.
    -- Build expectedProjectReferenceDefinitions from app.json dependencies.
    local lsp_mod = require("al.lsp")
    local app_json = lsp_mod.read_app_json(root)
    local proj_refs = {}
    for _, dep in ipairs((app_json and app_json.dependencies) or {}) do
      if dep.id then
        table.insert(proj_refs, {
          appId     = dep.id,
          name      = dep.name or "",
          publisher = dep.publisher or "",
          version   = dep.version or "0.0.0.0",
        })
      end
    end

    -- VSCode extension sends: { currentWorkspaceFolderPath: <WorkspaceFolder>, settings: { ... } }
    -- Sending settings at the top level causes silent deserialization failure in the server.
    local root_uri = "file://" .. root
    client:request("al/setActiveWorkspace", {
      currentWorkspaceFolderPath = {
        uri   = root_uri,
        name  = vim.fn.fnamemodify(root, ":t"),
        index = 0,
      },
      settings = {
        workspacePath                       = root,
        alResourceConfigurationSettings     = ws_cfg,
        setActiveWorkspace                  = true,
        dependencyParentWorkspacePath       = vim.NIL,
        expectedProjectReferenceDefinitions = proj_refs,
        activeWorkspaceClosure              = {},
      },
    }, function(err, result)
      if err then
        vim.notify("AL: setActiveWorkspace error: " .. vim.inspect(err), vim.log.levels.WARN)
      elseif result and result.success == false then
        vim.notify("AL: setActiveWorkspace returned success=false: " .. vim.inspect(result), vim.log.levels.WARN)
      else
        vim.notify("AL: setActiveWorkspace OK — waiting for project to load…", vim.log.levels.WARN)
      end
    end, args.buf)

    -- gd: use the server's custom al/gotodefinition instead of textDocument/definition.
    -- vim.schedule defers until after all LspAttach handlers have run, so this
    -- overrides the generic gd set by the user's init.lua LspAttach callback.
    vim.schedule(function()
      vim.keymap.set("n", "gd", function()
        local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
        client:request("al/gotodefinition", {
          textDocumentPositionParams = params,
        }, function(err, result)
          if err or not result then return end
          vim.lsp.util.jump_to_location(result, client.offset_encoding)
        end, args.buf)
      end, { buffer = args.buf, desc = "AL: Go to definition" })
    end)
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

vim.api.nvim_create_user_command("ALLaunch", function(opts)
  require("al.debug").launch(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = "dir",
  desc  = "Compile, publish and attach debugger (F5 equivalent)",
})

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

vim.api.nvim_create_user_command("ALNextId", function()
  require("al.ids").show_next()
end, { desc = "Show next free object ID for the AL object type on the current line" })

vim.api.nvim_create_user_command("ALExplorer", function(opts)
  require("al.explorer").objects(opts.args ~= "" and opts.args or nil)
end, {
  nargs    = "?",
  complete = "dir",
  desc     = "AL Explorer: browse all AL objects across project and symbol packages",
})

vim.api.nvim_create_user_command("ALExplorerProcs", function()
  require("al.explorer").procedures()
end, { desc = "AL Explorer: browse procedures/triggers in the current file" })

vim.api.nvim_create_user_command("ALNewObject", function(opts)
  require("al.wizard").new_object(opts.args ~= "" and opts.args or nil)
end, {
  nargs    = "?",
  complete = "dir",
  desc     = "AL Object Wizard: create a new AL object file",
})

vim.api.nvim_create_user_command("ALSearch", function(opts)
  require("al.explorer").search(opts.args ~= "" and opts.args or nil)
end, {
  nargs    = "?",
  complete = "dir",
  desc     = "AL Explorer: live grep across all AL files (project + symbol packages)",
})

vim.api.nvim_create_user_command("ALHelp", function(opts)
  local url = opts.args ~= "" and opts.args or nil
  require("al.help").toggle(url)
end, {
  nargs = "?",
  desc  = "Toggle AL Help panel (MS Learn AL docs in lynx)",
})

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
