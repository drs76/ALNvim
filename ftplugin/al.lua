-- Buffer-local settings for AL files
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
-- Debugging
vim.keymap.set("n", "<F5>",        "<cmd>ALLaunch<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile, publish and attach debugger" }))
vim.keymap.set("n", "<leader>adl", "<cmd>ALLaunch<CR>",          vim.tbl_extend("force", opts, { desc = "AL: Compile, publish and attach debugger" }))
vim.keymap.set("n", "<leader>ads", "<cmd>ALSnapshotStart<CR>",   vim.tbl_extend("force", opts, { desc = "AL: Start snapshot debug session" }))
vim.keymap.set("n", "<leader>adf", "<cmd>ALSnapshotFinish<CR>",  vim.tbl_extend("force", opts, { desc = "AL: Finish snapshot and download" }))
vim.keymap.set("n", "<leader>add", "<cmd>ALDebugSetup<CR>",      vim.tbl_extend("force", opts, { desc = "AL: Configure nvim-dap for AL" }))
