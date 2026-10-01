# CLAUDE.md

ALNvim is a Neovim plugin (Lua) for Business Central AL, loaded via `vim.pack.add()` (Neovim 0.11+). Integrates the MS AL VSCode extension LSP from `~/.vscode/extensions/`, auto-detected by `lua/al/ext.lua`.

## Structure

| Path | Purpose |
|---|---|
| `plugin/al.lua` | Entry point: starts LSP, registers handlers, creates user commands |
| `lua/al/init.lua` | `require('al').setup(opts)` |
| `lua/al/ext.lua` | Auto-detects newest MS AL VSCode extension (cached) |
| `lua/al/lsp.lua` | Project root detection, `app.json` reading |
| `lua/al/connection.lua` | BC connection utils: parse launch.json, build URLs, `curl_auth` (sync), `get_auth` (async) |
| `lua/al/compile.lua` | Async `alc` compiler — output panel + quickfix |
| `lua/al/symbols.lua` | Download `.app` symbol packages (server or global) via the AL dotnet tool |
| `lua/al/publish.lua` | Compile then publish `.app` with `al publishapp` |
| `lua/al/debug.lua` | Snapshot debugging + nvim-dap adapter config |
| `lua/al/explorer.lua` | Telescope pickers: objects (`M.objects`), procedures (`M.procedures`), grep (`M.search`) |
| `lua/al/ids.lua` | Object ID completion from `app.json` `idRanges`; `M.next_id` used by wizard |
| `lua/al/cops.lua` | Code Cop selector + browser selector — config in `alnvim.json` |
| `lua/al/mcp.lua` | Writes `<project>/.claude/settings.json` for AL MCP server (never global) |
| `lua/al/agentic_lsp.lua` | **Experimental** standard-LSP backend via `al launchlspserver` (opt-in `experimental_lsp`) |
| `lua/al/altool.lua` | **The** AL dotnet tool module: `M.binary()` (the one resolver), `M.has(subcmd)`, `M.run()` streaming runner, `M.connection(_flags)()`/`M.cred_env()` launch.json mapping, `M.mcp_call()` one-shot MCP client |
| `lua/al/wizard.lua` | AL Object Wizard — creates new AL object files; `M.generate_permissionset()` skips type picker |
| `lua/al/refactor.lua` | Code refactoring: `M.extract_label()` (cursor string → Label var), `M.extract_to_procedure()` (visual selection → local procedure) |
| `lua/al/basedef.lua` | `gd` for the agentic LSP: server definition, else hover-driven jump into variable declarations / extracted base-object sources |
| `lua/al/diff.lua` | Git Diff Explorer — Telescope picker with diff preview |
| `lua/al/layout.lua` | Report Layout Wizard — Excel generation + rendering section injection |
| `lua/al/help.lua` | Opens MS Learn AL docs / alguidelines.dev in browser |
| `lua/al/status.lua` | Statusline state store (LSP, project, compile, publish) |
| `lua/al/platform.lua` | All platform-specific operations (paths, chmod, browser, zip) |
| `lua/al/json.lua` | `M.pretty()` / `M.write()` — indented JSON writer for user-facing config files |
| `lua/al/snippets.lua` | Loads snippets into LuaSnip; `M.create_from_selection()` wizard |
| `lua/al/actions.lua` | ALActions picker — 45 actions with descriptions; Telescope or `vim.ui.select` fallback |
| `ftdetect/al.vim` | `filetype=al` for `*.al`, `*.dal` |
| `ftplugin/al.lua` | Buffer-local settings and keymaps |
| `syntax/al.vim` | Vim syntax highlighting from `alsyntax.tmlanguage` |
| `colors/bc_dark.lua` | BC Dark colorscheme |
| `colors/bc_yellow.lua` | Alias for bc_dark with different `colors_name` — global default in `init.lua` |
| `snippets/al.json` | VSCode-format snippets (committed, read-only) |
| `snippets/al-user.json` | User-created snippets via `:ALCreateSnippet`; committed empty seed `{}` |
| `package.json` | Tells LuaSnip's `from_vscode` loader about both snippet files |

## Windows compatibility

All OS-specific operations go through `lua/al/platform.lua` — never add platform conditionals elsewhere.

**`glob_al_files` exclusion pitfall:** the cache filter uses a plain `string.find` for a path *segment*. With `plain=true` a Lua pattern is matched **literally**, so the old `"%.alpackages"` needle never matched anything. That was harmless for the default config — `vim.fn.glob("**/*")` does not descend into dot-directories, so `.alpackages` was excluded anyway — but `packagecachepath` is configurable, and a cache dir without a leading dot *is* returned and must be filtered. The needle is built from the configured value. Paths are normalised to forward slashes first because glob returns backslashes on Windows.

| Operation | Linux/macOS | Windows |
|---|---|---|
| Binary dir | `bin/linux/` or `bin/darwin/` | `bin/win32/` |
| Binary suffix | _(none)_ | `.exe` |
| Execute bit | `vim.uv.fs_chmod(path, 73)` | no-op |
| Open URL | `xdg-open` / `open` | `cmd /c start "" <url>` |
| Extract ZIP | `unzip` | `tar.exe` (Win10+) |
| Recursive copy | `cp -r` | `xcopy /s /e /i /q` |
| Stderr suppress | `2>/dev/null` | `2>nul` |
| DAP adapter env | minimal string-array (SIGABRT prevention) | `nil` (inherit) |

External requirements: `curl` and `tar.exe` built into Win10+. `rg` (ripgrep) required on all platforms. `az` optional for Entra auth.

## The AL dotnet tool is the toolchain

**Every AL operation runs through the AL dotnet tool (`al`) except formatting
and interactive debugging.** User directive, restated 2026-10-01. Compile
(`al compile`), publish (`al publishapp`), symbols (`al downloadsymbols` CLI on
tool 30+, MCP `al_downloadsymbols` on older tools), the MCP server
(`launchmcpserver`) and the agentic LSP (`launchlspserver`) all spawn
`altool.binary()`. The VS Code extension is used only for:

- **EditorServices LSP** — only when `experimental_lsp = false`. The tool's own server
  (`launchlspserver`, the user's backend since 2026-10-01) formats and loads base symbols
  too; it lacks code actions. See the agentic LSP section.
- **DAP adapter** — `:ALLaunch` / F5. Neither the MCP server nor the CLI has
  breakpoint/step/continue; 30.x's `launchsnapshotmcpproxy` captures snapshots only.

**There is no fallback to the extension, and there must not be one.** Compile
used to fall back to the extension's `alc` and publish to the DAP adapter, then
a direct HTTP POST. On a Windows laptop where the tool was not found, that
turned "tool missing" into a build with the wrong compiler and a publish that
crashed (the DAP adapter cannot publish on-prem on Windows). A missing tool now
fails with `altool.missing_msg()`, which names every path it searched.

**`altool.binary()` is the only resolver — never build `~/.dotnet/tools/al`
elsewhere.** It tries `~/.dotnet/tools/al[.exe]`, then (Windows)
`%USERPROFILE%\.dotnet\tools\al.exe`, then `exepath("al")`. `~` alone is not
enough: Neovim expands it from `$HOME`, which a corporate Windows machine often
points at a network drive, while `dotnet tool install -g` always writes under
`USERPROFILE`. Three modules used to carry their own copy of the path; mcp.lua's
had no `.exe`, so `:ALMcpSetup` could never succeed on Windows. Analyzer DLLs are
found in the tool's `.store`, located as a sibling of the *resolved* binary for
the same reason.

`:ALInfo` lists the binary, its version, and which command each operation uses.

## AL Toolchain paths

`ext.lua` picks the highest-version **usable** `~/.vscode/extensions/ms-dynamics-smb.al-*` directory.

**Two layouts exist; never assemble `bin/<platform>/…` paths outside ext.lua.**

| | native (≤ 18.0.2293710) | dotnet (≥ 18.0.2668733) |
|---|---|---|
| host | `bin/<platform>/EditorServices.Host[.exe]` | `bin/EditorServices.Host.dll` |
| alc | `bin/<platform>/alc[.exe]` | `bin/alc.dll` |
| analyzers | `bin/Analyzers/*.dll` | `bin/*.dll` (flat) |
| launch | run directly | `dotnet <dll>` (net10.0: needs **both** NETCore.App and AspNetCore.App) |

Go through `ext.host_cmd()` / `ext.alc_cmd()` / `ext.analyzers_dir()`, which return command **arrays** and resolve the difference. `ext.layout` is `"native"`/`"dotnet"`/nil. A dotnet-layout install only counts as usable when a muxer is found (`dotnet_path` → `DOTNET_ROOT` → PATH → VS Code's bundled runtime); otherwise selection falls back to an older native install rather than picking one that cannot spawn.

**Never `require("al")` from ext.lua's module body.** `al/init.lua` used to seed `ext_path = require("al.ext").path` in its defaults, so once ext.lua read config back it produced `al -> al.ext -> al` and "loop or previous error loading module 'al'", killing the whole plugin. That default is gone; `M.dotnet()` reads `package.loaded["al"]` instead, and re-reads `dotnet_path` on every call because ext.lua loads before `setup()` runs.

**Glob pitfall:** use `vim.fn.glob(vim.fn.expand("~") .. "/.vscode/extensions/ms-dynamics-smb.al-*", false, true)` — NOT `vim.fn.glob(vim.fn.expand("~/.vscode/extensions/ms-dynamics-smb.al-*"), ...)`. `expand` with a wildcard does its own glob, causing double-expansion that silently returns nothing.

```
<ext_path>/bin/{linux,win32,darwin}/Microsoft.Dynamics.Nav.EditorServices.Host[.exe]
<ext_path>/bin/{linux,win32,darwin}/alc[.exe]
<ext_path>/bin/Analyzers/Microsoft.Dynamics.Nav.CodeCop.dll  ← shared
```

`platform.bin_subdir()` → `"linux"` / `"win32"` / `"darwin"`. Never hardcode `bin/linux/`.

Linux/macOS binaries ship without execute bit. `platform.ensure_executable()` uses `vim.uv.fs_chmod(path, 73)` (decimal — LuaJIT/Lua 5.1 has no `0o` octal literals).

## Loading / pack setup

`vim.pack.add` defaults `load = false` during `init.lua` — must pass `{ load = true }` to source `plugin/` files. Installed copy at `~/.local/share/nvim/site/pack/core/opt/ALNvim/`; pull dev changes with `git -C ~/.local/share/nvim/site/pack/core/opt/ALNvim pull origin master`.

## LSP

AL server speaks LSP over stdio, started via `FileType al` autocmd with `vim.lsp.start`.

### Custom protocol methods

| Method | Direction | Purpose |
|---|---|---|
| `al/setActiveWorkspace` | client → server | Trigger indexing. Once per client (`client._al_workspace_set` guard). Re-sent by `cops.apply()` and `:ALAnalyze`. |
| `al/activeProjectLoaded` | server → client | Indexing complete. **REQUEST** — must respond with `vim.NIL`. |
| `al/progressNotification` | server → client | Loading progress. Notification — no response. |
| `al/gotodefinition` | client → server | Go to definition (`definitionProvider = false`). Returns `file://` or `al-preview://` URI. |
| `al/previewDocument` | client → server | Fetch `al-preview://` source. Payload: `{ Uri = uri }`. Response: `{ content = "..." }`. |

### `al/setActiveWorkspace` — critical payload format

**Must be wrapped as `{ currentWorkspaceFolderPath, settings }`** — sending settings fields at top level causes silent deserialization failure (project never loads, `al/gotodefinition` returns `projectId = null`).

**Send once per client** — server restarts full indexing on every call. Sending per-buffer causes perpetual reloads where hover/gd refuse to work until indexing completes.

```lua
client:request("al/setActiveWorkspace", {
  currentWorkspaceFolderPath = {
    uri   = "file://" .. root,
    name  = vim.fn.fnamemodify(root, ":t"),
    index = 0,
  },
  settings = {
    workspacePath                   = root,
    alResourceConfigurationSettings = {
      packageCachePaths    = { root .. "/.alpackages" },
      assemblyProbingPaths = {},   -- MUST be non-null array; empty avoids network-mount hang
      enableCodeAnalysis   = true,
      backgroundCodeAnalysis = "Project",
      enableCodeActions    = true,
      incrementalBuild     = true,
    },
    setActiveWorkspace                  = true,
    dependencyParentWorkspacePath       = vim.NIL,
    expectedProjectReferenceDefinitions = proj_refs,
    activeWorkspaceClosure              = {},
  },
}, callback, bufnr)
```

**`expectedProjectReferenceDefinitions`** — always prepend implicit Microsoft base packages (System, System Application, Business Foundation, Base Application, Application) using stable GUIDs, even when `app.json` has no dependencies. Without them, AL server never loads standard symbol tables. Versions from `app.json` `platform`/`application` fields. Explicit deps appended after, duplicates skipped. Single shared builder: `require("al.lsp").build_project_refs(root)` — used by both `plugin/al.lua` (first send) and `cops.apply()` (every re-send); never build this list inline.

**`assemblyProbingPaths` must be a non-null JSON array** — omitting causes `ArgumentNullException("path")` crash. VSCode default `['./.netpackages']` hangs on CIFS/SMB — use `{}`.

### `al/activeProjectLoaded` — must return a response

```lua
vim.lsp.handlers["al/activeProjectLoaded"] = function(err, result, ctx)
  if not err then vim.notify("AL: project loaded", vim.log.levels.WARN) end
  return vim.NIL  -- required: send null JSON-RPC response
end
```

### Progress fallback

Some server versions reach 100% via `al/progressNotification` but never fire `al/activeProjectLoaded`. If status is still `"loading"` 3 seconds after percent ≥ 100, call `set_lsp_ready()` automatically.

### `gd` keymap override

Server has `definitionProvider = false`. Override `gd` to use `al/gotodefinition`. Use `vim.schedule` to defer so it wins over user's generic `LspAttach` handler.

**Two return types:**
1. `file://` URI — open with `vim.cmd("edit ...")`, then `vim.api.nvim_get_current_buf()` (never pass `0` — invalid handle).
2. `al-preview://` URI — fetch via `al/previewDocument { Uri = uri }` → `result.content`. Show in read-only `nofile` scratch buffer (`filetype=al`). Strip `\r\n` before splitting.

**Do not use `vim.lsp.util.jump_to_location` or `vim.lsp.util.show_document`** — deprecated / "cursor position outside buffer" errors.

`al/setActiveWorkspace` and `al/gotodefinition` always appear "pending" in `client.requests` — server responds via `window/logMessage` notifications. Expected behaviour.

### Non-standard completion item labels

AL server sends `label` as `{ label = "begin" }` (object) instead of a plain string — crashes nvim-cmp. `vim.lsp.handlers["textDocument/completion"]` and the `handlers` table in `vim.lsp.start` do **not** intercept this (nvim-cmp calls `client:request` directly). Fix: monkey-patch `client.request` in `LspAttach`:

```lua
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
              if type(item.label) == "table" then item.label = item.label.label or "" end
            end
          end
        end
        return _cb(err, result, ...)
      end
    end
    return _orig(self, method, params, callback, bufnr_)
  end
end
```

### Agentic LSP (`al launchlspserver`) — the user's backend since 2026-10-01

`require("al").setup({ experimental_lsp = true })` (set in the user's `native.lua`). Swaps
the VS Code extension's `EditorServices.Host` for the **standard** LSP shipped by the AL
dotnet tool: `al launchlspserver <root> --packagecachepath <root>/.alpackages`.

- Runs as a distinct client **`al_agentic_lsp`**. Every EditorServices protocol workaround
  in `plugin/al.lua` is guarded on the `al_language_server` name, so none apply.
- `lua/al/agentic_lsp.lua` — `M.start(bufnr, root)`, `M.available()`, `M.binary()`
  (delegates to `altool.binary()`), `M.pids` (VimLeavePre kills the tree). `on_attach` sets
  the statusline + `set_lsp_ready()` (no progress/loaded events), configures MCP once, and
  maps `gd` to `al.basedef.definition` (scheduled so it wins over user maps).
- **Extension-independent**: needs only the tool and `.alpackages`.

**Capabilities, re-probed 2026-10-01 on tools 18.0.37 and 30.0.42 (identical):**

| works | missing |
|---|---|
| formatting (`documentFormattingProvider`; newText uses `\r\n`, which `vim.lsp.util` normalises) | `codeActionProvider` — `<leader>ac*`, organise-imports-on-save are no-ops |
| base symbols from `.alpackages`: hover shows a base table's fields, completion on `Cust.` lists them, references | `textDocument/definition` for anything in a symbol package **and for local variables/parameters** |
| definition of the project's own procedures | `al-preview://` documents |

This supersedes the earlier finding that it "does not load base symbols" — it does now.

**`gd` = `al.basedef.definition()`.** The server's answer when it has one; otherwise hover
names the target and the fallback resolves it:

- hover `(local) Mgt: Codeunit "Sales-Post"` (no qualifier) → the variable's **declaration**
  in the buffer (nearest above first, then anywhere — globals sit at the end of AL objects).
  `G := 1` must not match as a declaration of `G`.
- hover `Table Microsoft.Sales.Document."Sales Header"` → the object's declaration in the
  `.al` stubs `explorer.build_search_dirs` extracts from `.alpackages`, via rg. Opened
  read-only; `m'` first so `<C-o>` returns.
- `Var.Member` → hover the *qualifier* for its type, open that object, jump to the
  field/procedure/value. A member not declared there (built-in `Count`, or added by an
  extension) notifies instead of jumping to the object's first line.
- Object names match **fully quoted or bare** (`("X"|X)` then a boundary). With both quotes
  optional, `"Sales Header"` also matched `"Sales Header Archive"`, and rg's unordered
  output decided which one opened.
- Names: take the last *quoted* segment — `Microsoft.Purchases.Document."Purch. Header"`
  has a dot inside the quotes.
- **NuGet symbol packages ship without `.al` source** (extraction stamps `0`); for those it
  notifies and hover is the answer. Server-downloaded packages usually include source.
- First search per package extracts its sources synchronously (~8s for Base Application);
  `explorer.pending_extracts(root)` gates a "first time only" notice before it.

**Features must not key on `al_language_server`.** `lsp.client(bufnr)` returns whichever AL
client is attached (`lsp.CLIENT_NAMES`). Format-on-save looked up the EditorServices name
only, so switching backends silently stopped formatting. Organise-imports and
`compile.clear_lsp_diagnostics` go through the same list; `cops.apply` (an EditorServices
`al/setActiveWorkspace` re-send) tells an agentic user the cops apply at compile instead.

**Still EditorServices-only:** `debug.save_creds_to_lsp` stores on-prem UserPassword
credentials through `al/saveUsernamePassword` on the EditorServices client, which the DAP
adapter then reads. With only the agentic client running it is skipped, so **on-prem
UserPassword F5 debugging is likely to fail authentication**. Cloud (AAD) debugging does not
use it. Not verified against a server.

**The FileType root is bounded** (`lsp.find_root_upward`, not `vim.fs.root`). For this
backend the root is the workspace the server indexes.

## Compiling

`:ALCompile` runs `alc /project:<root> /packagecachepath:<root>/.alpackages` async. Full-width horizontal split (~30% height) streams output live. `<CR>` on diagnostic opens file at line/col. `q`/`<Esc>` closes panel. Quickfix also populated (`<leader>aq`).

Code analyzers from `alnvim.json` auto-included as `/analyzer:` flags. `ruleset_path` in `setup()` passes `/ruleset:<file>`. **Do not add `ruleSetPath` to `app.json`** — custom properties break AL validation.

Success: exit code 0 + empty quickfix. Error format: `/path/file.al(line,col): error|warning ALxxxx: message`.

`M.compile(dir, extra_args, on_success)` — `on_success()` called in `vim.schedule` only on clean build. `publish.lua` chains upload via this.

**Job output must be line-buffered.** `jobstart` without `stdout_buffered` delivers chunks where `data[1]` continues the previous chunk's partial line and `data[#data]` is itself partial. Appending chunks verbatim splits diagnostics across two "lines" so they never match the quickfix pattern. `line_stream(on_lines)` returns `(feed, flush)`; give stdout and stderr **separate** carries and call both `flush()` in `on_exit`. Same pattern as `altool.mcp_call`.

**`analyze_diagnostics` cancellation.** A job cancelled via `jobstop` still fires `on_exit` with partial output. `_analyze_gen` is bumped per call and captured; a stale `on_exit` returns early instead of resetting the diagnostic namespace and clobbering `_analyze_job`. `M.analyze_soon(dir)` debounces (`analyze_debounce_ms`, default 1500) — BufWritePost uses it so `:wa` schedules one build, not one per file.

**Compiler (`compiler_prefix()`)** — `{ altool.binary(), "compile" }`, or nil when the
tool is missing (→ `altool.missing_msg`). No extension fallback; see "The AL dotnet tool
is the toolchain". `al compile` forwards `/project:` `/packagecachepath:` `/analyzer:` to the
alc it bundles — so seeing `alc` in a process list does **not** mean the extension's
compiler ran. Analyzer DLLs (`analyzer_dll()`) come only from the tool's store: the
`net8.0` build under `<tool dir>/.store/.../tools/net8.0/any/`, cached per resolved binary.
Verified e2e on tool 30.0.42 with no VS Code extension installed and the tool found only
via PATH: clean build, `.app` produced.

**`<CR>` path resolution** — `alc` inherits Neovim's cwd, which may differ from `project_dir` (e.g. cwd = parent of project). `build_cwd = vim.fn.getcwd()` captured at compile time; relative paths in `alc` output resolved against `build_cwd`, not `project_dir`. Same applies to `parse_output` (fixes quickfix/diagnostic filenames).

**`<CR>` target window fallback chain**: (1) `file_win` captured at build open time, (2) any non-floating non-build window (e.g. alpha dashboard — reused rather than split), (3) new `aboveleft split` above build panel. `file_win` updated on fallback so subsequent `<CR>` presses reuse the same window.

## Keymaps

`<leader>aa` is **global** (works from any buffer including alpha dashboard).

| Key | Action |
|---|---|
| `<leader>aa` | **ALActions** — Telescope picker for all AL commands with descriptions (global) |

### AL buffers only

| Key | Action |
|---|---|
| `<leader>ab/ap/aP/as` | Compile / Publish / PublishOnly / DownloadSymbols |
| `<leader>ao/al` | OpenAppJson / OpenLaunchJson |
| `<leader>aq` | Quickfix list |
| `<leader>ac/aB` | SelectCops / SelectBrowser |
| `<leader>am/aM` | McpSetup / McpStatus |
| `<leader>ah/aH/aG` | Help / HelpTopics / Guidelines |
| `<leader>an/aw/aW` | NewObject / ReportLayout / OpenLayout |
| `<leader>aR` | GeneratePermissionSet — scan all project objects and create a `.PermissionSet.al` file |
| `<leader>aN` | AddNamespace — add namespace to all source files |
| `<leader>aA/aD/ae/af/ag` | Analyze (silent alc pass) / Diff / Explorer / ExplorerProcs / Search |
| `<leader>aca/acf/acF/acn/acr` | Code actions (all/fix/fixAll/organise/refactor) — `acr` works in visual mode |
| `<leader>ace` | ExtractProcedure — extract visual selection into a new `local procedure` (auto-detects params from var block) |
| `<leader>acs` | CreateSnippet — wizard to save visual selection as a user snippet to `snippets/al-user.json` |
| `grn` | RenameObject — rename quoted AL identifier project-wide (falls back to LSP rename for unquoted symbols) |
| `<F5>`/`<leader>adl/ads/adf/add` | Launch / SnapshotStart / SnapshotFinish / DebugSetup |
| `<leader>adX` | DapClose — terminate session, close all debug windows, restore pre-debug buffer |
| `gd` / `<C-o>` | AL go-to-definition / jumplist back |
| `<C-Space>`/`<Nul>` (insert) | Object ID completion (`<C-x><C-u>`) |

Explorer picker: `<C-s>` cycle sort (type/id/publisher/name), `<C-f>` live grep, `<CR>` open.

**Return-on-close.** Telescope closes on select and cannot host a file behind it, so the explorer instead *comes back*: `<CR>` arms a one-shot `BufDelete`/`BufWipeout` watcher on the opened buffer, and closing that buffer reopens the picker. The built entry list is cached in `_last`, so `M.reopen()` rebuilds from it — measured 0.2ms and **no second rg process**. Only the most recently opened file is watched (`arm_return` disarms first), and `v:exiting` is checked so `:qa` does not try to build a Telescope window on the way out. Disable with `explorer_return = false`; `:ALExplorerReopen` works either way.

## User commands

`:ALNewProject`, `:ALInstallExtension`, `:ALUpdateExtension`, `:ALInstallDotnetTool`, `:ALCompile [dir]`, `:ALPublish [dir]`, `:ALPublishOnly [dir]`, `:ALDownloadSymbols [dir]`, `:ALDownloadSymbolsGlobal [dir]`, `:ALSetNuGetFeeds [dir]`, `:ALLaunch [dir]`, `:ALSnapshotStart/Finish`, `:ALDebugSetup`, `:ALDapOutput`, `:ALDapClose`, `:ALHelp [url]`, `:ALHelpTopics`, `:ALGuidelines`, `:ALNewObject [dir]`, `:ALGeneratePermissionSet [dir]`, `:ALReportLayout`, `:ALOpenLayout`, `:ALExplorer [dir]`, `:ALExplorerReopen`, `:ALExplorerProcs`, `:ALSearch [dir]`, `:ALNextId`, `:ALAnalyze`, `:ALReindex`, `:ALAddNamespace [dir]`, `:ALDiff [dir]`, `:ALSelectCops`, `:ALSelectBrowser`, `:ALMcpSetup/Remove/Status [dir]`, `:ALOpenAppJson`, `:ALOpenLaunchJson`, `:ALReloadSnippets`, `:ALClearCredentials`, `:ALRenameObject`, `:ALExtractLabel`, `:ALExtractProcedure`, `:ALCreateSnippet`, `:ALActions`, `:ALInfo`, `:ALUpdate`

## Project root detection (`lsp.get_root()`)

1. Search upward from current buffer for `app.json` — **bounded** (`find_root_upward`)
2. Scan downward from `vim.fn.getcwd()` for all `app.json` files
3. One found → use it; multiple → `vim.fn.inputlist` prompt

All commands use `lsp.get_root()` — `compile.lua` has no separate `find_project_root()`.

**The upward search must stay bounded.** `vim.fs.root()` walks to the filesystem root, so one stray `app.json` above a project claims every file beneath it. A single `/mnt/rojaws/app.json` made every project on an NFS share resolve to the mount point, and AL Explorer then indexed the whole share — 77k objects and 14s, against 9.5k and 0.3s for the real project. `find_root_upward` stops at the enclosing `.git` directory (or `MAX_UP` levels without one) and returns a reason; `get_root` stores it in `M.last_root_reason`, which `:ALInfo` prints. It is deliberately not notified — `get_root` runs on every save.

## Symbol downloads

`<leader>as` / `:ALDownloadSymbols` prompts for source; `:ALDownloadSymbolsGlobal` skips
the picker. Both sources go through the AL dotnet tool, by whichever route it offers
(`symbols.lua` `transport()`):

| | tool 30+ — CLI `al downloadsymbols` | older — MCP `al_downloadsymbols` |
|---|---|---|
| output | streamed live (`--raw`) into `altool.run`'s float | one result at the end |
| global | `--globalsourcesonly` + `--symbolscountryregion` + `--nugetfeeds` (repeated) | `globalSourcesOnly = true`; **no custom feeds** (warns) |
| server | `altool.connection_flags(cfg)` | `altool.connection(cfg)`; AAD sets `useInteractiveLogin` |

Server downloads use `conn.pick_launch`, the same picker as publish; UserPassword
credentials go in via `altool.cred_env` (`BC_SERVER_USERNAME`/`BC_SERVER_PASSWORD`).
`--force` on every run — an explicit download means refresh.

Removed, with reasons: the EditorServices request `al/downloadSymbolsFromGlobalSources`
(needed the extension's server running for the project) and the hand-rolled curl calls
to `/dev/packages` (own auth path; only the five base packages plus direct dependencies,
never transitive ones). The tool resolves dependencies itself, transitively.

**Live streaming matters for AAD.** Sign-in can stop and print a device code; collected
output would leave the user watching a job that never finishes.

AppSource-registered ISV packages (Continia, etc.) resolve via the built-in feeds.
Custom `nugetFeeds` (`:ALSetNuGetFeeds`, else `.vscode/settings.json` `al.nugetFeeds`) are
for additional public NuGet v3 feeds and need tool 30+.

**BC v29 symbols are not on Microsoft's feed yet** (2026 wave 2 is not GA as of
2026-10-01), so a project targeting `application: 29.0.0.0` — `:ALNewProject`'s default
top entry — fails global download with "Exact version 29.0 not found". Not a tool fault.

## BC dev API endpoints

- On-prem: `http[s]://<server>:<port>/<serverInstance>`
- Cloud: `https://api.businesscentral.dynamics.com/v2.0/<tenant>/<env>`

**Cloud detection** (`connection.is_cloud`): non-empty `server` field not containing `microsoft.com`/`dynamics.com` = on-prem, regardless of `environmentType`. Allows BCContainer launch.json to keep `environmentType` for VSCode compat.

**On-prem port** (dev endpoint, not web client): `port` field → port in `server` field → default 7049. `webclient_url` uses `server` as-is (port 80/443).

| Feature | Method | Path |
|---|---|---|
| Download symbols | GET | `/dev/packages?publisher=…&appName=…&versionText=…&tenant=…` |
| Publish | POST | `/dev/apps?tenant=…&SchemaUpdateMode=…` |
| Snapshot start/download | POST/GET | `/dev/debugging/snapshots[/<sessionId>]` |

## Credentials (`connection.lua`)

- `M.curl_auth(cfg)` — sync
- `M.get_auth(cfg, cb)` — async (used by symbols, publish, debug)

**UserPassword/NavUserPassword order:** `userName`/`password` in launch.json → `al_username`/`al_password` in launch.json → `AL_BC_USERNAME`/`AL_BC_PASSWORD` env vars → interactive prompt (session-cached).

**MicrosoftEntraID order:** `AL_BC_TOKEN` env var → session cache → `az account get-access-token --resource https://api.businesscentral.dynamics.com --tenant <tenant>` → `az login --allow-no-subscriptions --use-device-code` (if not signed in) → manual `inputsecret` (if az missing).

- `--allow-no-subscriptions` required for `az login` (M365/BC-only tenants). **Not** valid for `az account get-access-token`.
- `--tenant` required for `az account get-access-token` (multi-tenant accounts).
- `"authentication": "Windows"` uses NTLM (`--ntlm --negotiate -u :`) — silently fails on Linux without Kerberos. Use `"UserPassword"` for on-prem, `"MicrosoftEntraID"` for cloud.

## BC Dark colorscheme

Auto-applied on AL window focus, restored on non-AL focus.

**Opt out with `setup({ colorscheme = false })`**, or name another with
`colorscheme = "bc_yellow"`. The ftplugin used to apply `bc_dark` unconditionally,
so a user's own colorscheme was silently replaced the first time any `.al` file
was opened — with no setting to prevent it. The override now only fires when the
current `colors_name` is not already a `bc_*` one, so re-entering an AL buffer
does not fight a deliberate switch. Key colours: bg `#1E1E1E`, fg `#D4D4D4`, keywords `#00747F` (teal), types `#4EC9B0` (aqua), functions `#DCDCAA`, variables `#9CDCFE`, strings `#CE9178`, numbers `#9FD89F`, constants `#62CFD7`, status bar `#00747F`/`#FFFFFF`.

**`bc_yellow`**: near-black green bg `#010704`, fg `#efefef`, comments `#04b925`, keywords/types `#f6fa16`. Set as global default via `colorscheme bc_yellow` in `init.lua` — no per-window switching.

**Syntax strings use `oneline`** on `alString`, `alVerbatim`, `alQuotedIdent` — without it, unclosed quotes bleed colour across the file.

## AL Explorer (`lua/al/explorer.lua`)

**All symbol-package searches must be async.** These cover the project *plus* every extracted package (Base Application alone is ~10k `.al` stubs), so `vim.fn.systemlist` freezes the editor for the whole search. Use `explorer.rg_async(cmd, cb)` and build the picker in the callback. The one place that cannot be async is `ids.get_used_ids` (reached from `completefunc`, which is synchronous) — it caches per project+type and `ids.invalidate()` is called from the ftplugin `BufWritePost`.

`M.objects`: `rg` across project root + `~/.cache/nvim/alnvim/symbols/` extracted packages. Entry: `[src]`/`[sym]` tag, publisher, type, ID, name, filename. `<C-s>` cycles sort.

**Symbol extraction:** `.app` files are ZIPs with `src/*.al` stubs, extracted to cache dir keyed on sanitised filename. `.ok` stamp skips re-extraction. `unzip` exits code 1 on no-match glob (not failure) — check `vim.fn.isdirectory(dir .. "/src")` not `vim.v.shell_error`.

Publisher from filename format `Publisher_Name_Major.Minor.Build.Rev.app`.

## Object ID completion (`lua/al/ids.lua`)

`<C-Space>`/`<Nul>` in insert mode on object-type keyword line → `<C-x><C-u>`. Global `_G.ALCompleteObjectId` bridges to `require("al.ids").complete` (avoids `v:lua` compatibility issues). Shows up to 5 free IDs per range with usage info. `:ALNextId` notifies next 3 free IDs in normal mode.

**The used-ID cache must be dropped whenever ALNvim itself writes an `.al` file.** `ids.invalidate()` runs from the ftplugin `BufWritePost`, but `wizard.write_and_open` uses `vim.fn.writefile` (fires no autocommands) and `:edit` (a read) — so it calls `invalidate()` directly. Without that, `next_id` serves a stale set and two objects of the same type created in one session get the **same ID**.

Types with IDs: `table`, `tableextension`, `page`, `pageextension`, `pagecustomization`, `codeunit`, `report`, `reportextension`, `query`, `xmlport`, `enum`, `enumextension`, `permissionset`, `permissionsetextension`, `profile`, `controladdin`.

## Code Cops (`lua/al/cops.lua`)

Four cops: `${CodeCop}`, `${PerTenantExtensionCop}`, `${UICop}`, `${AppSourceCop}`. Default: first three. Config + browser saved to `<root>/.vscode/alnvim.json`. After confirm, `cops.apply()` re-sends `al/setActiveWorkspace` — live effect without LSP restart. Telescope: `<Tab>` toggle, `<CR>` apply. Fallback: iterative `vim.ui.select` with `[x]`/`[ ]`.

Browser values stored in `alnvim.json` as `"browser"`. macOS: no-path value → `open -a <browser>`. `platform.open_url(url, browser)` — empty browser → OS default. `_current_root` in `debug.lua` set at start of `M.launch`/`M.setup_dap` for global DAP listeners.

## AL MCP Server (`lua/al/mcp.lua`)

Writes **`<project>/.claude/settings.json`** to spawn `al launchmcpserver` via stdio. Entry key: `"al:" .. basename(root)`. Binary: `altool.binary()`. Read/write pattern: `readfile` → `json_decode` → mutate → `al.json.write` (preserves all other keys).

**Per-project, never global.** This wrote `~/.claude/settings.json` until 2026-09-15. With `auto_mcp` on by default, every AL project ever opened left an entry there — eleven had accumulated, including one for a deleted `/tmp` scratch dir. The entry's **last positional argument is the server's workspace root**, so a stale or mis-resolved one is not inert: it is an AL language server indexing that tree in *every* Claude Code session. One (`al:rojaws`) pointed at a 3.6TB NFS share, because a stray `app.json` above the projects made `get_root()` resolve the mount point. `lsp.find_root_upward` now bounds that resolution; writing per-project bounds the damage if it ever resolves wrongly again. `:ALMcpStatus` reports leftover global `al:*` entries but does not remove them — that file holds the user's own config.

**Never overwrite a settings file you could not parse.** `mcp.read_settings` returns `(data, err)`: `{}` for absent/empty, `nil` plus a reason when the file exists but is invalid JSON. Collapsing those two into `{}` meant one trailing comma in a hand-edited `.claude/settings.json` was read as empty and then rewritten with only `mcpServers` — destroying the user's permissions and hooks. `auto_mcp` reaches this on every `LspAttach`, so opening one `.al` file was enough.

**Never write user-facing JSON with bare `json_encode` + `writefile`** — that emits one line and flattens the user's formatting. `~/.claude/settings.json` and `.vscode/alnvim.json` go through `require("al.json").write(path, data)`, which indents the encoder's output. `mcp.configure()` also `vim.deep_equal`-checks the existing entry and skips the write when unchanged, because `auto_mcp` calls it on every `LspAttach`. `auto_mcp = true` (default) calls `mcp.configure(root)` once per client on `LspAttach`. Restart Claude Code / run `/mcp` to pick up changes. 8 MCP tools: `al_build`, `al_publish`, `al_debug`, `al_setbreakpoint`, `al_symbolsearch`, `al_downloadsymbols`, `al_snapshotdebugging`.

## AL Extension Installer (`lua/al/install.lua`)

Downloads MS AL VSIX from `vsassets.io` CDN (not marketplace.visualstudio.com — returns non-ZIP redirect). Required headers: `Accept: application/octet-stream`, `X-Market-Client-Id: VSCode`, `User-Agent: VSCode/...`. Verifies ZIP magic bytes (`PK`). Calls `ext.reload()` + `doautocmd FileType al` after install. Registered before `ext_path` guard — always available.

`M.update()` — queries marketplace for latest, compares with `installed_version()`, downloads only if newer. Reports "already up to date" otherwise. Registered as `:ALUpdateExtension`. Installs beside the existing copy (`installed_path(cur)`'s parent), so an update does not scatter versions across `~/.vscode` and `~/.vscode-insiders`.

**Every "is it installed?" check must search both extension dirs.** `EXT_DIR` is the *install target* — the Insiders dir whenever `~/.vscode-insiders` exists, else stable — and is not where an existing copy necessarily lives. `M.install()` tested `EXT_DIR` only, so a user with Insiders present and the extension under stable `~/.vscode` was told it was not installed and re-downloaded the whole 300–700 MB VSIX on every run. `installed_path(version)` / `installed_all()` scan `ext.ext_dirs()`, the same list `ext.find()` uses.

**`version_gt` lives in `ext.lua` and is shared.** install.lua had its own copy that scanned *every* digit run in the string; ext.lua's read only the `ms-dynamics-smb.al-<ver>` tail and returned `{}` for anything else. Neither worked for both callers — ext.lua compares full directory paths, install.lua compares bare version strings like `"18.1.0"`, and ext.lua's version returned "equal" for those, which would have made `:ALUpdateExtension` report "already up to date" forever. The shared `ext.version_gt` takes the version tail when present and a bare string otherwise, and refuses to guess at a path it cannot parse — scanning a whole path lets digits in the *home directory* decide the comparison.

The dotnet-tool "already installed" probe uses `altool.binary()`, so it tests the binary the MCP client and agentic LSP actually spawn rather than re-deriving the path.

`M.install_dotnet_tool()` — checks if `~/.dotnet/tools/al[.exe]` exists, runs `dotnet tool install` (first time) or `dotnet tool update` (already installed) for package `microsoft.dynamics.businesscentral.development.tools`, streams output live. Registered as `:ALInstallDotnetTool`. Requires `dotnet` on PATH.

## AL Text Objects (`lua/al/textobj.lua`)

| Keys | Selects |
|---|---|
| `af`/`if` | around/inside procedure or trigger |
| `aF`/`iF` | around/inside nearest begin/end or case/end block |

**`block_bounds` must scan a line's tokens in source order.** Counting every
`begin` on a line before every `end` makes `end else begin` net out to zero —
the most common multi-token line in AL — so depth never reaches zero at the
`else` and `aF` swallows the else-branch along with the if-branch. The backward
walk records the *index* of the opening token as well as its line, and the
forward walk starts at `bidx + 1`: restarting at the opening line's first token
re-consumes the `end` in `end else begin` and closes the block on its own
opening line.

## AL Go! — new project (`lua/al/project.lua`)

`:ALNewProject` scaffolds `app.json` + `.vscode/launch.json` + a starter
pageextension. `"platform": "1.0.0.0"` is **not** a placeholder — MS's own
templates under `<ext>/templates/*/app.json` ship exactly that; only
`application` tracks the chosen runtime.

**The starter object is written to its CRS path, not the project root.**
`HELLO_WORLD_PATH` is `src/pageextension/CustomerListExt.PageExt.al` and must
agree with `wizard.build_path`. VSCode's template puts `HelloWorld.al` at the
root, but ALNvim runs `wizard.organise_file` on `BufWritePost` for every AL file
under the root — so a root-level starter object was renamed out from under the
user on the very first `:w`. Writing it in the right place also means
`ids.invalidate()` has to be called explicitly (same reason as `wizard`:
`vim.fn.writefile` fires no autocommands).

**No `showMyCode`.** Emitting it alongside `resourceExposurePolicy` is compiler error
AL1075, so every generated project failed its first build until 2026-10-01. MS's
templates carry `resourceExposurePolicy` only.

**`gen_uuid` seeds once per session and draws from `vim.uv.random`.** It used to
reseed from `os.time() + os.clock()` on every call, which makes the value a
function of when the call happened rather than of any entropy. This is the
app.json `id`; BC rejects two extensions claiming the same one.

## AL Object Wizard (`lua/al/wizard.lua`)

12 types: Table (DataClassification), TableExtension (extends picker), Page (PageType + SourceTable), PageExtension (extends), Codeunit, Report (SourceTable), Query (SourceTable), XmlPort, Enum (Extensible), EnumExtension (extends), Interface (no ID), PermissionSet (auto-generates permissions).

`M.generate_permissionset(root)` — skips the type picker, goes directly to ID → name → scan. Mirrors VS Code "AL: Generate Permission Set". Calls `run_wizard` with the permissionset entry directly.

File naming (CRS): `src/<obj_type>/<SanitisedName>.<FileType>.al` — no object ID. `build_path()` and `organise_file()` derive this independently and must stay in step; adding an ID to one would make `organise_file` rename every existing file on its next save. Interface: `src/interface/<Name>.Interface.al`. Auto-moves on `:w` (`wizard.M.organise_file` via `BufWritePost` in `ftplugin/al.lua`) — uses `vim.fn.rename` + `nvim_buf_set_name`, no reload needed.

PermissionSet scan uses `platform.glob_al_files(root)` + `io.open` (not `find` — not available on Windows). Tables generate two entries (`tabledata RIMD` + `table X`); others get `X`.

## AL Refactoring (`lua/al/refactor.lua`)

**Quote scanning pairs delimiters left to right.** Both `find_quoted_string` (single) and `dquoted_id_at_cursor` (double) walk from the start of the line pairing quotes, treating a doubled quote as an escape. Do not "scan left for the nearest quote" — a cursor on a *closing* quote then pairs it with the next string's opening quote, so `Cust.Get("Foo"); Other("Bar")` yields `); Other(` as the rename target.

**`find_proc_bounds(lines, cursor_lnum)`** — all line numbers 1-based. Returns `{ hdr, var, beg, fin }`. `var` is nil if no var block. Used by both `extract_label` and `extract_to_procedure`.

**`M.extract_to_procedure()`** — extracts visual selection (`'<`/`'>` marks) into a new `local procedure`:
1. Parses `var` block (lines `b.var+1`..`b.beg-1`) — greedy regex captures full type including `Record "Name" temporary`, `List of [...]`, etc. Skips `Label`/`TextConst` (compile-time constants, not passable as params).
2. Finds referenced vars in selection → parameters. `var` prefix when: type is `Record`/`array`/`List`/`Dictionary`, OR assigned (`:=`) in selection.
3. Re-indents body by stripping `min_indent` then adding `proc_indent .. "    "`.
4. **Bottom-up edit order**: insert new procedure at `b.fin` first (below selection), then replace selection. This keeps selection line numbers valid — do not reverse.

**V1 limits**: only detects local `var` block vars (not outer procedure params); identifiers inside string literals may false-match.

**`M.extract_label()`** — cursor inside single-quoted string → prompts for Label var name → replaces all occurrences in proc body → inserts `var` declaration (local or global scope).

## Snippets (`lua/al/snippets.lua`)

`M.load()` / `M.reload()` — load both `snippets/al.json` (committed, read-only) and `snippets/al-user.json` (user-created) via `from_vscode.load({ paths = { PLUGIN_ROOT } })`. Both files listed in `package.json`; LuaSnip picks them up automatically.

`M.create_from_selection()` — wizard to create a user snippet from visual selection:

1. Read `'<`/`'>` marks → extract lines. Guard: `sel_start == 0` → WARN + return.
2. Suggest prefix: first `%a[%w_]*` identifier in first non-blank line, lowercased, max 20 chars.
3. Four chained `vim.ui.input` prompts (nested callbacks):
   - **Name** — display name (default `"My AL Snippet"`)
   - **Prefix/trigger** — expansion trigger (default = suggested prefix)
   - **Description** — optional; omitted from JSON if blank
   - **Tabstop words** — comma-separated; `<Esc>` cancels wizard
4. Body transform (inside `vim.schedule`):
   - Strip common leading indent (ignores blank lines for min-indent calc)
   - Escape literal `$` → `\$` before inserting tabstop markers
   - Apply tabstop substitutions: word N → `${N:word}` first occurrence, `$N` subsequent; uses `%f[%w_]` frontier pattern for word boundaries
   - Append `"$0"` as final cursor position
5. Read `al-user.json` → merge → `vim.fn.json_encode` → `writefile` (compact JSON; overwrites corrupt file silently).
6. Call `M.reload()` → notify success.

`snippets/al-user.json` — committed empty `{}` seed; never overwritten by plugin updates. Duplicate snippet name → silent overwrite.

## Report Layout Wizard (`lua/al/layout.lua`)

Excel: generated immediately (one sheet/dataitem, BC maps by sheet name). Word/RDLC: rendering entry injected only — `alc /generatereportlayout+` generates files on next `:ALCompile` (requires proprietary OpenXml/alc internals, cannot be replicated in Lua).

`M._inject_rendering`: inserts `DefaultRenderingLayout` after opening `{`, adds `layout()` blocks to existing/new `rendering` section, bottom-up to preserve line numbers. Priority: Excel > RDLC > Word. Duplicate Type → prompt for new name.

`platform.create_zip`: uses Python 3 `zipfile` module (`python3` Linux/macOS, `python` Windows).

## BC dev API / DAP

**DAP adapter startup args** (required):
```lua
dap.adapters.al = {
  type = "executable", command = host,
  args = { "/startDebugging", "/projectRoot:" .. root },  -- REQUIRED
  options = { env = { DOTNET_ROOT = "/usr/share/dotnet", DISPLAY = ..., ... } },
}
```
Without `/startDebugging`: hangs in LSP mode. Without `/projectRoot`: can't locate project.

**`breakOnError`/`breakOnRecordWrite` must be booleans** (adapter 16.x+). `"All"` → `true`, `"None"`/`nil` → `false` via `to_break_bool()`.

**`launchBrowser`**: Linux/macOS → force `false` (adapter xdg-open causes SIGABRT, open from Lua instead). Windows on-prem → must be `true` (adapter requires it; `false` → "internal error"). Windows cloud → `false` (URL comes via `al/openUri` event).

**`M.close_debug()`** (`<leader>adX` / `:ALDapClose`): terminates DAP session, closes adapter output float (`_out_win`), calls `dapui.close()` silently (no-op if dap-ui absent), restores `_pre_debug_buf` (captured at `M.launch()` start). Scans windows first; falls back to `nvim_set_current_buf` if pre-debug buf is not currently displayed.

**One-shot DAP listeners must be armed after a clean compile.** `alnvim_launch_browser` deletes itself when `event_al/refreshExplorerObjects` fires. Registering it *before* `compile()` leaked it on every failed build: the listener never fired, never unregistered, and the next `:ALLaunch` tripped it. `clear_oneshot_listeners(dap)` also runs at the start of `launch` to cover an adapter that dies before emitting the event. (There used to be a second one for `debug.publish_only`; that publish path is gone.)

**⚠️ On-prem ALLaunch on Windows — NOT WORKING**: fails with "Could not publish the package". Cloud works on both platforms. Root cause unknown. Use cloud sandboxes or VSCode for on-prem debugging.

**Publish** (`publish.M.publish`): `al publishapp` only — all BC versions, AAD/Windows/UserPassword auth built in; explicit connection flags from the picked launch config (`altool.connection_flags`) override launch.json; UserPassword creds via `altool.cred_env`. Output streams through `altool.run`. The DAP-adapter (`debug.publish_only`) and direct-HTTP (`publish_http`, BC < 25) fallbacks were removed — they turned a missing tool into a crash on Windows. `:ALLaunch` still publishes through the adapter, because it debugs.

## Inspecting the AL extension protocol

```bash
python3 -c "
with open('~/.vscode/extensions/ms-dynamics-smb.al-*/dist/extension.js') as f: c = f.read()
idx = c.find('activeWorkspaceClosure'); print(c[max(0,idx-2000):idx+500])
"
```
```lua
vim.lsp.log.set_level(vim.log.levels.DEBUG)  -- log at vim.lsp.get_log_path()
```

## Tests

`tests/run.sh` — dependency-free suite (156 assertions). Runs under `nvim --headless -u NONE` with only the repo on the runtimepath: no plugin manager, no plenary, no network.

```bash
tests/run.sh
```

Covers the parsing-level logic where regressions are silent: job-output line framing, alc diagnostic parsing, AL quote scanning, procedure bounds, git path unquoting, JSON writing, the package-cache filter, project references, connection URLs, ID ranges. Pure internals are reached via a `M._test` table on the module — that table is for tests only, never call it from plugin code.

**Write tests that fail against the old code.** Each fix here was verified by reverting it and confirming the suite goes red; a test that passes both ways documents nothing. Two traps found doing exactly that:

- A `.alpackages` fixture cannot test the package-cache filter. `vim.fn.glob("**/*")` never descends into dot-directories, so those files are excluded regardless and the test passes with the filter deleted. Use a **non-dotted** `packagecachepath`.
- Hard-coded cursor columns silently point at the wrong character when a fixture's indentation changes. Derive positions from the fixture string.
- **Stub the fallback you are proving is not taken.** `al.ext` resolves on first
  `require`; if that happens inside a faked environment (empty `HOME`) it reports no
  extension, and a "does not fall back to the extension" test then passes with the
  fallback restored — there was nothing to fall back to. `altool_spec`'s
  `with_fake_extension` makes the extension present regardless of the machine.
- **Record every call, not the last one.** A test asserting "the server started for
  `top`" by keeping the last root seen passed with the bug restored: the bad path also
  resolved to `top`, so the final value matched. Collect all calls and compare the list.
- A mutation that is a pure reordering (swapping two mutually exclusive `if`
  branches) *should* stay green. Use one as a control: if it goes red, the test
  is asserting on something incidental.

## Project layout

```
<project>/app.json  .alpackages/  .snapshots/  .vscode/launch.json  src/*.al
```

## AI agents (Claude Code / Pi)

`lua/al/agent.lua` opens an AI coding agent in a terminal split at the project root:
- `:ALClaude` / `<leader>ai` → **Claude Code** (`claude` CLI; uses the `al:<project>` MCP entry `al.mcp` writes to `<project>/.claude/settings.json`).
- `:ALPi` / `<leader>ak` → **Pi** ([pi.dev](https://pi.dev)). Built as `{ pi, -e <pi_provider>, --model <pi_model> }` unless `agent.pi_cmd` is set.

Configure via `require("al").setup({ agent = { claude_cmd, pi_cmd, pi_provider, pi_model, pi_env } })`.
Per-machine Pi + Ollama setup (Node 22, provider extension, HTTPS/TLS) — see `docs/pi-setup.md`.

`ALOllamaChat` is a deprecated alias → `:ALClaude`.

## Ghost completions
`lua/al/ghost.lua` — inline FIM ghost text from an Ollama server (`<leader>aI` toggle, `<M-l>` accept). Defaults to `http://localhost:11434` / `qwen2.5-coder`; override `ghost = { endpoint, model, insecure }` via `setup()`. Set `insecure = true` for an HTTPS endpoint with a self-signed/local-CA cert.
