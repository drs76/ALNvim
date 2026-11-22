-- ALActions: Telescope (or vim.ui.select) picker for all AL commands.
local M = {}

-- { name, key, desc, cmd } — cmd is the Ex command the entry runs; `run` is
-- added below. key = "" means no dedicated keymap binding.
local ACTIONS = {
  -- Build & Deploy -------------------------------------------------------
  { name = "Compile",                  key = "<leader>ab",  desc = "Build project with al compile (AL dotnet tool); stream output to the build view",
    cmd = "ALCompile" },
  { name = "Build Output",             key = "",            desc = "Reopen this project's last build output",
    cmd = "ALBuildOutput" },
  { name = "Build Diagnostics",        key = "",            desc = "Browse the last build's diagnostics (navigator under Catnip, else quickfix)",
    cmd = "ALCatnipDiagnostics" },
  { name = "Tool Output",              key = "",            desc = "Reopen this project's last AL tool output (publish, symbols, tests, doc)",
    cmd = "ALToolOutput" },
  { name = "Publish",                  key = "<leader>ap",  desc = "Compile then publish with al publishapp (AL dotnet tool)",
    cmd = "ALPublish" },
  { name = "Publish Only",             key = "<leader>aP",  desc = "Publish existing .app with al publishapp, without recompiling",
    cmd = "ALPublishOnly" },
  { name = "Analyze",                  key = "<leader>aA",  desc = "Silent alc pass; populate diagnostics / file-tree badges",
    cmd = "ALAnalyze" },

  -- Symbols --------------------------------------------------------------
  { name = "Download Symbols",         key = "<leader>as",  desc = "Download .app symbol packages (BC server or NuGet/AppSource)",
    cmd = "ALDownloadSymbols" },
  { name = "Download Symbols (Global)",key = "",            desc = "Download symbols from NuGet/AppSource directly (no server needed)",
    cmd = "ALDownloadSymbolsGlobal" },
  { name = "Set NuGet Feeds",          key = "",            desc = "Configure custom public NuGet feed URLs for global symbol download",
    cmd = "ALSetNuGetFeeds" },

  -- Debug ----------------------------------------------------------------
  { name = "Launch Debug",             key = "<F5>",        desc = "Compile, publish and attach BC debugger via DAP",
    cmd = "ALLaunch" },
  { name = "Snapshot Start",           key = "<leader>ads", desc = "Start a BC snapshot debug session",
    cmd = "ALSnapshotStart" },
  { name = "Snapshot Finish",          key = "<leader>adf", desc = "Download and open snapshot file",
    cmd = "ALSnapshotFinish" },
  { name = "Profile Capture",          key = "<leader>adp", desc = "Arm a CPU profiling schedule on a BC session id (al launchprofilingmcpproxy, tool 30+)",
    cmd = "ALProfileCapture" },
  { name = "Profile Collect",          key = "<leader>adP", desc = "Stop the armed schedule, save .alcpuprofile under .profiles and open the viewer",
    cmd = "ALProfileCollect" },
  { name = "Profile Open",             key = "<leader>ado", desc = "Hot-function viewer for the newest .alcpuprofile (<CR> jumps to source)",
    cmd = "ALProfileOpen" },
  { name = "Snapshot Capture (proxy)", key = "<leader>adS", desc = "Arm snapshot debugging through al launchsnapshotmcpproxy (tool 30+)",
    cmd = "ALSnapshotCapture" },
  { name = "Snapshot Collect (proxy)", key = "<leader>adF", desc = "Stop snapshot debugging; save archive + decoded summary under .snapshots",
    cmd = "ALSnapshotCollect" },
  { name = "Debug Setup",              key = "<leader>add", desc = "Configure nvim-dap adapter for AL debugging",
    cmd = "ALDebugSetup" },
  { name = "DAP Close",                key = "<leader>adX", desc = "Terminate DAP session and restore pre-debug buffer",
    cmd = "ALDapClose" },

  -- Explorer -------------------------------------------------------------
  { name = "Object Explorer",          key = "<leader>ae",  desc = "Telescope picker: all AL objects across project and symbol packages",
    cmd = "ALExplorer" },
  { name = "Procedure Explorer",       key = "<leader>af",  desc = "Telescope picker: procedures and triggers in current file",
    cmd = "ALExplorerProcs" },
  { name = "Search",                   key = "<leader>ag",  desc = "Live grep across AL project source files",
    cmd = "ALSearch" },
  { name = "Diff Explorer",            key = "<leader>aD",  desc = "Git diff explorer with Telescope preview",
    cmd = "ALDiff" },

  -- Objects / Wizard -----------------------------------------------------
  { name = "New Project",              key = "",            desc = "AL Go! — create new AL project (app.json, HelloWorld.al, .alpackages)",
    cmd = "ALNewProject" },
  { name = "New Object",               key = "<leader>an",  desc = "Object wizard — create new AL object file (table, page, codeunit…)",
    cmd = "ALNewObject" },
  { name = "Generate Permission Set",  key = "<leader>aR",  desc = "Scan all project objects and generate a PermissionSet file",
    cmd = "ALGeneratePermissionSet" },
  { name = "Report Layout Wizard",     key = "<leader>aw",  desc = "Generate Excel report layout and inject rendering section",
    cmd = "ALReportLayout" },
  { name = "Open Layout",              key = "<leader>aW",  desc = "Open generated report layout file in default application",
    cmd = "ALOpenLayout" },

  -- Refactor / Code ------------------------------------------------------
  { name = "Inlay Hints",                key = "",            desc = "Toggle LSP inlay hints for this buffer (needs inlayHintProvider)",
    cmd = "ALInlayHints" },
  { name = "Ghost Toggle",               key = "<leader>aI",  desc = "Toggle inline AI ghost completions (Ollama FIM, accept with <M-l>)",
    cmd = "ALGhostToggle" },
  { name = "Rename Object",             key = "grn",         desc = "Rename quoted identifier (object/field name) across all project .al files",
    cmd = "ALRenameObject" },
  { name = "Extract Label",            key = "<leader>acl", desc = "Cursor inside string → extract to Label variable",
    cmd = "ALExtractLabel" },
  { name = "Extract Procedure",        key = "<leader>ace", desc = "Visual selection → new local procedure (auto-detects params)",
    cmd = "ALExtractProcedure" },
  { name = "Create Snippet",           key = "<leader>acs", desc = "Save visual selection as a user snippet",
    cmd = "ALCreateSnippet" },
  { name = "Code Action",              key = "<leader>aca", desc = "Code actions — Lua refactors plus server actions when supported",
    cmd = "ALCodeAction" },
  { name = "Refactor Actions",         key = "<leader>acr", desc = "Refactor-kind code actions only",
    cmd = "ALCodeAction refactor" },
  { name = "Extract Locked Label",     key = "",            desc = "Cursor inside string → extract to Label with Locked = true",
    cmd = "ALExtractLockedLabel" },
  { name = "Convert to Validate",      key = "",            desc = "`X := Y;` → `Validate(X, Y);` on the current line / selection",
    cmd = "ALRefactorValidate" },
  { name = "Convert to Evaluate",      key = "",            desc = "`X := Y;` → `Evaluate(X, Y);` on the current line / selection",
    cmd = "ALRefactorEvaluate" },
  { name = "Make Var Global",          key = "",            desc = "Move the local variable under cursor to the global var block",
    cmd = "ALMakeVarGlobal" },
  { name = "Add Publishers",           key = "",            desc = "Add OnBefore/OnAfter IntegrationEvent publishers to current procedure",
    cmd = "ALAddPublishers" },
  { name = "Promote Action",           key = "",            desc = "Add actionref for the page action under cursor to area(Promoted)",
    cmd = "ALPromoteAction" },
  { name = "Create Handler",           key = "",            desc = "Stub a missing test handler named in [HandlerFunctions]",
    cmd = "ALCreateHandler" },
  { name = "Fix Cops",                 key = "<leader>acx", desc = "Analyze, then apply all AA0137/AA0206/AA0008 fixes (unused var/assignment, missing ())",
    cmd = "ALFixCops" },
  { name = "Quick Fixes",              key = "<leader>acf", desc = "Quick fixes for diagnostics on the cursor line (create procedure, cop fixes)",
    cmd = "ALCodeAction quickfix" },
  { name = "Option To Enum",           key = "<leader>acE", desc = "Convert the Option field under cursor to a new enum object (`extensible` arg)",
    cmd = "ALRefactorToEnum" },
  { name = "Find Related",             key = "<leader>aF",  desc = "Go to event publisher / handler function / table trigger for the cursor line",
    cmd = "ALFindRelated" },
  { name = "Run Tests",                key = "<leader>at",  desc = "Run test codeunit / methods from the built .app via al runtests (pass/fail → quickfix)",
    cmd = "ALRunTests" },
  { name = "Run Test At Cursor",       key = "<leader>aT",  desc = "Run only the [Test] procedure under the cursor",
    cmd = "ALRunTests!" },
  { name = "List Tests",               key = "",            desc = "List test codeunits and methods in the built .app (al listtests)",
    cmd = "ALListTests" },
  { name = "Run Object",               key = "<leader>ar",  desc = "Open the page/report/table declared in this buffer in the BC web client",
    cmd = "ALRunObject" },
  { name = "Build Docs",               key = "<leader>ax",  desc = "Build reference documentation into .aldoc (al doc build)",
    cmd = "ALDoc" },
  { name = "Add Usings",               key = "<leader>acu", desc = "Organise imports — add missing using statements",
    cmd = "ALAddUsings" },
  { name = "Add Namespace",            key = "<leader>aN",  desc = "Add namespace declaration to all source files in project",
    cmd = "ALAddNamespace" },
  { name = "Change Namespace",         key = "",            desc = "Move the project's namespaces to a new prefix (POC → PTE): namespace, using, qualified references",
    cmd = "ALChangeNamespace" },

  -- Configuration --------------------------------------------------------
  { name = "Select Code Cops",         key = "<leader>aC",  desc = "Toggle active code analyzers (CodeCop, UICop, AppSourceCop…)",
    cmd = "ALSelectCops" },
  { name = "Select Browser",           key = "<leader>aB",  desc = "Choose default browser for BC webclient launch",
    cmd = "ALSelectBrowser" },
  { name = "MCP Setup",                key = "<leader>am",  desc = "Write AL MCP server entry to <project>/.claude/settings.json",
    cmd = "ALMcpSetup" },
  { name = "MCP Status",               key = "<leader>aM",  desc = "Show configured AL MCP server entries",
    cmd = "ALMcpStatus" },
  { name = "Claude Code",              key = "<leader>ai",  desc = "Open Claude Code agent in a terminal split at the project root",
    cmd = "ALClaude" },
  { name = "Pi Agent",                 key = "<leader>ak",  desc = "Open Pi agent in a terminal split at the project root",
    cmd = "ALPi" },

  -- Files ----------------------------------------------------------------
  { name = "Open app.json",            key = "<leader>ao",  desc = "Open project app.json",
    cmd = "ALOpenAppJson" },
  { name = "Open launch.json",         key = "<leader>al",  desc = "Open .vscode/launch.json",
    cmd = "ALOpenLaunchJson" },

  -- Misc -----------------------------------------------------------------
  { name = "Reindex",                  key = "",            desc = "Restart AL LSP and re-send workspace configuration",
    cmd = "ALReindex" },
  { name = "Next ID",                  key = "",            desc = "Notify next 3 free object IDs from app.json idRanges",
    cmd = "ALNextId" },
  { name = "Reload Snippets",          key = "",            desc = "Reload built-in and user snippet files into LuaSnip",
    cmd = "ALReloadSnippets" },
  { name = "Clear Credentials",        key = "",            desc = "Clear cached BC auth credentials for this session",
    cmd = "ALClearCredentials" },
  { name = "AL Info",                  key = "",            desc = "Show LSP client info, extension path and version",
    cmd = "ALInfo" },
  { name = "Install Extension",        key = "",            desc = "Download and install the MS AL VSCode extension",
    cmd = "ALInstallExtension" },
  { name = "Update Extension",         key = "",            desc = "Check marketplace and update MS AL VSCode extension if newer",
    cmd = "ALUpdateExtension" },
  { name = "Install Dotnet Tool",      key = "",            desc = "Install/update AL dotnet tool (required for MCP server)",
    cmd = "ALInstallDotnetTool" },

  -- Help -----------------------------------------------------------------
  { name = "Help",                     key = "<leader>ah",  desc = "Open MS Learn AL documentation in browser",
    cmd = "ALHelp" },
  { name = "Help Topics",              key = "<leader>aH",  desc = "Browse AL help topic list",
    cmd = "ALHelpTopics" },
  { name = "AL Guidelines",            key = "<leader>aG",  desc = "Open alguidelines.dev in browser",
    cmd = "ALGuidelines" },
}

for _, a in ipairs(ACTIONS) do
  local c = a.cmd
  a.run = function() vim.cmd(c) end
end

-- The action list for hosts with their own command palette (Catnip keeps a
-- hand-written table that drifted: commands that do not exist, new ones in
-- "Other"). command is the Ex command without the colon, arguments included.
function M.list()
  return vim.tbl_map(function(a)
    return { name = a.name, command = a.cmd, key = a.key, desc = a.desc }
  end, ACTIONS)
end

function M.picker()
  if not require("al.host").use_telescope() then
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

M._test = { ACTIONS = ACTIONS }

return M
