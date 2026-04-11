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
| `lua/al/symbols.lua` | Download `.app` symbol packages from BC dev endpoint |
| `lua/al/publish.lua` | Compile then POST `.app` to BC |
| `lua/al/debug.lua` | Snapshot debugging + nvim-dap adapter config |
| `lua/al/explorer.lua` | Telescope pickers: objects (`M.objects`), procedures (`M.procedures`), grep (`M.search`) |
| `lua/al/ids.lua` | Object ID completion from `app.json` `idRanges`; `M.next_id` used by wizard |
| `lua/al/cops.lua` | Code Cop selector + browser selector — config in `alnvim.json` |
| `lua/al/mcp.lua` | Writes `~/.claude/settings.json` for AL MCP server |
| `lua/al/wizard.lua` | AL Object Wizard — creates new AL object files |
| `lua/al/diff.lua` | Git Diff Explorer — Telescope picker with diff preview |
| `lua/al/layout.lua` | Report Layout Wizard — Excel generation + rendering section injection |
| `lua/al/help.lua` | Opens MS Learn AL docs / alguidelines.dev in browser |
| `lua/al/status.lua` | Statusline state store (LSP, project, compile, publish) |
| `lua/al/platform.lua` | All platform-specific operations (paths, chmod, browser, zip) |
| `lua/al/snippets.lua` | Loads `snippets/al.json` into LuaSnip |
| `ftdetect/al.vim` | `filetype=al` for `*.al`, `*.dal` |
| `ftplugin/al.lua` | Buffer-local settings and keymaps |
| `syntax/al.vim` | Vim syntax highlighting from `alsyntax.tmlanguage` |
| `colors/bc_dark.lua` | BC Dark colorscheme |
| `colors/bc_yellow.lua` | Alias for bc_dark with different `colors_name` — global default in `init.lua` |
| `snippets/al.json` | VSCode-format snippets |
| `package.json` | Tells LuaSnip's `from_vscode` loader about `snippets/al.json` |

## Windows compatibility

All OS-specific operations go through `lua/al/platform.lua` — never add platform conditionals elsewhere.

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

## AL Toolchain paths

`ext.lua` picks the highest-version `~/.vscode/extensions/ms-dynamics-smb.al-*` directory.

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

**`expectedProjectReferenceDefinitions`** — always prepend implicit Microsoft base packages (System, System Application, Business Foundation, Base Application, Application) using stable GUIDs, even when `app.json` has no dependencies. Without them, AL server never loads standard symbol tables. Versions from `app.json` `platform`/`application` fields. Explicit deps appended after, duplicates skipped.

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

## Compiling

`:ALCompile` runs `alc /project:<root> /packagecachepath:<root>/.alpackages` async. Full-width horizontal split (~30% height) streams output live. `<CR>` on diagnostic opens file at line/col. `q`/`<Esc>` closes panel. Quickfix also populated (`<leader>aq`).

Code analyzers from `alnvim.json` auto-included as `/analyzer:` flags. `ruleset_path` in `setup()` passes `/ruleset:<file>`. **Do not add `ruleSetPath` to `app.json`** — custom properties break AL validation.

Success: exit code 0 + empty quickfix. Error format: `/path/file.al(line,col): error|warning ALxxxx: message`.

`M.compile(dir, extra_args, on_success)` — `on_success()` called in `vim.schedule` only on clean build. `publish.lua` chains upload via this.

## Keymaps (AL buffers only)

| Key | Action |
|---|---|
| `<leader>ab/ap/aP/as` | Compile / Publish / PublishOnly / DownloadSymbols |
| `<leader>ao/al` | OpenAppJson / OpenLaunchJson |
| `<leader>aq` | Quickfix list |
| `<leader>ac/aB` | SelectCops / SelectBrowser |
| `<leader>am/aM` | McpSetup / McpStatus |
| `<leader>ah/aH/aG` | Help / HelpTopics / Guidelines |
| `<leader>an/aw/aW` | NewObject / ReportLayout / OpenLayout |
| `<leader>aN` | AddNamespace — add namespace to all source files |
| `<leader>aA/aD/ae/af/ag` | Analyze / Diff / Explorer / ExplorerProcs / Search |
| `<leader>aca/acf/acF/acn/acr` | Code actions (all/fix/fixAll/organise/refactor) |
| `<F5>`/`<leader>adl/ads/adf/add` | Launch / SnapshotStart / SnapshotFinish / DebugSetup |
| `gd` / `<C-o>` | AL go-to-definition / jumplist back |
| `<C-Space>`/`<Nul>` (insert) | Object ID completion (`<C-x><C-u>`) |

Explorer picker: `<C-s>` cycle sort (type/id/publisher/name), `<C-f>` live grep, `<CR>` open.

## User commands

`:ALInstallExtension`, `:ALCompile [dir]`, `:ALPublish [dir]`, `:ALPublishOnly [dir]`, `:ALDownloadSymbols [dir]`, `:ALLaunch [dir]`, `:ALSnapshotStart/Finish`, `:ALDebugSetup`, `:ALHelp [url]`, `:ALHelpTopics`, `:ALGuidelines`, `:ALNewObject [dir]`, `:ALReportLayout`, `:ALOpenLayout`, `:ALExplorer [dir]`, `:ALExplorerProcs`, `:ALSearch [dir]`, `:ALNextId`, `:ALAnalyze`, `:ALAddNamespace [dir]`, `:ALDiff [dir]`, `:ALSelectCops`, `:ALSelectBrowser`, `:ALMcpSetup/Remove/Status [dir]`, `:ALOpenAppJson`, `:ALOpenLaunchJson`, `:ALReloadSnippets`, `:ALClearCredentials`, `:ALInfo`, `:ALUpdate`

## Project root detection (`lsp.get_root()`)

1. Search upward from current buffer for `app.json`
2. Scan downward from `vim.fn.getcwd()` for all `app.json` files
3. One found → use it; multiple → `vim.fn.inputlist` prompt

All commands use `lsp.get_root()` — `compile.lua` has no separate `find_project_root()`.

## Symbol downloads

Always include implicit Microsoft base packages even with empty `app.json` dependencies:
- `Microsoft/System` — version from `app.platform`
- `Microsoft/System Application`, `Business Foundation`, `Base Application`, `Application` — version from `app.application`

Explicit deps appended after, duplicates skipped.

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

Auto-applied on AL window focus, restored on non-AL focus. Key colours: bg `#1E1E1E`, fg `#D4D4D4`, keywords `#00747F` (teal), types `#4EC9B0` (aqua), functions `#DCDCAA`, variables `#9CDCFE`, strings `#CE9178`, numbers `#9FD89F`, constants `#62CFD7`, status bar `#00747F`/`#FFFFFF`.

**`bc_yellow`**: near-black green bg `#010704`, fg `#efefef`, comments `#04b925`, keywords/types `#f6fa16`. Set as global default via `colorscheme bc_yellow` in `init.lua` — no per-window switching.

**Syntax strings use `oneline`** on `alString`, `alVerbatim`, `alQuotedIdent` — without it, unclosed quotes bleed colour across the file.

## AL Explorer (`lua/al/explorer.lua`)

`M.objects`: `rg` across project root + `~/.cache/nvim/alnvim/symbols/` extracted packages. Entry: `[src]`/`[sym]` tag, publisher, type, ID, name, filename. `<C-s>` cycles sort.

**Symbol extraction:** `.app` files are ZIPs with `src/*.al` stubs, extracted to cache dir keyed on sanitised filename. `.ok` stamp skips re-extraction. `unzip` exits code 1 on no-match glob (not failure) — check `vim.fn.isdirectory(dir .. "/src")` not `vim.v.shell_error`.

Publisher from filename format `Publisher_Name_Major.Minor.Build.Rev.app`.

## Object ID completion (`lua/al/ids.lua`)

`<C-Space>`/`<Nul>` in insert mode on object-type keyword line → `<C-x><C-u>`. Global `_G.ALCompleteObjectId` bridges to `require("al.ids").complete` (avoids `v:lua` compatibility issues). Shows up to 5 free IDs per range with usage info. `:ALNextId` notifies next 3 free IDs in normal mode.

Types with IDs: `table`, `tableextension`, `page`, `pageextension`, `pagecustomization`, `codeunit`, `report`, `reportextension`, `query`, `xmlport`, `enum`, `enumextension`, `permissionset`, `permissionsetextension`, `profile`, `controladdin`.

## Code Cops (`lua/al/cops.lua`)

Four cops: `${CodeCop}`, `${PerTenantExtensionCop}`, `${UICop}`, `${AppSourceCop}`. Default: first three. Config + browser saved to `<root>/.vscode/alnvim.json`. After confirm, `cops.apply()` re-sends `al/setActiveWorkspace` — live effect without LSP restart. Telescope: `<Tab>` toggle, `<CR>` apply. Fallback: iterative `vim.ui.select` with `[x]`/`[ ]`.

Browser values stored in `alnvim.json` as `"browser"`. macOS: no-path value → `open -a <browser>`. `platform.open_url(url, browser)` — empty browser → OS default. `_current_root` in `debug.lua` set at start of `M.launch`/`M.setup_dap` for global DAP listeners.

## AL MCP Server (`lua/al/mcp.lua`)

Writes `~/.claude/settings.json` to spawn `al launchmcpserver` via stdio. Entry key: `"al:" .. basename(root)`. Binary: `~/.dotnet/tools/al`. Read/write pattern: `readfile` → `json_decode` → mutate → `json_encode` → `writefile` (preserves all other keys). `auto_mcp = true` (default) calls `mcp.configure(root)` once per client on `LspAttach`. Restart Claude Code / run `/mcp` to pick up changes. 8 MCP tools: `al_build`, `al_publish`, `al_debug`, `al_setbreakpoint`, `al_symbolsearch`, `al_downloadsymbols`, `al_snapshotdebugging`.

## AL Extension Installer (`lua/al/install.lua`)

Downloads MS AL VSIX from `vsassets.io` CDN (not marketplace.visualstudio.com — returns non-ZIP redirect). Required headers: `Accept: application/octet-stream`, `X-Market-Client-Id: VSCode`, `User-Agent: VSCode/...`. Verifies ZIP magic bytes (`PK`). Calls `ext.reload()` + `doautocmd FileType al` after install. Registered before `ext_path` guard — always available.

## AL Text Objects (`lua/al/textobj.lua`)

| Keys | Selects |
|---|---|
| `af`/`if` | around/inside procedure or trigger |
| `aF`/`iF` | around/inside nearest begin/end or case/end block |

## AL Object Wizard (`lua/al/wizard.lua`)

12 types: Table (DataClassification), TableExtension (extends picker), Page (PageType + SourceTable), PageExtension (extends), Codeunit, Report (SourceTable), Query (SourceTable), XmlPort, Enum (Extensible), EnumExtension (extends), Interface (no ID), PermissionSet (auto-generates permissions).

File naming (CRS): `src/<obj_type>/<id>.<SanitisedName>.<FileType>.al`. Interface: `src/interface/<Name>.Interface.al`. Auto-moves on `:w` (`wizard.M.organise_file` via `BufWritePost` in `ftplugin/al.lua`) — uses `vim.fn.rename` + `nvim_buf_set_name`, no reload needed.

PermissionSet scan uses `platform.glob_al_files(root)` + `io.open` (not `find` — not available on Windows). Tables generate two entries (`tabledata RIMD` + `table X`); others get `X`.

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

**⚠️ On-prem ALLaunch on Windows — NOT WORKING**: fails with "Could not publish the package". Cloud works on both platforms. Root cause unknown. Use cloud sandboxes or VSCode for on-prem debugging.

**Cloud publish** (`/dev/apps`): returns HTTP 415 for direct `application/octet-stream` POST — cloud API doesn't expose this to external clients. The DAP adapter (EditorServices.Host) handles publish internally.

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

## Project layout

```
<project>/app.json  .alpackages/  .snapshots/  .vscode/launch.json  src/*.al
```
