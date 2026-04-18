local M = {}

M.defaults = {
  -- Path to the MS AL VSCode extension (auto-detected from ~/.vscode/extensions/).
  -- Override only if you have a non-standard install location.
  ext_path = require("al.ext").path,

  -- Extra arguments passed to alc on every compile
  -- e.g. { "/warnaserror+", "/analyzer:/path/to/analyzer.dll" }
  alc_extra_args = {},

  -- Path to a ruleset JSON file passed to alc via /ruleset:<file>.
  -- Set to an absolute path, e.g. "/home/user/Documents/AL/codeanalyzer.json"
  ruleset_path = nil,

  -- Global fallback for the object name affix (suffix or prefix) used by
  -- CRS naming conventions. Prefer setting CRS.ObjectNameSuffix in
  -- .vscode/settings.json — that is read automatically and takes priority.
  -- e.g. object_name_suffix = "PTE"
  object_name_suffix = nil,

  -- Relative path inside the project root where symbol packages are cached
  packagecachepath = ".alpackages",

  -- Side the compile results panel opens on: "left" or "right"
  compile_side = "left",

  -- Automatically configure the AL MCP server in ~/.claude/settings.json
  -- whenever the AL LSP attaches to a project. Set to false to manage manually
  -- via :ALMcpSetup / :ALMcpRemove.
  auto_mcp = true,

  -- Automatically start the AL LSP when Neovim opens inside an AL project root
  -- (i.e. app.json exists in the current working directory). Enables diagnostics
  -- in the file explorer without needing to open an AL file first.
  auto_start = true,

  -- Automatically add missing `using` statements on save via source.organizeImports.
  -- Runs synchronously in BufWritePre, before the formatter, so the formatter also
  -- cleans up the newly added using lines. Set to false to manage manually via <leader>acn.
  organize_imports_on_save = true,

  -- Optional callback: function(client, bufnr) – called when the AL LSP attaches
  on_attach = nil,
}

M.config = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

  -- Wire up snippet loading after LuaSnip is initialised
  -- (lazy_load is safe to call multiple times)
  local ok, _ = pcall(require, "luasnip")
  if ok then
    require("al.snippets").load()
  else
    -- Defer until LuaSnip becomes available (e.g. loaded later by vim.pack)
    vim.api.nvim_create_autocmd("User", {
      pattern  = "LuasnipInsertNodeEnter",
      once     = true,
      callback = function() require("al.snippets").load() end,
    })
  end
end

return M
