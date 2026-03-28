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

  -- Relative path inside the project root where symbol packages are cached
  packagecachepath = ".alpackages",

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
