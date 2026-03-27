-- Buffer-local settings for AL files

-- Switch to BC Dark theme for AL buffers, restore previous theme on leave.
local _prev_colors = vim.g.colors_name
if _prev_colors ~= "bc_dark" then
  vim.cmd("colorscheme bc_dark")
end
vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave" }, {
  buffer  = 0,
  once    = true,
  callback = function()
    if _prev_colors and _prev_colors ~= "bc_dark" then
      vim.cmd("colorscheme " .. _prev_colors)
    end
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
-- Explorer
vim.keymap.set("n", "<leader>ah", "<cmd>ALHelp<CR>",        vim.tbl_extend("force", opts, { desc = "AL: Toggle help panel (MS Learn)" }))
vim.keymap.set("n", "<leader>an", "<cmd>ALNewObject<CR>",     vim.tbl_extend("force", opts, { desc = "AL: New object wizard" }))
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
vim.keymap.set("n", "<F5>",        "<cmd>ALLaunch<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile, publish and attach debugger" }))
vim.keymap.set("n", "<leader>adl", "<cmd>ALLaunch<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile, publish and attach debugger" }))
vim.keymap.set("n", "<leader>ads", "<cmd>ALSnapshotStart<CR>",   vim.tbl_extend("force", opts, { desc = "AL: Start snapshot debug session" }))
vim.keymap.set("n", "<leader>adf", "<cmd>ALSnapshotFinish<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Finish snapshot and download" }))
vim.keymap.set("n", "<leader>add", "<cmd>ALDebugSetup<CR>",      vim.tbl_extend("force", opts, { desc = "AL: Configure nvim-dap for AL" }))
