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

  -- EXPERIMENTAL: use the standard `al launchlspserver` language server (from the
  -- Microsoft.Dynamics.BusinessCentral.Development.Tools dotnet tool, BC 2026 wave 1+)
  -- instead of the VSCode extension's EditorServices.Host binary.
  --
  -- The agentic server speaks *standard* LSP over stdio — native textDocument/definition,
  -- find-references (cross-project), rename, completion, hover, inlay hints — so none of
  -- the EditorServices custom-protocol workarounds (al/setActiveWorkspace, gd override,
  -- completion-label patch, al-preview://) apply. Runs as a distinct client
  -- (al_agentic_lsp) and coexists with the AL MCP server (both are the same `al` binary).
  --
  -- Requires: dotnet tool install/update Microsoft.Dynamics.BusinessCentral.Development.Tools
  --           --prerelease --global   (must expose `al launchlspserver`).
  -- Known gaps vs EditorServices: no server-driven progress/loaded events (statusline goes
  -- straight to ready), symbol download still uses the EditorServices global-sources method,
  -- al-preview:// base-object browsing not available.
  experimental_lsp = false,

  -- Automatically add missing `using` statements on save via source.organizeImports.
  -- Runs synchronously in BufWritePre, before the formatter, so the formatter also
  -- cleans up the newly added using lines. Set to false to manage manually via <leader>acn.
  organize_imports_on_save = true,

  -- How long the on-save organizeImports request may block the write before it
  -- is abandoned. The save always completes; only the using-statement fix-up is
  -- skipped on timeout.
  organize_imports_timeout_ms = 1500,

  -- Idle delay before the post-save alc pass that refreshes vim.diagnostic
  -- (file-tree badges). This is a full-project compile, so saves are coalesced
  -- rather than run one build per written file.
  analyze_debounce_ms = 1500,

  -- Diagnostic rule IDs to suppress in both alc output and LSP publishDiagnostics.
  -- AA0215 (object name must be suffixed) is suppressed by default because the
  -- file-organiser adds the suffix during save, causing a transient false positive.
  suppressed_diagnostics = { "AA0215" },

  -- Global browser override — used when no per-project browser is set in alnvim.json.
  -- Set to an executable path for your machine, e.g. on WSL:
  --   browser = "/mnt/c/Program Files/Mozilla Firefox/firefox.exe"
  -- Leave nil to use the system default (xdg-open / open).
  browser = nil,

  -- In-editor AI agents opened in a terminal split at the project root
  -- (:ALClaude / :ALPi, <leader>ai / <leader>ak).
  agent = {
    -- Claude Code (claude CLI must be installed + logged in).
    claude_cmd  = { "claude" },
    -- Pi (https://pi.dev): built as { pi, -e <pi_provider>, --model <pi_model> }
    -- unless pi_cmd is set. See docs/pi-setup.md.
    pi_cmd      = nil,
    pi_provider = "~/.pi/ollama-provider.ts",   -- a Pi extension registering your provider
    pi_model    = "ollama/qwen2.5-coder",       -- "<provider>/<model>"
    -- Extra env when launching Pi, e.g. for an HTTPS endpoint with a local CA:
    --   pi_env = { NODE_OPTIONS = "--use-system-ca" }            (CA in OS store)
    --   pi_env = { NODE_TLS_REJECT_UNAUTHORIZED = "0" }          (LAN-only, insecure)
    pi_env      = {},
  },

  -- Optional callback: function(client, bufnr) – called when the AL LSP attaches
  on_attach = nil,
}

-- Start from the defaults so the plugin behaves as documented even when the
-- user never calls setup() (e.g. config.agent.claude_cmd, auto_mcp).
M.config = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

  -- Wire up snippet loading after LuaSnip is initialised.
  local ok, _ = pcall(require, "luasnip")
  if ok then
    require("al.snippets").load()
  else
    -- LuaSnip may reach the runtimepath after setup() runs, depending on
    -- vim.pack ordering. Retry at VimEnter, by which point every pack is loaded.
    --
    -- The old trigger was "User LuasnipInsertNodeEnter", which only fires from
    -- inside an already-expanded snippet — it could never fire before the
    -- snippets it was meant to load existed, so this path never ran and AL
    -- snippets were simply missing for the whole session.
    vim.api.nvim_create_autocmd("VimEnter", {
      once     = true,
      callback = function()
        if pcall(require, "luasnip") then require("al.snippets").load() end
      end,
    })
  end
end

return M
