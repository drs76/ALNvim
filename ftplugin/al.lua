-- Buffer-local settings for AL files

-- Apply bc_dark as default when an AL buffer is first loaded,
-- but only if the user hasn't already chosen a bc_* colorscheme.
local _cs = vim.g.colors_name or ""
if not _cs:find("^bc_") then
  vim.cmd("colorscheme bc_dark")
end

-- AL statusline: show project name/version, LSP loading state, compile/publish result.
-- Save and restore around focus changes so other buffers get their default statusline back.
local _AL_STL = " %f %m  │  %{v:lua.require('al.status').get()}  %=  %l:%c  %P "
local _prev_stl = vim.wo.statusline
vim.wo.statusline = _AL_STL
vim.api.nvim_create_autocmd("BufLeave", {
  buffer   = 0,
  callback = function() vim.wo.statusline = _prev_stl end,
})
vim.api.nvim_create_autocmd("BufEnter", {
  buffer   = 0,
  callback = function() vim.wo.statusline = _AL_STL end,
})
-- Format on save using the AL language server formatter.
-- Runs synchronously in BufWritePre so the formatted content is what gets written.
vim.api.nvim_create_autocmd("BufWritePre", {
  buffer   = 0,
  callback = function()
    local bufnr  = vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients({ name = "al_language_server", bufnr = bufnr })
    if #clients == 0 then return end
    local cap = clients[1].server_capabilities.documentFormattingProvider
    if not cap then return end
    vim.lsp.buf.format({ bufnr = bufnr, async = false, timeout_ms = 3000, id = clients[1].id })
  end,
})
-- Auto-organise: on save, move file into src/<objecttype>/ if not already there.
vim.api.nvim_create_autocmd("BufWritePost", {
  buffer   = 0,
  callback = function()
    require("al.wizard").organise_file(vim.api.nvim_get_current_buf())
  end,
})

vim.bo.commentstring = "// %s"
vim.bo.tabstop       = 4
vim.bo.shiftwidth    = 4
vim.bo.expandtab     = true
vim.bo.smartindent   = true

-- Fold on #region / #endregion markers
vim.wo.foldmethod = "marker"
vim.wo.foldmarker = "#region,#endregion"

-- AL compile / publish shortcuts (buffer-local)
local opts = { buffer = true, silent = true }
-- Build
vim.keymap.set("n", "<leader>ab", "<cmd>ALCompile<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile project" }))
vim.keymap.set("n", "<leader>ap", "<cmd>ALPublish<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile + Publish to BC" }))
vim.keymap.set("n", "<leader>aP", "<cmd>ALPublishOnly<CR>",      vim.tbl_extend("force", opts, { desc = "AL: Publish existing .app (skip compile)" }))
vim.keymap.set("n", "<leader>as", "<cmd>ALDownloadSymbols<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Download symbols from BC" }))
-- Project files
vim.keymap.set("n", "<leader>ao", "<cmd>ALOpenAppJson<CR>",      vim.tbl_extend("force", opts, { desc = "AL: Open app.json" }))
vim.keymap.set("n", "<leader>al", "<cmd>ALOpenLaunchJson<CR>",   vim.tbl_extend("force", opts, { desc = "AL: Open launch.json" }))
vim.keymap.set("n", "<leader>aq", "<cmd>copen<CR>",              vim.tbl_extend("force", opts, { desc = "AL: Open quickfix list" }))
vim.keymap.set("n", "<leader>ac", "<cmd>ALSelectCops<CR>",       vim.tbl_extend("force", opts, { desc = "AL: Select active code cops" }))
vim.keymap.set("n", "<leader>aB", "<cmd>ALSelectBrowser<CR>",   vim.tbl_extend("force", opts, { desc = "AL: Select browser for BC launch" }))
vim.keymap.set("n", "<leader>am", "<cmd>ALMcpSetup<CR>",        vim.tbl_extend("force", opts, { desc = "AL: Configure MCP server for Claude Code" }))
vim.keymap.set("n", "<leader>aM", "<cmd>ALMcpStatus<CR>",       vim.tbl_extend("force", opts, { desc = "AL: Show configured AL MCP entries" }))
vim.keymap.set("n", "<leader>ad", function()
  if pcall(require, "telescope.builtin") then
    require("telescope.builtin").diagnostics({ bufnr = 0 })
  else
    vim.diagnostic.setloclist()
  end
end, vim.tbl_extend("force", opts, { desc = "AL: Diagnostics for current buffer" }))
-- Explorer
vim.keymap.set("n", "<leader>ah", "<cmd>ALHelp<CR>",        vim.tbl_extend("force", opts, { desc = "AL: Open AL docs in browser (MS Learn)" }))
vim.keymap.set("n", "<leader>aH", "<cmd>ALHelpTopics<CR>", vim.tbl_extend("force", opts, { desc = "AL: Help topic picker" }))
vim.keymap.set("n", "<leader>aG", "<cmd>ALGuidelines<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Open AL Code Guidelines in browser" }))
vim.keymap.set("n", "<leader>an", "<cmd>ALNewObject<CR>",     vim.tbl_extend("force", opts, { desc = "AL: New object wizard" }))
vim.keymap.set("n", "<leader>av", "<cmd>ALPreviewPage<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Preview page layout" }))
vim.keymap.set("n", "<leader>aw", "<cmd>ALReportLayout<CR>", vim.tbl_extend("force", opts, { desc = "AL: Report Layout Wizard (Excel/Word/RDLC)" }))
vim.keymap.set("n", "<leader>aW", "<cmd>ALOpenLayout<CR>",   vim.tbl_extend("force", opts, { desc = "AL: Open existing report layout in default app" }))
vim.keymap.set("n", "<leader>aA", "<cmd>ALAnalyze<CR>",       vim.tbl_extend("force", opts, { desc = "AL: Force re-analysis / refresh diagnostics" }))
-- Code actions
-- <leader>ca (all code actions) is set globally via LspAttach in init.lua
vim.keymap.set({ "n", "v" }, "<leader>aca", vim.lsp.buf.code_action,
  vim.tbl_extend("force", opts, { desc = "AL: Code actions (all)" }))
vim.keymap.set("n", "<leader>acf", function()
  vim.lsp.buf.code_action({ context = { only = { "quickfix" }, diagnostics = vim.diagnostic.get(0) } })
end, vim.tbl_extend("force", opts, { desc = "AL: Quick fixes for diagnostics on cursor line" }))
vim.keymap.set("n", "<leader>acF", function()
  vim.lsp.buf.code_action({ context = { only = { "source.fixAll" } } })
end, vim.tbl_extend("force", opts, { desc = "AL: Fix all — apply all source.fixAll actions in file" }))
vim.keymap.set("n", "<leader>acn", function()
  vim.lsp.buf.code_action({ context = { only = { "source.organizeImports" } } })
end, vim.tbl_extend("force", opts, { desc = "AL: Organise namespaces / using statements" }))
vim.keymap.set("n", "<leader>acr", function()
  vim.lsp.buf.code_action({ context = { only = { "refactor" } } })
end, vim.tbl_extend("force", opts, { desc = "AL: Refactor actions (convert with, promoted actions, interfaces…)" }))
vim.keymap.set("n", "<leader>aN", "<cmd>ALAddNamespace<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Add namespace to all source files" }))
vim.keymap.set("n", "<leader>aD", "<cmd>ALDiff<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Git diff explorer — changed files" }))
vim.keymap.set("n", "<leader>ae", "<cmd>ALExplorer<CR>",      vim.tbl_extend("force", opts, { desc = "AL: Explorer — browse objects" }))
vim.keymap.set("n", "<leader>af", "<cmd>ALExplorerProcs<CR>", vim.tbl_extend("force", opts, { desc = "AL: Explorer — procedures in file" }))
vim.keymap.set("n", "<leader>ag", "<cmd>ALSearch<CR>",        vim.tbl_extend("force", opts, { desc = "AL: Explorer — live grep all AL files" }))
-- Object ID completion  (<C-Space> on a line starting with an AL object type)
_G.ALCompleteObjectId = function(findstart, base)
  return require("al.ids").complete(findstart, base)
end
vim.bo.completefunc = "ALCompleteObjectId"
-- <C-Space> sends NUL (0x00) in most Linux terminals → map both
vim.keymap.set("i", "<C-Space>", "<C-x><C-u>",
  { buffer = true, silent = true, desc = "AL: Next free object ID" })
vim.keymap.set("i", "<Nul>", "<C-x><C-u>",
  { buffer = true, silent = true, desc = "AL: Next free object ID" })
-- Debugging
vim.keymap.set("n", "<F5>", function()
  local ok, dap = pcall(require, "dap")
  if ok and dap.session() then
    dap.continue()   -- session already running: resume
  else
    vim.cmd("ALLaunch")  -- no session: compile, publish and attach
  end
end, vim.tbl_extend("force", opts, { desc = "AL: Continue debug session or launch" }))
vim.keymap.set("n", "<leader>adl", "<cmd>ALLaunch<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile, publish and attach debugger" }))
vim.keymap.set("n", "<leader>ads", "<cmd>ALSnapshotStart<CR>",   vim.tbl_extend("force", opts, { desc = "AL: Start snapshot debug session" }))
vim.keymap.set("n", "<leader>adf", "<cmd>ALSnapshotFinish<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Finish snapshot and download" }))
vim.keymap.set("n", "<leader>add", "<cmd>ALDebugSetup<CR>",      vim.tbl_extend("force", opts, { desc = "AL: Configure nvim-dap for AL" }))
-- nvim-dap runtime controls (only mapped when nvim-dap is present)
if pcall(require, "dap") then
  local dap = require("dap")
  vim.keymap.set("n", "<F9>",        dap.toggle_breakpoint,                                           vim.tbl_extend("force", opts, { desc = "DAP: Toggle breakpoint" }))
  vim.keymap.set("n", "<leader>adb", dap.toggle_breakpoint,                                           vim.tbl_extend("force", opts, { desc = "DAP: Toggle breakpoint" }))
  vim.keymap.set("n", "<leader>adB", function() dap.set_breakpoint(vim.fn.input("Condition: ")) end,  vim.tbl_extend("force", opts, { desc = "DAP: Conditional breakpoint" }))
  vim.keymap.set("n", "<F10>",       dap.step_over,                                                   vim.tbl_extend("force", opts, { desc = "DAP: Step over" }))
  vim.keymap.set("n", "<F11>",       dap.step_into,                                                   vim.tbl_extend("force", opts, { desc = "DAP: Step into" }))
  vim.keymap.set("n", "<F12>",       dap.step_over,                                                   vim.tbl_extend("force", opts, { desc = "DAP: Step over" }))
  vim.keymap.set("n", "<leader>adc", dap.continue,                                                    vim.tbl_extend("force", opts, { desc = "DAP: Continue" }))
  vim.keymap.set("n", "<leader>adq", dap.terminate,                                                   vim.tbl_extend("force", opts, { desc = "DAP: Terminate session" }))
  vim.keymap.set("n", "<leader>adi", function() require("dap.ui.widgets").hover() end,                vim.tbl_extend("force", opts, { desc = "DAP: Inspect variable under cursor" }))
end
-- Text objects
local _to = require("al.textobj")
vim.keymap.set({ "o", "x" }, "af", _to.around_proc,  { buffer = true, silent = true, desc = "AL: around procedure/trigger" })
vim.keymap.set({ "o", "x" }, "if", _to.inside_proc,  { buffer = true, silent = true, desc = "AL: inside procedure/trigger" })
vim.keymap.set({ "o", "x" }, "aF", _to.around_block, { buffer = true, silent = true, desc = "AL: around begin/end block" })
vim.keymap.set({ "o", "x" }, "iF", _to.inside_block, { buffer = true, silent = true, desc = "AL: inside begin/end block" })
