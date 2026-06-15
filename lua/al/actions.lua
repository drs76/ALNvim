-- ALActions: Telescope (or vim.ui.select) picker for all AL commands.
local M = {}

-- { name, key, desc, run() }
-- key = "" means no dedicated keymap binding.
local ACTIONS = {
  -- Build & Deploy -------------------------------------------------------
  { name = "Compile",                  key = "<leader>ab",  desc = "Build project with alc; stream output to panel",
    run = function() vim.cmd("ALCompile") end },
  { name = "Publish",                  key = "<leader>ap",  desc = "Compile then POST .app to BC server",
    run = function() vim.cmd("ALPublish") end },
  { name = "Publish Only",             key = "<leader>aP",  desc = "POST existing .app to BC without recompiling",
    run = function() vim.cmd("ALPublishOnly") end },
  { name = "Analyze",                  key = "<leader>aA",  desc = "Silent alc pass; populate diagnostics / file-tree badges",
    run = function() vim.cmd("ALAnalyze") end },

  -- Symbols --------------------------------------------------------------
  { name = "Download Symbols",         key = "<leader>as",  desc = "Download .app symbol packages (BC server or NuGet/AppSource)",
    run = function() vim.cmd("ALDownloadSymbols") end },
  { name = "Download Symbols (Global)",key = "",            desc = "Download symbols from NuGet/AppSource directly (no server needed)",
    run = function() vim.cmd("ALDownloadSymbolsGlobal") end },
  { name = "Set NuGet Feeds",          key = "",            desc = "Configure custom public NuGet feed URLs for global symbol download",
    run = function() vim.cmd("ALSetNuGetFeeds") end },

  -- Debug ----------------------------------------------------------------
  { name = "Launch Debug",             key = "<F5>",        desc = "Compile, publish and attach BC debugger via DAP",
    run = function() vim.cmd("ALLaunch") end },
  { name = "Snapshot Start",           key = "<leader>ads", desc = "Start a BC snapshot debug session",
    run = function() vim.cmd("ALSnapshotStart") end },
  { name = "Snapshot Finish",          key = "<leader>adf", desc = "Download and open snapshot file",
    run = function() vim.cmd("ALSnapshotFinish") end },
  { name = "Debug Setup",              key = "<leader>add", desc = "Configure nvim-dap adapter for AL debugging",
    run = function() vim.cmd("ALDebugSetup") end },
  { name = "DAP Close",                key = "<leader>adX", desc = "Terminate DAP session and restore pre-debug buffer",
    run = function() vim.cmd("ALDapClose") end },

  -- Explorer -------------------------------------------------------------
  { name = "Object Explorer",          key = "<leader>ae",  desc = "Telescope picker: all AL objects across project and symbol packages",
    run = function() vim.cmd("ALExplorer") end },
  { name = "Procedure Explorer",       key = "<leader>af",  desc = "Telescope picker: procedures and triggers in current file",
    run = function() vim.cmd("ALExplorerProcs") end },
  { name = "Search",                   key = "<leader>ag",  desc = "Live grep across AL project source files",
    run = function() vim.cmd("ALSearch") end },
  { name = "Diff Explorer",            key = "<leader>aD",  desc = "Git diff explorer with Telescope preview",
    run = function() vim.cmd("ALDiff") end },

  -- Objects / Wizard -----------------------------------------------------
  { name = "New Project",              key = "",            desc = "AL Go! — create new AL project (app.json, HelloWorld.al, .alpackages)",
    run = function() vim.cmd("ALNewProject") end },
  { name = "New Object",               key = "<leader>an",  desc = "Object wizard — create new AL object file (table, page, codeunit…)",
    run = function() vim.cmd("ALNewObject") end },
  { name = "Generate Permission Set",  key = "<leader>aR",  desc = "Scan all project objects and generate a PermissionSet file",
    run = function() vim.cmd("ALGeneratePermissionSet") end },
  { name = "Report Layout Wizard",     key = "<leader>aw",  desc = "Generate Excel report layout and inject rendering section",
    run = function() vim.cmd("ALReportLayout") end },
  { name = "Open Layout",              key = "<leader>aW",  desc = "Open generated report layout file in default application",
    run = function() vim.cmd("ALOpenLayout") end },

  -- Refactor / Code ------------------------------------------------------
  { name = "Ghost Toggle",               key = "<leader>aI",  desc = "Toggle inline AI ghost completions from Larry (Ollama FIM, accept with <M-l>)",
    run = function() vim.cmd("ALGhostToggle") end },
  { name = "Rename Object",             key = "grn",         desc = "Rename quoted identifier (object/field name) across all project .al files",
    run = function() vim.cmd("ALRenameObject") end },
  { name = "Extract Label",            key = "<leader>acl", desc = "Cursor inside string → extract to Label variable",
    run = function() vim.cmd("ALExtractLabel") end },
  { name = "Extract Procedure",        key = "<leader>ace", desc = "Visual selection → new local procedure (auto-detects params)",
    run = function() vim.cmd("ALExtractProcedure") end },
  { name = "Create Snippet",           key = "<leader>acs", desc = "Save visual selection as a user snippet",
    run = function() vim.cmd("ALCreateSnippet") end },
  { name = "Code Action",              key = "<leader>aca", desc = "LSP code actions (all)",
    run = function() vim.lsp.buf.code_action() end },
  { name = "Add Usings",               key = "<leader>acu", desc = "Organise imports — add missing using statements",
    run = function() vim.cmd("ALAddUsings") end },
  { name = "Add Namespace",            key = "<leader>aN",  desc = "Add namespace declaration to all source files in project",
    run = function() vim.cmd("ALAddNamespace") end },

  -- Configuration --------------------------------------------------------
  { name = "Select Code Cops",         key = "<leader>ac",  desc = "Toggle active code analyzers (CodeCop, UICop, AppSourceCop…)",
    run = function() vim.cmd("ALSelectCops") end },
  { name = "Select Browser",           key = "<leader>aB",  desc = "Choose default browser for BC webclient launch",
    run = function() vim.cmd("ALSelectBrowser") end },
  { name = "MCP Setup",                key = "<leader>am",  desc = "Write AL MCP server entry to ~/.claude/settings.json",
    run = function() vim.cmd("ALMcpSetup") end },
  { name = "MCP Status",               key = "<leader>aM",  desc = "Show configured AL MCP server entries",
    run = function() vim.cmd("ALMcpStatus") end },
  { name = "Ollama Chat",              key = "<leader>ai",  desc = "Open Ollama chat with AL MCP tools in terminal (mcphost)",
    run = function() vim.cmd("ALOllamaChat") end },

  -- Files ----------------------------------------------------------------
  { name = "Open app.json",            key = "<leader>ao",  desc = "Open project app.json",
    run = function() vim.cmd("ALOpenAppJson") end },
  { name = "Open launch.json",         key = "<leader>al",  desc = "Open .vscode/launch.json",
    run = function() vim.cmd("ALOpenLaunchJson") end },

  -- Misc -----------------------------------------------------------------
  { name = "Reindex",                  key = "",            desc = "Restart AL LSP and re-send workspace configuration",
    run = function() vim.cmd("ALReindex") end },
  { name = "Next ID",                  key = "",            desc = "Notify next 3 free object IDs from app.json idRanges",
    run = function() vim.cmd("ALNextId") end },
  { name = "Reload Snippets",          key = "",            desc = "Reload built-in and user snippet files into LuaSnip",
    run = function() vim.cmd("ALReloadSnippets") end },
  { name = "Clear Credentials",        key = "",            desc = "Clear cached BC auth credentials for this session",
    run = function() vim.cmd("ALClearCredentials") end },
  { name = "AL Info",                  key = "",            desc = "Show LSP client info, extension path and version",
    run = function() vim.cmd("ALInfo") end },
  { name = "Install Extension",        key = "",            desc = "Download and install the MS AL VSCode extension",
    run = function() vim.cmd("ALInstallExtension") end },
  { name = "Update Extension",         key = "",            desc = "Check marketplace and update MS AL VSCode extension if newer",
    run = function() vim.cmd("ALUpdateExtension") end },
  { name = "Install Dotnet Tool",      key = "",            desc = "Install/update AL dotnet tool (required for MCP server)",
    run = function() vim.cmd("ALInstallDotnetTool") end },

  -- Help -----------------------------------------------------------------
  { name = "Help",                     key = "<leader>ah",  desc = "Open MS Learn AL documentation in browser",
    run = function() vim.cmd("ALHelp") end },
  { name = "Help Topics",              key = "<leader>aH",  desc = "Browse AL help topic list",
    run = function() vim.cmd("ALHelpTopics") end },
  { name = "AL Guidelines",            key = "<leader>aG",  desc = "Open alguidelines.dev in browser",
    run = function() vim.cmd("ALGuidelines") end },
}

function M.picker()
  local ok_tel = pcall(require, "telescope")
  if not ok_tel then
    -- Fallback: vim.ui.select
    vim.ui.select(ACTIONS, {
      prompt = "AL Actions",
      format_item = function(a)
        local key = a.key ~= "" and (" " .. a.key) or ""
        return string.format("%-28s%-14s %s", a.name, key, a.desc)
      end,
    }, function(a)
      if a then vim.schedule(a.run) end
    end)
    return
  end

  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local tel_actions  = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "AL Actions",
    finder = finders.new_table({
      results = ACTIONS,
      entry_maker = function(a)
        local key = a.key ~= "" and ("  " .. a.key) or ""
        return {
          value   = a,
          display = string.format("%-28s%-14s  %s", a.name, key, a.desc),
          ordinal = a.name .. " " .. a.desc,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      tel_actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        tel_actions.close(prompt_bufnr)
        if sel then vim.schedule(sel.value.run) end
      end)
      return true
    end,
  }):find()
end

return M
