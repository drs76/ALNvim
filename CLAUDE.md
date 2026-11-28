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
| `lua/al/compile.lua` | Async `al compile` — build view from `host.output` (one per root) + quickfix |
| `lua/al/symbols.lua` | Download `.app` symbol packages (server or global) via the AL dotnet tool |
| `lua/al/publish.lua` | Compile then publish `.app` with `al publishapp` |
| `lua/al/debug.lua` | Snapshot debugging + nvim-dap adapter config |
| `lua/al/explorer.lua` | Telescope pickers: objects (`M.objects`), procedures (`M.procedures`), grep (`M.search`) |
| `lua/al/ids.lua` | Object ID completion from `app.json` `idRanges`; `M.next_id` used by wizard; `M.free_ids`, `M.get_ranges`, `M.header_context(before)`, `M.used_ids_async(root, type, cb)` for the cmp source |
| `lua/al/cmp_ids.lua` | nvim-cmp source `al_ids` (free IDs on object headers, async rg); `M.register()` (idempotent), `M.in_sources()` |
| `lua/al/cops.lua` | Code Cop selector + browser selector — config in `alnvim.json` |
| `lua/al/mcp.lua` | Writes `<project>/.claude/settings.json` for AL MCP server (never global) |
| `lua/al/agentic_lsp.lua` | **Experimental** standard-LSP backend via `al launchlspserver` (opt-in `experimental_lsp`) |
| `lua/al/altool.lua` | **The** AL dotnet tool module: `M.binary()` (the one resolver), `M.has(subcmd)`, `M.run()` streaming runner into the host view `alnvim.tool:<root>` (`M.output_float(title, root)` → sink, log; `M.open_output` = `:ALToolOutput`; `M.close_later(sink, ms)`), `M.connection(_flags)()`/`M.cred_env()` launch.json mapping (`connection_flags(cfg, { port = "mcp" })` = proxy port), `M.mcp_call()`/`M.mcp_call_server()` one-shot MCP client, `M.mcp_tools()` cached `tools/list` |
| `lua/al/wizard.lua` | AL Object Wizard — creates new AL object files; `M.generate_permissionset()` skips type picker |
| `lua/al/refactor.lua` | Code refactoring: `M.extract_label({locked})`, `M.extract_to_procedure()`, pure string-array refactors (`to_validate`, `to_evaluate`, `make_var_global`, `add_publishers`, `promote_action`, `create_handler_function`); parsers in `M.helpers` |
| `lua/al/codeactions.lua` | Server-independent code actions: `M.register()` registry + `M.pick({only})` picker; merges LSP actions only when the client has `codeActionProvider` |
| `lua/al/tests.lua` | Test running through the tool: `M.list` (`al listtests --appfile`), `M.run` (`al runtests --raw` → quickfix; `:ALRunTests!` = test under cursor), `M.doc` (`al doc build` → `.aldoc`), `M.run_object` (web-client URL for the buffer's object). Parsers under `M._test` |
| `lua/al/profile.lua` | Profiling + snapshot through the tool's MCP proxies (tool 30+): `M.capture`/`M.collect` (`al launchprofilingmcpproxy`: `schedule_profiling` → `stop_schedule_and_get_profiles` → `.profiles/<ts>/`), `M.open` (`.alcpuprofile` hot-function viewer, `<CR>` jumps), `M.snapshot_capture`/`M.snapshot_collect` (`al launchsnapshotmcpproxy`). Pure helpers under `M._test` |
| `lua/al/fixes.lua` | Diagnostic quick fixes (Create procedure, AA0137/AA0206/AA0008/AA0021, `:ALFixCops`), Option→enum refactor, related-code navigation; pure helpers under `M._test`, registered as actions by codeactions.lua |
| `lua/al/basedef.lua` | `gd` for the agentic LSP: server definition, else hover-driven jump into variable declarations / extracted base-object sources |
| `lua/al/diff.lua` | Git Diff Explorer — Telescope picker with diff preview |
| `lua/al/layout.lua` | Report Layout Wizard — Excel generation + rendering section injection |
| `lua/al/help.lua` | Opens MS Learn AL docs / alguidelines.dev in browser |
| `lua/al/host.lua` | **Host adapter** — the only module that may `require('catnip.*')`. `setup({ ui = "auto"\|"catnip"\|"native" })`; `M.name()` (detected once, silently), `M.output({ id, title, hint, native })` → sink (`buf`, `append`, `clear`, `open`, `close`, `close_later`, `on_enter`, `map`/`unmap`), `M.locations({ id, title, items, qf_title })` (quickfix always, then Catnip navigator or `:copen`), `M.edit(file, line, col, { from = sink })` (Catnip child tab, else the native edit-window chain), `M.to_items(qf)`, `M.show_quickfix()` (current list in the navigator, list unchanged; else `:copen`), `M.buffer_diagnostics(bufnr)` (navigator; returns false when the host is not Catnip), `M.use_telescope()` (`setup({ picker = "auto"\|"telescope"\|"select" })` for the simple pickers) |
| `lua/al/status.lua` | Statusline state store (LSP, project, compile, publish), **one state per project root**; every setter takes an optional trailing `root` (without: the root updated last); `M.get()` shows the current buffer's project; `M.is_ready(root)` |
| `lua/al/startup.lua` | `M.poll(opts)` — the VimEnter readiness poller behind the once-per-root background analysis; completion claimed exactly once |
| `lua/al/platform.lua` | All platform-specific operations (paths, chmod, browser, zip) |
| `lua/al/json.lua` | `M.pretty()` / `M.write()` — indented JSON writer for user-facing config files |
| `lua/al/snippets.lua` | Loads snippets into LuaSnip; `M.create_from_selection()` wizard |
| `lua/al/actions.lua` | ALActions picker — the `ACTIONS` table (group, name, key, desc, **cmd**; `run` derived from `cmd`); `M.list()` → `{ group, name, command, key, desc }` for a host's own palette; Telescope or `vim.ui.select` per `host.use_telescope()`. `tests/actions_spec.lua` checks every entry runs an existing command |
| `lua/al/namespace.lua` | `:ALAddNamespace` wizard: `suggest_namespace` from app.json, `has_namespace`, `add_namespace_to_file/project` (refuses modified buffers); `:ALAddUsings` / `<leader>acn` / code-action "Add missing using statements" — server-independent resolver (see below); `:ALChangeNamespace` — `plan_change`/`apply_change` move namespaces to a new prefix |
| `lua/al/preview.lua` | `:ALPreviewPage` — page layout preview |
| `lua/al/update.lua` | `:ALUpdate` — `M.update(dir, { run, getenv })` fast-forwards the running checkout; refuses (no git mutation) on a dirty tree, a non-`master`/`main` branch, or `ALNVIM_DEV` set; every step's exit code checked, success only after `merge --ff-only` exits 0 |
| `lua/al/install.lua` | `:ALInstallExtension` / `:ALUpdateExtension` (VSIX from vsassets.io), `:ALInstallDotnetTool`; log in the host view `alnvim.install`, not focused, kept after close |
| `lua/al/project.lua` | `:ALNewProject` — AL Go! scaffold, built-in Hello World or extension templates |
| `lua/al/agent.lua` | `:ALClaude` / `:ALPi` — AI agent terminal at the project root, one per (command, root) in `M._terms`; float under Catnip (`host.float_for`), `botright vsplit` natively |
| `lua/al/textobj.lua` | `af`/`if` procedure and `aF`/`iF` block text objects |
| `lua/al/ghost.lua` | Inline FIM ghost completions from Ollama (`:ALGhostToggle`, `<M-l>` accept); cleared on cmp `menu_opened`; prefix capped at `M.PREFIX_LINES` (150) |
| `ftdetect/al.vim` | `filetype=al` for `*.al`, `*.dal` |
| `ftplugin/al.lua` | Buffer-local settings and keymaps |
| `syntax/al.vim` | Vim syntax highlighting from `alsyntax.tmlanguage` |
| `colors/bc_dark.lua` | BC Dark colorscheme |
| `colors/bc_yellow.lua` | Alias for bc_dark with different `colors_name` — global default in `init.lua` |
| `snippets/al.json` | ALNvim-only VSCode-format snippets (committed, read-only) — MS's own come from the extension |
| `snippets/al-user.json` | User-created snippets via `:ALCreateSnippet`; committed empty seed `{}` |

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

**`:ALUpdate` never switches branch.** It used to run `fetch` → `checkout master` → `merge --ff-only` and report only the last exit code, so it could pull a feature-branch checkout onto master, merge over uncommitted work, or claim success after a failed fetch. `lua/al/update.lua` now checks `status --porcelain` and the current branch first, stops at the first failing step with that step's output, and is a warning-only no-op whenever `ALNVIM_DEV` is set (a dev checkout is updated by hand). Git is injected (`opts.run`), so `tests/update_spec.lua` covers the whole decision table with a stub plus one real `file://` repo.

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
      assemblyProbingPaths = lsp.assembly_probing_paths(root),  -- MUST be non-null array
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

**`read_app_json`, `decode_jsonc` and `read_launch` strip a UTF-8 byte-order mark** — `json_decode` rejects it (E474), and VS Code keeps one when the file has it.

**`assemblyProbingPaths` must be a non-null JSON array** — omitting causes `ArgumentNullException("path")` crash. Sending VS Code's default `['./.netpackages']` blind hangs on CIFS/SMB, so `lsp.assembly_probing_paths` adds it only when the directory exists.

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

AL server sends `label` as `{ label = "begin" }` (object) instead of a plain string — crashes nvim-cmp. `vim.lsp.handlers["textDocument/completion"]` and the `handlers` table in `vim.lsp.start` do **not** intercept this (nvim-cmp calls `client:request` directly). Fix: **`require("al.lsp").patch_completion(client)`** wraps `client.request` once per client (`_al_completion_patched`); both the EditorServices `LspAttach` and `agentic_lsp` `on_attach` call it — never copy the wrapper inline again (it existed twice until 2026-11-22). The pure part is `lsp.normalise_completion(result)` (CompletionItem[] or `{ items = … }`).

**`filterText` quotes.** The tool's server quotes every filterText, bare names included (label `Abs`, filterText `"Abs"`); cmp scored `Ab` 13.2 against `"Abs"` vs 21.6 against `Abs`. The patch drops the quotes when filterText is exactly the label wrapped in `"`. A quoted label (`"Sales Header"`) never matches that test, so its filterText stays. The rename interception in `plugin/al.lua` is a separate wrapper with its own guard (`_al_rename_patched`). Guard: `tests/completion_patch_spec.lua`.

### Agentic LSP (`al launchlspserver`) — the user's backend since 2026-10-01

`require("al").setup({ experimental_lsp = true })` (set in the user's `native.lua`). Swaps
the VS Code extension's `EditorServices.Host` for the **standard** LSP shipped by the AL
dotnet tool: `al launchlspserver <root> --packagecachepath <root>/.alpackages`.

- Runs as a distinct client **`al_agentic_lsp`**. Every EditorServices protocol workaround
  in `plugin/al.lua` is guarded on the `al_language_server` name, so none apply.
- `lua/al/agentic_lsp.lua` — `M.start(bufnr, root)`, `M.available()`, `M.binary()`
  (delegates to `altool.binary()`), `M.pids` (VimLeavePre kills the tree). `on_attach` sets
  the project in the statusline, runs `M.warm` (ready only after the symbols load — see
  below; no progress/loaded events), configures MCP once, and
  maps `gd` to `al.basedef.definition` (scheduled so it wins over user maps).
- **Extension-independent**: needs only the tool and `.alpackages`.

**Capabilities, re-probed 2026-10-01 on tools 18.0.37 and 30.0.42 (identical):**

| works | missing |
|---|---|
| formatting (`documentFormattingProvider`; newText uses `\r\n`, which `vim.lsp.util` normalises) | `codeActionProvider` — `<leader>ac*`, organise-imports-on-save are no-ops |
| base symbols from `.alpackages`: hover shows a base table's fields, completion on `Cust.` lists them, references | `textDocument/definition` for anything in a symbol package **and for local variables/parameters** |
| definition of the project's own procedures | `al-preview://` documents |
| `textDocument/references` — accurate, cross-file, quotes inside the range | `textDocument/rename` — advertised but **never answered** (no result, no error); `renameProvider` is cleared in `on_init` |

This supersedes the earlier finding that it "does not load base symbols" — it does now.

**Warm-up on attach (`agentic_lsp.warm`, 2026-11-22).** The server answers `initialize` in
~0.5s but loads symbols on the first semantic request (6–9s on tool 30.0.42). `on_attach` used to
`set_lsp_ready()` at once, so the first `.` waited the whole load and nvim-cmp (fetching_timeout
500) showed snippets only. Now, once per client: `set_lsp_loading()`, hover on the qualifier, then
a **member** completion just after `X.`, results discarded; `set_lsp_ready()` on the completion's
answer or after `WARM_CAP_MS` (30s), exactly once. `startup.poll` waits on `is_ready()`, so the
VimEnter background analysis now waits for the real load (cap 30s < poll limit 60s). Restart goes
through `M.start`, so it warms again. Probed on ALTest (BC 21 symbols), tool 30.0.42:

- **Completion at (0,0)** loads the symbols but leaves the first `Cust.` at 1.0–1.5s. After a member
  completion on *any* variable (`SH.`), `Cust.` answers in ~40ms. `warm_position(lines)` finds the
  first member access (skips `namespace`/`using`, `1.5`, `1..9`, strings, `//` comments).
- **A document not on disk gets empty answers (~80ms) and loads nothing** — including the VimEnter
  anchor `_al_startup_.al`. So `warm_target(buf, root)` uses the attached buffer when it is on disk
  and has a member access, else the first project `.al` file (`vim.fs.find`, 200 max) with one,
  sent with a raw `didOpen`/`didClose` (no Neovim buffer; skipped when that file is already loaded,
  since Neovim opened it), else the buffer at (0,0); nothing on disk → ready at once.
- Measured after "ready": first completion in a file that the warm-up did not touch (`It.` on
  `Record Item`) **56ms**; in the warmed file 20ms. Ready arrives ~6.8–7.9s after start.
- **The server publishes no `textDocument/publishDiagnostics`** (none in 10s with a syntax error
  in an open buffer). Diagnostics come from `compile.analyze_diagnostics` only.

**It reads `.alpackages` once, at startup** (probed 2026-11-22, tool 30.0.42): a package added or
replaced later stays invisible to completion, hover and diagnostics, even after
`workspace/didChangeWatchedFiles`. EditorServices reloaded by itself, so after switching backends a
dependency's renamed table was "missing" in Neovim while VS Code offered it. `agentic_lsp.restart(root)`
stops the client (waits for `is_stopped()`, max 5s) and starts a fresh one on the same buffers. It
runs after a successful `:ALDownloadSymbols` (the watcher is `suspended[root]` during the download, so
several packages are one restart), on `:ALReindex`, and from `watch_packages` — a `uv` fs_event on the
package cache, `.app` names only, debounced `RELOAD_DEBOUNCE_MS` (3s). Explorer re-extraction deletes
the old `src/` first, so a renamed object does not survive as a stale stub.

**Restart and the watcher.** `restart(root)` stops the watcher's pending debounce (`M.debounces[root]`): it was left running, so every symbol download restarted the server twice and threw away the first warm-up. The warm-up's `didClose` is skipped when the user has opened that file meanwhile (it would close their document on the server).

**`gd` = `al.basedef.definition()`.** `open_at(file, lnum, root)` locks only files outside the project — the object search covers the project too, and a hit there used to leave the user's own file unmodifiable. The server's answer when it has one; otherwise hover
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
- **Under Catnip a symbol stub opens in a float** (`open_at`: `host.float_for`, `q` closes, window flag `w:al_stub_float`), not in the edit window: the stub is a cache copy, and it replaced the user's file with a buffer that was not theirs. A further `gd` inside the float reuses it. Project files and the native host are unchanged.
- **NuGet symbol packages ship without `.al` source** (extraction stamps `0`); for those it
  notifies and hover is the answer. Server-downloaded packages usually include source.
- First search per package extracts its sources synchronously (~8s for Base Application);
  `explorer.pending_extracts(root)` gates a "first time only" notice before it.

**Inlay hints.** `agentic_lsp` `on_attach` calls `vim.lsp.inlay_hint.enable(true, { bufnr })`
when `server_capabilities.inlayHintProvider` is set and `setup({ inlay_hints = true })` (default);
`:ALInlayHints` toggles per buffer and `:ALInfo` prints the capability. **Probed 2026-11-15 on
tool 30.0.42: `inlayHintProvider = false`** (`codeActionProvider = false`, `hoverProvider = true`),
so the enable is a no-op until a tool version advertises it — the capability guard is what keeps
`:ALInlayHints` from erroring on `textDocument/inlayHint` unsupported.

**Features must not key on `al_language_server`.** `lsp.client(bufnr)` returns whichever AL
client is attached (`lsp.CLIENT_NAMES`). Format-on-save looked up the EditorServices name
only, so switching backends silently stopped formatting. Organise-imports and
`compile.clear_lsp_diagnostics` go through the same list; `cops.apply` (an EditorServices
`al/setActiveWorkspace` re-send) tells an agentic user the cops apply at compile instead.

**Two switches for hosts with their own rules** (both default `true`, unchanged for everyone
else): `setup({ format_on_save = false })` stops the ftplugin's `BufWritePre` format (Catnip
formats by hand, `:Format`); `setup({ statusline = false })` sets no window-local
`statusline`. With `laststatus=3` the current window's local value is the one drawn, so the
ALNvim line replaced the host's global one in every AL buffer. A host embeds
`%{v:lua.require('al.status').get()}` in its own line instead.

**Status is per root.** `status.lua` held one table for the session, so with two AL projects in
two tabs both showed whichever attached last. State is keyed by root; callers that know their
root pass it (`compile`, `publish`, `tests`, `agentic_lsp`, the EditorServices handlers via
`client.root_dir`, `cops.apply`). `get()` resolves the current buffer's root with
`find_root_upward`, cached per buffer and name, and keeps the 250 ms string cache per root. A
call without a root targets the root updated last — the old behaviour for one project.
`ftplugin` checks `is_ready(<buffer's root>)` before organise-imports and the debounced analyze.

**On-prem UserPassword debugging does not depend on either language server** — the
credentials go into the debug adapter's environment (see "BC dev API / DAP").

**The FileType root is bounded** (`lsp.find_root_upward`, not `vim.fs.root`). For this
backend the root is the workspace the server indexes.

## Repeating timers with `vim.schedule_wrap` (`lua/al/startup.lua`)

**A scheduled callback may run several times after the condition it polls for is already
met.** The timer ticks in the libuv loop; `vim.schedule_wrap` only queues the callback,
and the queue drains when the main loop is free. Any synchronous work at startup (an rg
over the symbol cache, a package extraction, the user's own config) lets the 1s poll
queue one callback per tick, and they then run back to back: each saw `is_ready()`, each
called `timer:close()` — `plugin/al.lua: handle 0x… is already closing` — and each
started another `analyze_diagnostics` per root. `startup.poll` claims completion once
(`done` flag, one `finish()` guarded by `timer:is_closing()`, tick returns early when
done) and runs `on_ready` only after the claim succeeded; the timeout path never runs it.
Apply the same shape to any repeating timer whose callback closes its own handle —
`timer:is_closing()` alone is not enough, because the second callback would still redo
the work. Headless repro: `vim.wait(…, fast_only = true)` ticks timers without draining
the schedule queue; the regression test in `tests/startup_spec.lua` uses exactly that.

## .NET assembly probing (`lsp.assembly_probing_paths(root)`)

The one source for compile (`/assemblyprobingpaths:`, repeated per directory), the agentic LSP and MCP server (`--assemblyprobingpath`), and EditorServices (`assemblyProbingPaths`). Without it, any project with a `dotnet` block fails with AL0451 "could not be found in the assembly probing paths ''" then AL0185, while VS Code compiles it.

Precedence, first set wins and `[]` counts as set (VS Code replaces arrays between scopes): `.vscode/settings.json` → `.code-workspace` in the project or its parent → `setup({ assembly_probing_paths })` → VS Code user settings. Unset → `.netpackages` if it exists. Relative paths mean the project root; `${workspaceFolder}`, `${workspaceRoot}`, `${userHome}`, `${env:X}` and `~` expand. Files are read with `json.decode_jsonc`, because VS Code settings may hold comments and trailing commas. `:ALInfo` prints the result.

## Compiling

`:ALCompile` runs `al compile /project:<root> /packagecachepath:<root>/.alpackages` async. Output streams live into the build view the **host adapter** (`lua/al/host.lua`) picks: under Catnip an owned float (`catnip.ui` view `alnvim.build:<root>`), otherwise the full-width bottom split (~30% height) it always was. `<CR>` on a diagnostic opens file at line/col — a managed child tab under Catnip, the edit window the build started from natively. `q`/`<Esc>` closes the view, never the job. Quickfix also populated (`<leader>aq`). After a failed build under Catnip the summary line ends `d: browse` and `d` opens the linked navigator on that build's diagnostics. `:ALBuildOutput` reopens the current project's view; `:ALCatnipDiagnostics` browses its last finished build (quickfix natively). (`:ALCompileLegacy` / `:ALCompileCatnip` were removed 2026-11-22: the caller no longer picks the view.)

**One build view per project root; the caller never picks the sink.** `compile.compile(root, args, on_success)` has no `opts` — `publish`, `tests` and `debug` compile through the same host sink, so none of them opens a bottom split under Catnip (D4). State lives in `M._builds[root] = { sink, qf, job, gen }`: a second compile of the same root `jobstop`s the first and bumps `gen`, so the stopped job's late output and `on_exit` are dropped (same guard as `analyze_diagnostics`). The old single id `alnvim.build.output` interleaved two projects in one buffer and wiped a running build (D2).

**Never switch the user's tab (D1).** Catnip's `View:open` focuses a view already open in another tabpage, which switches tab. `CatnipSink:open` closes such a view first (close does not move focus when the view is not focused). Request R4 asks Catnip to fix the root cause; the guard stays either way.

**Sink rules (2026-11-27).** `close_later` closes only if the sink was not cleared or opened again since (`_use` counter) — a second tool run inside the 2.5 s delay had its view closed by the first run's timer. Under Catnip the first write after `clear()` replaces the buffer (Catnip's `View:append` adds below the one empty line an emptied buffer keeps, so output started on line 2), and every append moves the view's windows to the last line (Catnip does not follow the tail).

**`host.edit` falls back when the view has no parent edit window.** Catnip's `View:edit_file` needs `previous_win` to be a normal window; a view opened while another float had focus has none, and `<CR>` on a diagnostic only warned. Then the view is closed and the file opens in an edit window of the current tab. `:ALInfo` fills the view `alnvim.info` under Catnip (it was a long `print`); natively it still prints.

**Detection is silent (D3).** `pcall(require, "catnip.ui")` once, cached; `setup()` resets it. `ui = "catnip"` with Catnip missing warns once, at `setup()`, never per command. Natively, split build panels open one per tab: a second root's panel replaces the first in that tab, as the single panel always did.

**Pickers (W6).** `host.use_telescope()` decides for the simple pickers — ALActions, the
wizard's field multi-select, `:ALSelectCops`, `:ALRunTests` methods, the layout types: Telescope
under `picker = "auto"` when it loads or `"telescope"`, their existing `vim.ui.select` fallback
under `"select"` (Catnip's `vim.ui.select` is dressing.nvim, so that is one look). Explorer,
procedures, grep and diff keep Telescope: they need a preview and extra keys, and a Snacks
backend is a separate task. `actions.list()` exports the table for a host's own palette
(Catnip's hard-coded one listed `ALGoto` and `ALInlineHints`, which do not exist — request R2).

**Every other output view is on the host too (W3).** `altool.run` streams into
`alnvim.tool:<root>` (publish, symbols over both routes, tests, doc): opened without focus,
stays open on failure, `close_later(2500)` on success, and the buffer outlives the window, so
`:ALToolOutput` shows the last run again. The installer logs into `alnvim.install` without
entering it (`:q` mid-download used to wipe the log). Natively both are the centred float they
were. Left as they are: the DAP adapter output (`debug.lua`, already the right lifecycle), the
az-login terminal, and the profile viewer / page preview (interactive floats; their "open
source" still uses the current window — `host.edit` has no child tab without a Catnip view).

Code analyzers from `alnvim.json` auto-included as `/analyzer:` flags. `ruleset_path` in `setup()` passes `/ruleset:<file>`. **Do not add `ruleSetPath` to `app.json`** — custom properties break AL validation.

Success: exit code 0 + empty quickfix. Error format: `/path/file.al(line,col): error|warning ALxxxx: message`.

`M.compile(dir, extra_args, on_success)` — `on_success()` called in `vim.schedule` only on clean build. `publish.lua` chains upload via this.

**Job output must be line-buffered.** `jobstart` without `stdout_buffered` delivers chunks where `data[1]` continues the previous chunk's partial line and `data[#data]` is itself partial. Appending chunks verbatim splits diagnostics across two "lines" so they never match the quickfix pattern. `line_stream(on_lines)` returns `(feed, flush)`; give stdout and stderr **separate** carries and call both `flush()` in `on_exit`. Same pattern as `altool.mcp_call`.

**Analysis is per project root (2026-11-27).** `_analyze[root] = { job, gen, timer }`. It was one job, one generation and one debounce timer for the session, and `push_diagnostics` reset the whole namespace: with two projects open a save in one cancelled the other's run and wiped its diagnostics, and the startup pass over a multi-root workspace analysed only the last root. `push_diagnostics(qf, root)` resets only buffers under `root`. Three more rules: the pass writes its package to `compile.analyze_out(root)` (`stdpath("cache")/alnvim/analyze/<hash>.app`) through `/out:` — without it every save rewrote the project's `.app`; `compile()` calls `cancel_analyze(root)` first, because `:w` then `<leader>ab` ran two compilers on one project; `analyze_diagnostics` returns at once while a build of that root runs. Measured on a 59-file project with three cops: one pass is 9.3 s wall, 15.6 CPU-seconds. Guard: `tests/review_spec.lua`.

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

**`<CR>` target window fallback chain** (native, `host.edit` → `native_target`): (1) `origin_win` captured when the sink opened, (2) any edit window in the current tab, (3) any non-floating non-sink window (e.g. alpha dashboard — reused rather than split), (4) new `aboveleft split` above the sink. `origin_win` is updated so later `<CR>` presses reuse the same window.

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
| `<leader>aq` | Quickfix list — `host.show_quickfix()`: Catnip navigator, else `:copen` |
| `<leader>aC/aB` | SelectCops / SelectBrowser (SelectCops moved from `<leader>ac` 2026-11-15 — it shadowed the `<leader>ac*` prefix) |
| `<leader>am/aM` | McpSetup / McpStatus |
| `<leader>ai/ak/aI` | Claude Code / Pi agent terminal split / Ghost completions toggle (`<M-l>` accepts) |
| `<leader>ad` | Diagnostics for the current buffer — `host.buffer_diagnostics()` under Catnip, else Telescope or loclist |
| `<leader>av` | PreviewPage |
| `<leader>acu` | AddUsings — server-only organizeImports |
| `<leader>rn` | RenameObject (same as `grn`) |
| `af/if`, `aF/iF` | Text objects: procedure, begin/end block |
| `<leader>ah/aH/aG` | Help / HelpTopics / Guidelines |
| `<leader>an/aw/aW` | NewObject / ReportLayout / OpenLayout |
| `<leader>aR` | GeneratePermissionSet — scan all project objects and create a `.PermissionSet.al` file |
| `<leader>aN` | AddNamespace — add namespace to all source files |
| `<leader>aA/aD/ae/af/ag` | Analyze (silent alc pass) / Diff / Explorer / ExplorerProcs / Search |
| `<leader>aca/acf/acr` | Code actions via `al.codeactions.pick` (all / quickfix for cursor-line diagnostics / refactor) — `aca`/`acr` work in visual mode; Lua actions always, server actions only with `codeActionProvider` |
| `<leader>acF` | fixAll — server-only; notifies "not supported by this language server" on the agentic LSP |
| `<leader>acn` / `<leader>acu` | Add missing using statements — ALNvim's own resolver (server organizeImports on EditorServices) |
| `<leader>acx/acE` | FixCops (apply every AA0137/AA0206/AA0008/AA0021 fix project-wide) / RefactorToEnum (Option field → enum) |
| `<leader>acv` | SortVariables — every var block in the buffer in AA0021 order |
| `<leader>aF` | FindRelated — publisher for `[EventSubscriber]`, handlers for `[HandlerFunctions]`, table trigger for `Rec.Insert()` |
| `<leader>acl` | ExtractLabel (`:ALExtractLockedLabel` for `Locked = true`) |
| `<leader>at/aT` | RunTests (pick codeunit → methods) / RunTests! (the `[Test]` procedure under the cursor) |
| `<leader>ar` | RunObject — open the buffer's page/report/table/query in the web client |
| `<leader>ax` | Doc — `al doc build` reference docs into `<root>/.aldoc` |
| `<leader>ace` | ExtractProcedure — extract visual selection into a new `local procedure` (auto-detects params from var block) |
| `<leader>acs` | CreateSnippet — wizard to save visual selection as a user snippet to `snippets/al-user.json` |
| `grn` | RenameObject — rename quoted AL identifier project-wide (falls back to LSP rename for unquoted symbols) |
| `<F5>`/`<leader>adl/ads/adf/add` | Launch / SnapshotStart / SnapshotFinish / DebugSetup |
| `<leader>adp/adP/ado` | ProfileCapture (arm a schedule on a BC session id) / ProfileCollect (save `.alcpuprofile`s, open viewer) / ProfileOpen (newest profile). Under `ad`, not `ap`: `<leader>ap*` would make `<leader>ap` Publish wait on `timeoutlen` |
| `<leader>adS/adF` | SnapshotCapture / SnapshotCollect — proxy route (`al launchsnapshotmcpproxy`) |
| `<leader>adX` | DapClose — terminate session, close all debug windows, restore pre-debug buffer |
| `<F9>`/`<leader>adb/adB/adc/adq/adi`, `<F10>`/`<F11>`/`<F12>` | nvim-dap: breakpoint / conditional / continue / terminate / inspect, step over / into / over (only when nvim-dap is installed) |
| `gd` / `<C-o>` | AL go-to-definition / jumplist back |
| `<C-Space>`/`<Nul>` (insert) | Object ID completion (`<C-x><C-u>`) — not mapped when the buffer's cmp sources include `al_ids` (then IDs are in the normal menu) |

Explorer picker: `<C-s>` cycle sort (type/id/publisher/name), `<C-f>` live grep, `<CR>` open.

**Return-on-close.** Telescope closes on select and cannot host a file behind it, so the explorer instead *comes back*: `<CR>` arms a one-shot `BufDelete`/`BufWipeout` watcher on the opened buffer, and closing that buffer reopens the picker. The built entry list is cached in `_last`, so `M.reopen()` rebuilds from it — measured 0.2ms and **no second rg process**. Only the most recently opened file is watched (`arm_return` disarms first), and `v:exiting` is checked so `:qa` does not try to build a Telescope window on the way out. Disable with `explorer_return = false`; `:ALExplorerReopen` works either way.

## User commands

Every `nvim_create_user_command` in `plugin/al.lua` (plus `:ALClaude`/`:ALPi`/`:ALOllamaChat` from `agent.lua`); `tests/actions_spec.lua` checks the ALActions table against this set. `docs/cheatsheet.md` carries the descriptions. `docs/handbook.md` is the engineering handbook (house style, STE wording, lint under 2.5 with `ste-lint.py`): update its Status table and Sharp edges when a fix here earns one.

`:ALActions`, `:ALAddNamespace`, `:ALAddPublishers`, `:ALAddUsings`, `:ALAnalyze`, `:ALBuildOutput`, `:ALCatnipDiagnostics`, `:ALChangeNamespace`, `:ALClaude`, `:ALClearCredentials`, `:ALCodeAction`, `:ALCompile`, `:ALCreateHandler`, `:ALCreateSnippet`, `:ALDapClose`, `:ALDapOutput`, `:ALDebugSetup`, `:ALDiff`, `:ALDoc`, `:ALDownloadSymbols`, `:ALDownloadSymbolsGlobal`, `:ALExplorer`, `:ALExplorerProcs`, `:ALExplorerReopen`, `:ALExtractLabel`, `:ALExtractLockedLabel`, `:ALExtractProcedure`, `:ALFindRelated`, `:ALFixCops`, `:ALGeneratePermissionSet`, `:ALGhostToggle`, `:ALGuidelines`, `:ALHelp`, `:ALHelpTopics`, `:ALInfo`, `:ALInlayHints`, `:ALInstallDotnetTool`, `:ALInstallExtension`, `:ALLaunch`, `:ALListTests`, `:ALMakeVarGlobal`, `:ALMcpRemove`, `:ALMcpSetup`, `:ALMcpStatus`, `:ALNewObject`, `:ALNewProject`, `:ALNextId`, `:ALOllamaChat`, `:ALOpenAppJson`, `:ALOpenLaunchJson`, `:ALOpenLayout`, `:ALPi`, `:ALPreviewPage`, `:ALProfileCapture`, `:ALProfileCollect`, `:ALProfileOpen`, `:ALPromoteAction`, `:ALPublish`, `:ALPublishOnly`, `:ALRefactorEvaluate`, `:ALRefactorToEnum`, `:ALRefactorValidate`, `:ALReindex`, `:ALReloadSnippets`, `:ALRenameObject`, `:ALReportLayout`, `:ALRunObject`, `:ALRunTests`, `:ALSearch`, `:ALSelectBrowser`, `:ALSelectCops`, `:ALSetNuGetFeeds`, `:ALSnapshotCapture`, `:ALSnapshotCollect`, `:ALSnapshotFinish`, `:ALSnapshotStart`, `:ALSortVariables`, `:ALToolOutput`, `:ALUpdate`, `:ALUpdateExtension`

## Project root detection (`lsp.get_root()`)

1. Search upward from current buffer for `app.json` — **bounded** (`find_root_upward`)
2. Scan downward from `vim.fn.getcwd()` for all `app.json` files
3. One found → use it; multiple → `vim.fn.inputlist` prompt, **once per working directory**
   (`M._picked[getcwd()]`; `getcwd()` is tab-aware, so once per Catnip workspace), and
   **never** while `vim.v.vim_did_enter == 0` or with no UI attached — then it returns nil.
   `get_root` stays synchronous: it has dozens of callers. The prompt used to come back on
   every command, and a headless start blocked on it.

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

**Extraction runs in jobs: `explorer.with_search_dirs(root, cb)`** (2026-11-27). It unzips every package whose sources are missing or older than its `.app`, all at once, then calls `cb(search_dirs, sym_map, sym_count)`; concurrent calls for one root share one extraction. `build_search_dirs` still extracts synchronously and froze the editor about 8 s for Base Application on the first `gd`, explorer or search after a symbol download — `M.objects`, `M.search`, `basedef.find_object` and `fixes.find_publisher` now go through `with_search_dirs`. The wizard pickers and the profile viewer still call `build_search_dirs` (they run after one of the others in practice). `platform.extract_zip_cmd` is the argv both forms use.

**All symbol-package searches must be async.** These cover the project *plus* every extracted package (Base Application alone is ~10k `.al` stubs), so `vim.fn.systemlist` freezes the editor for the whole search. Use `explorer.rg_async(cmd, cb)` and build the picker in the callback. The one place that cannot be async is `ids.get_used_ids` (reached from `completefunc`, which is synchronous) — it caches per project+type and `ids.invalidate()` is called from the ftplugin `BufWritePost`.

`M.objects`: `rg` across project root + `~/.cache/nvim/alnvim/symbols/` extracted packages. The package list comes from `package_cache(root)` (`packagecachepath`, default `.alpackages`) — it was hard-coded. Entry: `[src]`/`[sym]` tag, publisher, type, ID, name, filename. `<C-s>` cycles sort.

**Symbol extraction:** `.app` files are ZIPs with `src/*.al` stubs, extracted to cache dir keyed on sanitised filename. `.ok` stamp skips re-extraction. `unzip` exits code 1 on no-match glob (not failure) — check `vim.fn.isdirectory(dir .. "/src")` not `vim.v.shell_error`.

Publisher from filename format `Publisher_Name_Major.Minor.Build.Rev.app`.

## Object ID completion (`lua/al/ids.lua`)

`<C-Space>`/`<Nul>` in insert mode on object-type keyword line → `<C-x><C-u>`. Global `_G.ALCompleteObjectId` bridges to `require("al.ids").complete` (avoids `v:lua` compatibility issues). Shows up to 5 free IDs per range with usage info. `:ALNextId` notifies next 3 free IDs in normal mode.

**With nvim-cmp: the `al_ids` source** (`lua/al/cmp_ids.lua`). Offered only when the text before
the cursor is `<object type> <digits?>`; the root comes from `find_root_upward` (a completion
source must never prompt); the used-ID scan goes through `explorer.rg_async`
(`ids.used_ids_async`) and fills the same cache. `register()` runs from `setup()` and the
ftplugin (cmp may load later). **The ftplugin drops its `<C-Space>`/`<Nul>` map only when
`cmp_ids.in_sources()`** — the buffer's cmp config lists `al_ids`. Dropping it whenever cmp is
loaded would remove ID completion for a host whose own `cmp.setup.filetype("al")` runs after
ALNvim's: Catnip calls `require("al").setup` before `config.completion`, so its list
(`nvim_lsp`, `luasnip`) wins (checked with the real config 2026-11-22). Request: add
`{ name = "al_ids" }` there. Whether cmp's buffer remap kills ALNvim's `<C-Space>` map (handover
C3) was not checked in a terminal; the map is only skipped when it cannot be needed.

**cmp sources are set once, in `setup()`** (`completion = { configure_cmp = true }`):
`cmp.setup.filetype("al", { nvim_lsp, al_ids, luasnip })`. The ftplugin used to call
`cmp.setup.buffer` on every `FileType al` (and the ftplugin re-runs on `:e`), overriding the
user's own AL config each time. `configure_cmp = false` leaves cmp alone.

**Capabilities** (`lsp.capabilities()`): `setup({ capabilities })`, else
`cmp_nvim_lsp.default_capabilities()`, else `blink.cmp`'s `get_lsp_capabilities()`, else
Neovim's; passed by both `vim.lsp.start` calls. Tool 30.0.42 sends no commit characters,
preselect or resolve, so this is correctness for later tool versions, not speed.

**The used-ID cache must be dropped whenever ALNvim itself writes an `.al` file.** `ids.invalidate()` runs from the ftplugin `BufWritePost`, but `wizard.write_and_open` uses `vim.fn.writefile` (fires no autocommands) and `:edit` (a read) — so it calls `invalidate()` directly. Without that, `next_id` serves a stale set and two objects of the same type created in one session get the **same ID**.

Types with IDs: `table`, `tableextension`, `page`, `pageextension`, `pagecustomization`, `codeunit`, `report`, `reportextension`, `query`, `xmlport`, `enum`, `enumextension`, `permissionset`, `permissionsetextension`, `profile`, `controladdin`.

## Code Cops (`lua/al/cops.lua`)

Four cops: `${CodeCop}`, `${PerTenantExtensionCop}`, `${UICop}`, `${AppSourceCop}`. Default: first three. Config + browser saved to `<root>/.vscode/alnvim.json`. After confirm, `cops.apply()` re-sends `al/setActiveWorkspace` — live effect without LSP restart. Telescope: `<Tab>` toggle, `<CR>` apply. Fallback: iterative `vim.ui.select` with `[x]`/`[ ]`.

Browser values stored in `alnvim.json` as `"browser"`. macOS: no-path value → `open -a <browser>`. `platform.open_url(url, browser)` — empty browser → OS default. `_current_root` in `debug.lua` set at start of `M.launch`/`M.setup_dap` for global DAP listeners.

## AL MCP Server (`lua/al/mcp.lua`)

Writes **`<project>/.claude/settings.json`** to spawn `al launchmcpserver` via stdio. Entry key: `"al:" .. basename(root)`. Binary: `altool.binary()`. Read/write pattern: `readfile` → `json_decode` → mutate → `al.json.write` (preserves all other keys).

**Per-project, never global.** This wrote `~/.claude/settings.json` until 2026-09-15. With `auto_mcp` on by default, every AL project ever opened left an entry there — eleven had accumulated, including one for a deleted `/tmp` scratch dir. The entry's **last positional argument is the server's workspace root**, so a stale or mis-resolved one is not inert: it is an AL language server indexing that tree in *every* Claude Code session. One (`al:rojaws`) pointed at a 3.6TB NFS share, because a stray `app.json` above the projects made `get_root()` resolve the mount point. `lsp.find_root_upward` now bounds that resolution; writing per-project bounds the damage if it ever resolves wrongly again. `:ALMcpStatus` reports leftover global `al:*` entries but does not remove them — that file holds the user's own config.

**Never overwrite a settings file you could not parse.** `mcp.read_settings` returns `(data, err)`: `{}` for absent/empty, `nil` plus a reason when the file exists but is invalid JSON. Collapsing those two into `{}` meant one trailing comma in a hand-edited `.claude/settings.json` was read as empty and then rewritten with only `mcpServers` — destroying the user's permissions and hooks. `auto_mcp` reaches this on every `LspAttach`, so opening one `.al` file was enough.

**Never write user-facing JSON with bare `json_encode` + `writefile`** — that emits one line and flattens the user's formatting. `<project>/.claude/settings.json` and `.vscode/alnvim.json` go through `require("al.json").write(path, data)`, which indents the encoder's output. `mcp.configure()` also `vim.deep_equal`-checks the existing entry and skips the write when unchanged, because `auto_mcp` calls it on every `LspAttach`. `auto_mcp = true` (default) calls `mcp.configure(root)` once per client on `LspAttach`. Restart Claude Code / run `/mcp` to pick up changes. 13 MCP tools on tool 30.0.42 (`tools/list`, verified 2026-11-15): `al_addproject`, `al_build`, `al_compile`, `al_downloadsymbols`, `al_getdiagnostics`, `al_getnextobjectid`, `al_getpackagedependencies`, `al_inspectpage`, `al_publish`, `al_searchtranslations`, `al_symbolrelations`, `al_symbolsearch`, `al_writetranslation`.

**Proxy entries (opt-in, tool 30+).** `setup({ mcp = { profiling = true, snapshot = true } })`
(both default off — each is one more process per Claude Code session) makes `configure(root)`
also write `al-profiling:<name>` (`al launchprofilingmcpproxy … --profilefolder <root>/.profiles`)
and `al-snapshot:<name>` (`al launchsnapshotmcpproxy …`) beside `al:<name>`, from the **first** AL
launch configuration (`conn.read_launch` — `LspAttach` cannot prompt). Their connection flags
come from `altool.connection_flags(cfg, { port = "mcp" })`: **the proxies take the BC API/OData
port (`mcpServicePort` in launch.json, default 7047), not the dev port 7049** every other tool
command uses — `--help` says so, and a proxy given 7049 starts cleanly and then fails every
call. Cloud has no port. UserPassword credentials are referenced as `${AL_BC_USERNAME}` /
`${AL_BC_PASSWORD}` in the entry's `env` (never copied as values); whether Claude Code expands
`${VAR}` in `settings.json` `mcpServers.env` is **unverified**. An opted-out proxy's entry is
left alone by `configure`; `:ALMcpRemove` drops all three keys, `:ALMcpStatus` lists them (`al:`
sorted first). Same `deep_equal` skip and unparsable-file refusal.

**Deliberately not implemented (Phase 5, 2026-11-15):** `al_getnextobjectid` via `mcp_call`
(spawns a server per call, and `completefunc` is synchronous — `ids.lua` reads app.json instead);
JSON schemas for jsonls (editor-config concern, not the plugin's); `useMcpServerForDebugging` /
`mcpServicePort` wiring beyond the proxy port; `semanticFolding` / `extendGoToSymbol`
(EditorServices-only settings, meaningless on the agentic LSP); permission sets as XML (legacy
format, the wizard emits `.al`); `al.incognito` (telemetry opt-out for the extension, not used
by the tool).

## Profiling and snapshot proxies (`lua/al/profile.lua`)

Both proxies are stdio MCP servers and both are **two-phase**: arming captures nothing, the user
reproduces the scenario in the BC client, stopping returns the capture. So each is a command
pair, with the armed state in `M._profile` / `M._snapshot`. Every call is a fresh
`altool.mcp_call_server` process (one-shot client), which is fine because the state that matters
(`scheduleId`, `debuggingContext`) lives on the NST. There is no list-sessions tool, so the BC
session id is prompted for (web client `?` → Help → Session ID).

**Tool names, from `tools/list` on 30.0.42** (fixtures `phase2b-*-tools-list.json` in the side
session notes; the list is answered with the server down, so `altool.mcp_tools` can probe before
a call and name the real tools when one is missing):

| proxy | arm | collect | other |
|---|---|---|---|
| `launchprofilingmcpproxy` | `schedule_profiling { targetSessionId, durationSeconds=300, samplingIntervalMs, profileCreationThresholdMs, description }` → `scheduleId`, `nextStep` | `stop_schedule_and_get_profiles { targetSessionId, scheduleId }` → base64 zip of `<activityId>.alcpuprofile` (inline when small, else a `resourceUri`) + `profilesOverview` | `get_profile_for_activity`, `analyze_profiles_in_folder` (local) |
| `launchsnapshotmcpproxy` | `initialize_snapshot_debugging { clientType=WebClient, sessionId?, snappoints?, snapshotVerbosity }` → `debuggingContext`, `hostId` | `stop_snapshot_debugging { debuggingContext, hostId? }` → archive + Markdown/JSON projection of the captures | `get_snapshot_status`, `run_tests` |

**Stop-response shapes are not verified live** (bc2 down throughout). `extract_archives` scans
the result for a `resource` block blob or any string in the text block's JSON whose base64
decodes to `PK…`; `find_field` searches for the id keys case-insensitively at any depth. An
archive referenced only by `resourceUri` is reported, not fetched (that needs `resources/read`
in the same proxy process). `hostId` is passed back on collect because a fresh proxy process has
forgotten the owning node.

`parse_cpuprofile`: `timeDeltas[i]` is attributed to `samples[i]`; total = self + descendants
via `children[]` (or `parent` links); nodes sharing a call frame are merged. Viewer `<CR>` →
`frame_location(url, functionName)`: a readable path or basename under
`explorer.build_search_dirs(root)`, else `kind + id/name` parsed from the url (kinds tried
longest-first — Lua patterns have no alternation, and `tableextension` must not read as `table`)
rg'd over the same dirs, then `basedef.member_line` for the procedure. **The url shape of an AL
frame is unknown until a live capture**; the resolver tries all three.

The curl `:ALSnapshotStart/Finish` in `debug.lua` stay. The proxy route (`:ALSnapshotCapture/
Collect`) is the one that goes through the tool and is to be preferred once verified live; the
curl pair goes then.

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

**Templates.** The first prompt after the name is the template: "Hello World
(built-in)" (the path above — always offered, works with no extension) then
`list_templates()` = `<ext.path>/templates/*/altemplate.json` (Agent, Copilot,
Copilot with tests, Hello World on 18.x/30.x). `scaffold_template` copies the
tree byte-exact through `io` (CRLF survives), skipping `altemplate.json`;
`glob("**/*")` never enters dot-dirs, so `.resources` (agent instructions, test
datasets) has its own pass. `substitute(text, vars)` handles `{{id+N}}`,
`{{guidK}}`, `{{projectname}}`, `{{publishername}}`, `{{rootnamespace}}`
(`root_namespace`, the starter object's derivation); unknown placeholders stay.
**`vars.guids` is one memo table per project** — `{{guid0}}` is the app id in
app.json and must be the same value wherever else a file uses it.
`generateAppJson = false` → the template's own app.json, substituted, and the
runtime prompt is skipped (the template fixes `application`); `true` →
`build_app_json` and any template app.json is ignored. launch.json and
`.alpackages/` as for the built-in. Verified 2026-11-15: Agent template from
extension 30.0.2863738 + global symbols (27.5) → `al compile` clean.

**`gen_uuid` seeds once per session and draws from `vim.uv.random`.** It used to
reseed from `os.time() + os.clock()` on every call, which makes the value a
function of when the call happened rather than of any entropy. This is the
app.json `id`; BC rejects two extensions claiming the same one.

## AL Object Wizard (`lua/al/wizard.lua`)

18 types: Table (DataClassification), TableExtension (extends picker), Page (PageType + SourceTable), PageExtension (extends), Codeunit, Report (SourceTable), Query (SourceTable), XmlPort, Enum (Extensible), EnumExtension (extends), Interface (no ID), PermissionSet (auto-generates permissions), ReportExtension (report picker), PermissionSetExtension (permission set picker), Profile (no ID; Role Center picker — pages with `PageType = RoleCenter`), PageCustomization (no ID; page picker), ControlAddIn (no ID), Entitlement (no ID; permission set picker for `ObjectEntitlements`). Generated objects of every new type compile (checked 2026-11-15, tool 30.0.42).

**ID-less declarations** (`NO_ID_TYPES`: interface, profile, profileextension, pagecustomization, controladdin, entitlement) are recognised by `detect_obj_type`/`find_obj_decl` quoted or bare; the name must start with a quote or word character, so a `Profile = …` property or `Entitlement: Record …` variable is not a declaration. `customizes …` is stripped from the name like `extends …`.

**`organise_file` scope.** Only files at the project root or under `organise_dirs` (`setup({ organise_dirs = { "src" } })`, root-relative) are moved or re-suffixed. It used to act on every AL file under the root, so the first `:w` in an Agent-template project moved `app/Setup/MyAgentSetup.Table.al` to `src/table/` — scrambling the feature layout MS's templates use. Outside the scope both the move *and* the suffix rewrite are skipped.

`M.generate_permissionset(root)` — skips the type picker, goes directly to ID → name → scan. Mirrors VS Code "AL: Generate Permission Set". Calls `run_wizard` with the permissionset entry directly.

File naming (CRS): `src/<obj_type>/<SanitisedName>.<FileType>.al` — no object ID. **Spaces are removed, not replaced** (`"Private Gallery Setup"` → `PrivateGallerySetup`, the CRS default). `sanitise_name` wrote `_` until 2026-11-15, so a project whose files were already named the CRS way got a duplicate `Private_Gallery_Setup.Page.al` beside each original on the first `:w`. `build_path()` and `organise_file()` derive this independently and must stay in step; adding an ID to one would make `organise_file` rename every existing file on its next save. Interface: `src/interface/<Name>.Interface.al`. Auto-moves on `:w` (`wizard.M.organise_file` via `BufWritePost` in `ftplugin/al.lua`) — uses `vim.fn.rename` + `nvim_buf_set_name`, no reload needed.

**A move never overwrites, and always ends in `write!`** (2026-11-27). `vim.fn.rename` replaces an existing target silently; two objects of one type whose names differ only in punctuation (`"Item No."` / `"Item No"`) sanitise to the same file name, so saving one deleted the other. An existing target is now a warning and no move. After a move the buffer is written with `silent write!`: `nvim_buf_set_name` marks it "not edited", and the user's next plain `:w` stopped with E13 "File exists". The old name's leftover unlisted buffer is deleted.

PermissionSet scan uses `platform.glob_al_files(root)` + `io.open` (not `find` — not available on Windows). Tables generate two entries (`tabledata RIMD` + `table X`); others get `X`.

## AL Refactoring (`lua/al/refactor.lua`)

**Rename on the agentic LSP is built from references** (`rename_via_references`, 2026-11-21). `grn` / `<leader>rn` / `:ALRenameObject` with an `al_agentic_lsp` client: `basedef.target_at_cursor` for the name (quoted or bare), `textDocument/references`, then `plan_rename` → one edit per location under the root → `vim.lsp.util.apply_workspace_edit`. Before this, bare names fell to `vim.lsp.buf.rename()`, which waited forever on the server; quoted names took the rg text path, which renames *every* `"Entry No."` in the project. The server ignores `includeDeclaration`: the declaration is always in the result when it is in the project and absent when it lives in a symbol package, so **a plan with no declaration among its locations is refused** (`is_declaration`: object headers, member keywords in `MEMBER_KEYWORDS` such as `field(`/`action(`, `procedure`/`trigger`, `Name:` but not `Name :=`) — otherwise renaming `Customer` would rewrite the usages of a base-app table and break the build. `rename_text` keeps a quoted original quoted and quotes a bare one only when the new name needs it. **Fallback for files the server cannot parse:** it then never answers references at all (a page variable named `Actions` — reserved there — stops parsing at its declaration, and that is exactly when people rename). An error diagnostic on the symbol's line → `local_text_rename` first, instantly; otherwise references with an 8s timeout (`REFS_TIMEOUT_MS`, request cancelled) or an empty result → the same fallback. It renames a **local variable or parameter only**, declared in the enclosing procedure's header or var block, whole words, case-insensitive, inside that procedure, skipping string literals, `//` comments and quoted identifiers (`Widget.Add('Actions', Actions)` keeps its JSON key). Anything else is refused with the reason. Verified on bc-dashboard Core `DashboardDemo.Page.al`: 3 occurrences, page compiles afterwards. The rg path below remains for EditorServices, whose rename tokenises quoted names by word. On `:w`, `wizard.organise_file` renames the object's file to match its new name.

**Quote scanning pairs delimiters left to right.** Both `find_quoted_string` (single) and `dquoted_id_at_cursor` (double) walk from the start of the line pairing quotes, treating a doubled quote as an escape. Do not "scan left for the nearest quote" — a cursor on a *closing* quote then pairs it with the next string's opening quote, so `Cust.Get("Foo"); Other("Bar")` yields `); Other(` as the rename target.

**`find_proc_bounds(lines, cursor_lnum)`** — all line numbers 1-based. Returns `{ hdr, var, beg, fin }`. `var` is nil if no var block. Used by both `extract_label` and `extract_to_procedure`.

**`M.extract_to_procedure()`** — extracts visual selection (`'<`/`'>` marks) into a new `local procedure`:
1. Parses `var` block (lines `b.var+1`..`b.beg-1`) — greedy regex captures full type including `Record "Name" temporary`, `List of [...]`, etc. Skips `Label`/`TextConst` (compile-time constants, not passable as params).
2. Finds referenced vars in selection → parameters. `var` prefix when: type is `Record`/`array`/`List`/`Dictionary`, OR assigned (`:=`) in selection.
3. Re-indents body by stripping `min_indent` then adding `proc_indent .. "    "`.
4. **Bottom-up edit order**: insert new procedure at `b.fin` first (below selection), then replace selection. This keeps selection line numbers valid — do not reverse.

**V1 limits**: only detects local `var` block vars (not outer procedure params); identifiers inside string literals may false-match.

**`M.extract_label({ locked })`** — cursor inside single-quoted string → prompts for Label var name → replaces all occurrences in proc body → inserts `var` declaration via `insert_var_decl` (local or global scope). **Default is a translatable label.** Until 2026-11-15 `Locked = true` was emitted unconditionally, so every extracted label silently dropped out of translation; `:ALExtractLockedLabel` / the "Extract to locked Label" action pass `locked = true`.

**Pure refactors take and return string arrays** — `to_validate`, `to_evaluate`, `make_var_global`, `add_publishers`, `promote_action`, `missing_handlers` + `create_handler_function`. They return `(nil, reason)` on refusal; the `*_at_cursor` / `convert_*` wrappers read the buffer and `vim.notify` the reason. `mask_strings(line)` blanks quoted spans (single and double, doubled quote = escape) so `:=`, `.` and `{}` searches never land inside a literal — that is how `Rec.Name := 'a := b';` converts correctly and why `+=` is refused (no `:=` left).

`add_publishers` edits bottom-up: publishers after `end;`, `OnAfter…` call before `end;`, `IsHandled` block after `begin`, then the `IsHandled: Boolean` declaration. Config `setup({ codeactions = { publisher_var_params = true, initialize_is_handled = true } })`, read through `package.loaded["al"]` so the module never requires `al` itself. `promote_action` walks brace blocks (`block_end`) from the enclosing `actions` line; it appends to the first `group` in `area(Promoted)`, else creates `area(Promoted) { group(Category_Process) { … } }`.

## Add missing usings (`lua/al/namespace.lua`)

`:ALAddUsings` requested `source.organizeImports` from the language server; the AL tool's server has no code actions, so it only printed "method textDocument/codeAction is not supported" (2026-11-21). It now resolves usings itself (EditorServices still gets organizeImports):

1. **`refs_in(lines)`** — referenced objects: `Record/Codeunit/Page/Report/Query/XmlPort/Enum/Interface/TestPage X`, `Database::/Page::/… X`, `extends`/`customizes`/`implements`, `SourceTable`, `TableRelation`, `LookupPageId`/`DrillDownPageId`/`CardPageId`, `part(…; X)`, `dataitem(…; X)`, `tableelement(…; X)`, `tabledata X`. `mask_code` blanks single-quoted literals and `//` comments but keeps `"quoted identifiers"`.
2. **Namespace index** — every object of every package in the package cache, from the `.app`'s **`SymbolReference.json`** (`Namespaces` tree; names each object's namespace even when the package has no `.al` source), read with `platform.zip_member` (`unzip -p` / `tar -xOf`) and cached per `.app` in `stdpath("cache")/alnvim/nsindex/` (valid while newer than the `.app`). Base Application decodes to ~250 MB in ~0.8 s, so the first run notifies and `collectgarbage()`s after each package; measured 3.2 s for 10 packages, then 0.03 s. Plus the project's own files (`namespace X;` + object header).
3. **`missing_usings`** — a reference is satisfied by the file's own namespace, an existing `using` (case-insensitive) or the global namespace; otherwise one candidate → add, several → reported, never guessed. **`insert_usings`** merges into a sorted block keeping it sorted, appends to an unsorted one, else inserts `namespace; / blank / usings / blank`.

The compiler's AL0185 ("Table 'X' is missing") was not used as the source: it comes only for declarations, and `Page::X` references surface a compile later. Verified on a bc-dashboard Core copy: three namespaces added, AL0185 gone.

## Change namespace (`:ALChangeNamespace [old new]`)

For turning a POC into a PTE. Moves every project namespace under `old` to `new` (prefix: `Demo.Sales` → `Contoso.Sales`), with prompts pre-filled from the declared namespaces' common prefix and `suggest_namespace`, then one confirm with counts. Rewrites `namespace` lines under the prefix, and `using` lines and qualified references (`P."Name"`, `P.Name.X`) **only when P is declared by the project** — a dependency often shares the prefix (Location renamed out of `SinclairSoftScotland` keeps `using SinclairSoftScotland.DashboardCore`). Qualified references need two or more segments (`Demo.Run()` is a variable) and a start not preceded by `.`/`"`; strings and comments are masked. Files keep their BOM, CRLF and final newline (`read_lines`/`write_lines`); buffers with unsaved changes stop the run, unmodified open buffers are reloaded. Apps that depend on the renamed one are not touched. Verified on a copy of bc-dashboard Location: 9 files, compile clean.

## Code actions (`lua/al/codeactions.lua`)

The agentic LSP has no `codeActionProvider`, so `vim.lsp.buf.code_action` did nothing on the user's backend. `M.register({ id, title, kind, applicable(ctx), run(ctx) })` keeps Lua actions; `M.pick({ only, range })` builds `ctx` (`bufnr, root, lines, row, col0, line, sel_start, sel_end, visual, bounds, diagnostics` — cursor-line diagnostics only), filters by `kind` prefix (`"refactor"` matches `"refactor.extract"`), and shows `vim.ui.select`. **It requests `textDocument/codeAction` only when `lsp.client(bufnr).server_capabilities.codeActionProvider` is set** — otherwise the request sits pending forever and the Lua actions never show. Server results are merged with a `[LSP]` prefix. **The `vim.ui.select` call must not pass `kind = "codeaction"`** — snacks.nvim's `ui_select` formats that kind as LSP items and indexes `item.ctx`, so with a snacks-based config (Catnip) the picker died with "attempt to index local 'ctx'" and nothing showed. It passes `kind = "al.codeaction"`; `tests/codeactions_spec.lua` guards it. Built-in actions are registered at the bottom of the module (not in refactor.lua, which must not require codeactions). `M._test = { registry, applicable_for }`.

## Diagnostic quick fixes and navigation (`lua/al/fixes.lua`)

Actions keyed on **`diagnostic.code`** of the cursor line, registered in codeactions.lua with
kind `quickfix`. `compile.push_diagnostics` sets `code = "ALxxxx"/"AAxxxx"` (parsed from the
start of alc's message) and `source = "alc"`; the LSP client sets `code` itself. Until
2026-11-15 the alc namespace carried no `code`, so nothing could key on it.

- **Create procedure** (`AL0118`/`AL0132`): `parse_call_args` splits the call at the diagnostic
  column on top-level commas (quotes and bracket nesting respected — `Foo(Cust, 'a,b', Qty + 1)`
  is three args). Types: literals by shape, identifiers by **hover** (`basedef.hover_text`,
  all in parallel, 1.5s timeout, else `Variant`); Record params are `var`. Unqualified →
  `local procedure` after the enclosing procedure; `Qualifier.Name(...)` → hover the qualifier,
  `basedef.find_object`, and insert only when the file is **under the project root** — a
  symbol-package stub is a read-only extracted copy. No return type.
- **AA0137** removes the declaration (one name from a `a, b: T` list), and the `var` keyword
  when nothing is left under it. **AA0206** removes a single-line `:=` statement. **AA0008**
  inserts `()` after the identifier at the column (falls back to the quoted name in the message).
- **AA0021** sorts the var block (`sort_var_block`): Record, Report, Codeunit, XmlPort, Page,
  Query, Notification, BigText, DateFormula, RecordId, RecordRef, FieldRef, FilterPageBuilder,
  then every other type in its original order; `array[N] of X` ranks as X. Order probed on tool
  30.0.42 (an Integer above `array[2] of Record` and a Label above a Record are both flagged).
  The sort is stable, so a compliant block is unchanged. Comment, attribute and blank lines move
  with the declaration below them; a declaration runs to its `;`. `:ALSortVariables` /
  `<leader>acv` sorts every block in the buffer; `:ALFixCops` sorts whole files **after** the
  line-addressed fixes, because a sort moves the lines an AA0137 points at.
- **`:ALFixCops`** — `compile.analyze_diagnostics(root, on_done)` (the `on_done(qf)` callback
  was added for this; a cancelled run never calls it), then every fix **bottom-up per file**
  on loaded buffers, not written; quickfix lists what changed.
- **Option → enum** (`:ALRefactorToEnum [extensible]`): `option_to_enum` parses the enclosing
  `field(...)` block, `OptionMembers` (quoted members, `" "` blank) and `OptionCaption`
  (used only when the count matches), retypes the field `Enum "Name"`, drops both properties,
  and the enum is written through `wizard.build_path` + `write_and_open` with
  `ids.next_id(root, "enum")`. The field buffer is edited **before** `write_and_open` switches
  to the new file.
- **Navigation** (kind `navigate`, `:ALFindRelated` runs the single applicable one):
  `[EventSubscriber(..., 'Event', ...)]` → rg `--multiline` for an `IntegrationEvent|BusinessEvent`
  attribute followed by `procedure "?Event"?\s*\(` over `explorer.build_search_dirs` — the `(`
  boundary is what stops `OnX` matching `OnXY`; `[HandlerFunctions('A,B')]` → `procedure A(` in
  the project; `Rec.Insert/Modify/Delete/Rename(` → hover the qualifier, `find_object`, then
  `basedef.member_line` for the trigger. Results go to quickfix; one hit jumps.

`basedef.lua` exports `hover_text`, `find_object`, `parse_hover`, `member_line`,
`target_at_cursor`; `wizard.lua` exports `build_path`, `write_and_open`. Those are the one
hover/object-lookup and one file-naming path — do not duplicate them in fixes.lua.

## Tests, docs and run object (`lua/al/tests.lua`)

All three are tool 30+ subcommands; `need(subcmd)` goes through `altool.has` and names
`:ALInstallDotnetTool` when missing. No extension fallback (VS Code's test runner is an
EditorServices protocol extension; the tool's CLI replaces it).

- **Discovery is offline.** `al listtests --appfile <built .app> --project <root>` reads the
  test codeunits out of the package through `altool.run_json` (collected, no float — nothing
  here can prompt for a sign-in). No `.app` → `compile.compile(root, nil, cb)` first; the
  `.app` is located with `publish.find_app`. Output is one JSON document:
  `{"codeunits":[{"id":50130,"name":"My Tests","methods":[{"name":"X","isDataDriven":false}]}]}`
  (captured on tool 30.0.42; fixture in `tests/tests_spec.lua`).
- **Running streams.** `al runtests <id> --project <root> --raw [--testmethods M]… <connection
  flags>` through `altool.run` with `altool.cred_env(cfg)`, because AAD can stop for a device
  code. `--testmethods` is a `string[]` option: **repeat the flag per method**, do not
  comma-join. `altool.run` gained `opts.on_lines`, a tap on the cleaned output, so the parser
  sees the same lines the user watches. The `--raw` summary format comes from decompiling
  `TestRunService.FormatResponse` (bc2 was down during Phase 2, so it is **not verified
  live**): `===== Codeunit N =====`, `  PASS|FAIL|SKIP Name (Nms)`, a 7-space-indented error
  line under a FAIL, and `Test run completed: P passed, F failed, S skipped.` per codeunit
  and again as the final total. **When anything failed the whole summary is written to
  stderr behind `Test run failed: `**, so `parse_runtests` strips that prefix on every line
  and takes the totals from the *last* summary line. Results map to quickfix by scanning
  project files for `codeunit <id>` then `procedure <Method>(`.
- **Cursor variant** (`:ALRunTests!`): codeunit from `wizard.find_obj_decl` (exported for
  this), method from `refactor.helpers.find_proc_bounds` and a walk up through the attribute
  lines (`[HandlerFunctions(...)]` may sit between `[Test]` and the header).
  **`local kind, id = decl and parse_obj_header(decl)` was the bug that made it never run**:
  `and` keeps only the first return value, so `id` was always nil (fixed 2026-11-22; guard in
  `tests/views_spec.lua`). Use an `if` when a call returns several values.
- **Failed runs go to `host.locations`**: quickfix as a new list (`action = " "`), then the
  Catnip navigator or `:copen`. `fixes.lua` (`:ALFixCops`, multi-hit `:ALFindRelated`) does the
  same; a single hit still jumps with `:cfirst`.
- **`al doc build -s <app> -o <root>/.aldoc -c <cache>`** emits a docfx YAML tree
  (`reference/<app>/toc.yml`, one `.yml` per object) — no HTML. `:ALDoc` opens an
  `index.html` if one ever appears, else notifies the folder.
- **`:ALRunObject`** builds on `conn.webclient_url(cfg)` but replaces its startup-object
  query (`?page=50100&tenant=default`; cloud has no tenant parameter). Types: page, report,
  table, query, xmlport, codeunit; extensions are refused with a reason.

## Snippets (`lua/al/snippets.lua`)

`M.load()` / `M.reload()` — explicit merge, keyed by prefix, later wins: the extension's `al`-language snippet files (its `package.json` `contributes.snippets`; only when `ext.path` is set) < `snippets/al.json` < `snippets/al-user.json`. Each entry goes through `ls.parser.parse_snippet` and the set is registered with `ls.add_snippets("al", list, { key = "alnvim" })`; the same key replaces the previous set, so `reload()` is a re-run that touches nothing else in the session. Files are read with `json.decode_jsonc`.

**No `package.json` at the repo root.** It made LuaSnip's `from_vscode` loaders (including a user's `lazy_load()`, which scans the runtimepath) load the bundled files a second time beside the merge. **`snippets/al.json` is ALNvim-only** — the 31 copies of MS snippets (`ttable`, `tpage`, `tif`, …) were removed because the extension ships them; without an extension only the 12 ALNvim snippets plus user ones exist.

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

**On-prem UserPassword debugging: credentials go in the adapter's environment.**
`:ALLaunch` against on-prem never worked — "Could not publish the package to the server"
after "An internal error has occurred", on Linux *and* Windows (it had been logged as a
Windows-only problem with unknown cause). The adapter only received credentials through
`save_creds_to_lsp` → `al/saveUsernamePassword` on the EditorServices language server.
The adapter's `Microsoft.Dynamics.Nav.Deployment.dll` reads **`BC_SERVER_USERNAME` /
`BC_SERVER_PASSWORD`** — the same variables `al publishapp` uses — so
`debug.adapter_creds(cfg, user, pass)` puts them in the adapter env for `UserPassword` /
`NavUserPassword` (launch and attach). `platform.adapter_env(stub, extra)` appends them; on
Windows, where the adapter otherwise inherits (env `nil`), it builds the full inherited
environment plus the extras, because a non-nil env *replaces* the child's environment.
Only the current dotnet-layout extension (18.0.2732683) carries those strings; older
extensions still depend on `save_creds_to_lsp`, which still runs.
Verified 2026-10-02 against `bc2` (BC 27.0 on-prem, `bcl` on VM101): adapter logs
"Using credentials from environment variables", publishes, opens a SignalR debug session,
and a breakpoint in `OnOpenPage` stops at the right line once the browser tab with the
debugging context loads. BC's adapter reports a breakpoint hit as `reason = "Step"`, and
its first `stackTrace` reply can take ~5s.

**Browser:** the adapter follows the publish with `al/openUri` carrying the web client URL
**with the debugging context and the real web port**. ALNvim also opened
`conn.webclient_url(cfg)` on `refreshExplorerObjects` — a second tab, on the wrong port
(`:80`, not the env's web port) and with no debug context. That listener is now a 5s
fallback that fires only if `al/openUri` never arrived. Both honour launch.json
`launchBrowser` (`_want_browser`); ALNvim always sends `launchBrowser=false` to the adapter
on Linux/macOS, so the user's choice has to be carried separately.

**Those flags are declared at the top of debug.lua, above every function that uses them.**
They were first added beside `make_adapter_env`, *below* `register_al_dap_events`; a
`local` declared after a function is not in scope inside it, so there they were globals —
`_want_browser` read `nil`, the debugging-context URL never opened, and only the
wrong-port fallback did. A browser session without the debugging context never hits a
breakpoint, which is how the first live breakpoint test failed.

**Publish** (`publish.M.publish`): `al publishapp` only — all BC versions, AAD/Windows/UserPassword auth built in; explicit connection flags from the picked launch config (`altool.connection_flags`) override launch.json; UserPassword creds via `altool.cred_env`. Output streams through `altool.run`. **`forceUpgrade: true` must be sent as `--forceupgrade`** — the CLI does not read that key from launch.json, so it was silently ignored by `:ALPublish` until 2026-11-14; `:ALLaunch` needs nothing, the launch request hands it to the adapter as VS Code does. The DAP-adapter (`debug.publish_only`) and direct-HTTP (`publish_http`, BC < 25) fallbacks were removed — they turned a missing tool into a crash on Windows. `:ALLaunch` still publishes through the adapter, because it debugs.

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

`tests/run.sh` — dependency-free suite (482 assertions). Runs under `nvim --headless -u NONE` with only the repo on the runtimepath: no plugin manager, no plenary, no network.

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
- **Fakes must share state the way the real module does.** `debug.lua` registers its DAP
  event listeners once per session; a fresh fake `nvim-dap` per test left every test after
  the first with no listeners at all. One fake per file, like the one real module.
- **Run fake timers after the events, not inline.** Executing `vim.defer_fn` immediately
  fired the 5s browser fallback before the `al/openUri` that arrives 0.5s later.
- **Absent means absent.** `-u NONE` still has `~/.config/nvim` on the runtimepath, so on
  the author's machine `require("catnip.ui")` finds the *real* Catnip. `host_spec`'s
  "without Catnip" tests install a failing `package.preload` entry; the "with Catnip"
  tests install `tests/fakes/catnip/{ui,navigator}.lua` (real floats, every call recorded,
  the real `View:open` tab switch kept so D1 can go red).
- A mutation that is a pure reordering (swapping two mutually exclusive `if`
  branches) *should* stay green. Use one as a control: if it goes red, the test
  is asserting on something incidental.

## Project layout

```
<project>/app.json  .alpackages/  .snapshots/  .vscode/launch.json  src/*.al
```

## AI agents (Claude Code / Pi)

`lua/al/agent.lua` opens an AI coding agent in a terminal at the project root. **One per
(command, root)**: a second `:ALClaude` focuses the window, or shows the buffer again when the
window was closed, instead of adding a split and a second agent; closing the window never stops
the agent (`bufhidden=hide`). A window open in another tab is moved here, not focused there
(that would switch tab). Under Catnip the window is a float sized like an output view
(`host.float_for`); natively `botright vsplit`. Catnip's own `<leader>cc` Claude terminal is
separate and untouched.
- `:ALClaude` / `<leader>ai` → **Claude Code** (`claude` CLI; uses the `al:<project>` MCP entry `al.mcp` writes to `<project>/.claude/settings.json`).
- `:ALPi` / `<leader>ak` → **Pi** ([pi.dev](https://pi.dev)). Built as `{ pi, -e <pi_provider>, --model <pi_model> }` unless `agent.pi_cmd` is set.

Configure via `require("al").setup({ agent = { claude_cmd, pi_cmd, pi_provider, pi_model, pi_env } })`.
Per-machine Pi + Ollama setup (Node 22, provider extension, HTTPS/TLS) — see `docs/pi-setup.md`.

`ALOllamaChat` is a deprecated alias → `:ALClaude`.

## Ghost completions
`lua/al/ghost.lua` — inline FIM ghost text from an Ollama server (`<leader>aI` toggle, `<M-l>` accept). The ghost clears when the cmp menu opens (`cmp.event:on("menu_opened")`, hooked on toggle); it only checked `cmp.visible()` when a suggestion arrived, so a menu opened later showed both. The FIM prefix is at most `M.PREFIX_LINES` (150) lines ending at the cursor — the whole file above the cursor was sent (prompt time on the model server was not timed). Defaults to `http://localhost:11434` / `qwen2.5-coder`; override `ghost = { endpoint, model, insecure }` via `setup()`. Set `insecure = true` for an HTTPS endpoint with a self-signed/local-CA cert.
