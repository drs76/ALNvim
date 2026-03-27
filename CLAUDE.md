# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ALNvim is a Neovim plugin (Lua) that adds Business Central AL language support, loaded via the Neovim 0.11+ built-in `vim.pack.add()` API. It integrates the AL language server shipped with the MS AL VSCode extension under `~/.vscode/extensions/`. The newest installed version is auto-detected at startup by `lua/al/ext.lua`.

## Structure

| Path | Purpose |
|---|---|
| `plugin/al.lua` | Auto-loaded entry point: starts LSP, registers handlers, creates user commands |
| `lua/al/init.lua` | `require('al').setup(opts)` – user-facing configuration |
| `lua/al/ext.lua` | Auto-detects the newest MS AL VSCode extension directory (cached at startup) |
| `lua/al/lsp.lua` | Helpers for finding project root and reading `app.json` |
| `lua/al/connection.lua` | Shared BC connection utils: parse launch.json, build URLs, curl auth flags |
| `lua/al/compile.lua` | Async `alc` compiler integration — floating output window + quickfix |
| `lua/al/symbols.lua` | Download `.app` symbol packages from BC dev endpoint |
| `lua/al/publish.lua` | Compile then POST `.app` to BC dev endpoint |
| `lua/al/debug.lua` | Snapshot debugging (BC API) + nvim-dap adapter config |
| `lua/al/explorer.lua` | Telescope pickers: browse all AL objects (`M.objects`), procedures in file (`M.procedures`), live grep (`M.search`) |
| `lua/al/ids.lua` | Object ID completion — suggests next free IDs from `app.json` `idRanges`; `M.next_id` used by wizard |
| `lua/al/cops.lua` | Code Cop selector — per-project cop config, Telescope/fallback picker, live apply via `al/setActiveWorkspace` |
| `lua/al/wizard.lua` | AL Object Wizard — interactive prompt flow to create new AL object files |
| `lua/al/help.lua` | AL Help panel — toggleable left split showing MS Learn AL docs via `smd` (ANSI) or render-markdown fallback |
| `lua/al/snippets.lua` | Loads `snippets/al.json` into LuaSnip via the VSCode loader |
| `ftdetect/al.vim` | Sets `filetype=al` for `*.al` and `*.dal` files |
| `ftplugin/al.lua` | Buffer-local settings and keymaps for AL files |
| `syntax/al.vim` | Vim syntax highlighting derived from `alsyntax.tmlanguage` |
| `colors/bc_dark.lua` | BC Dark colorscheme (applied per-buffer for AL files, restored on BufLeave) |
| `snippets/al.json` | VSCode-format snippets (object templates + control flow) |
| `package.json` | Tells LuaSnip's `from_vscode` loader about `snippets/al.json` |

## AL Toolchain paths

`ext.lua` scans `~/.vscode/extensions/ms-dynamics-smb.al-*` and picks the highest version numerically. Binaries are relative to that directory:

```
<ext_path>/
  bin/linux/Microsoft.Dynamics.Nav.EditorServices.Host   ← LSP server (stdio)
  bin/linux/alc                                          ← AL compiler
  bin/linux/altool                                       ← AL tools helper
  bin/linux/aldoc                                        ← AL documentation generator
```

Both `alc` and the LSP host are shipped without the exec bit. `plugin/al.lua` sets it at startup via `vim.uv.fs_chmod`.

**LuaJIT gotcha**: Neovim uses LuaJIT (Lua 5.1), which does not support `0o` octal literals. Use decimal `73` instead of `0o111` for the execute-bit mask.

## Loading / pack setup

`vim.pack.add` defaults to `load = false` during `init.lua` (because `vim.v.vim_did_init == 0`), which means `packadd!` — adds to rtp but does **not** source `plugin/` files. The fix is to pass `{ load = true }`:

```lua
vim.pack.add({ { src = "/path/to/ALNvim" }, ... }, { load = true })
```

The installed pack lives at `~/.local/share/nvim/site/pack/core/opt/ALNvim/`. Edits to the dev copy (`~/Documents/ALNvim`) must be committed and then pulled into the installed copy:

```bash
git -C ~/.local/share/nvim/site/pack/core/opt/ALNvim pull origin master
```

## LSP

The AL language server speaks standard LSP over stdio. It is started via a `FileType al` autocmd using `vim.lsp.start`:

```lua
vim.lsp.start({
  name     = "al_language_server",
  cmd      = { lsp_bin },
  root_dir = root,   -- nearest directory containing app.json
  init_options = {
    workspacePath = root,
    alResourceConfigurationSettings = { ... },
  },
})
```

If the server fails to attach, check `vim.lsp.get_clients()` and `:checkhealth lsp`.

### Custom protocol methods

The AL server extends LSP with several custom methods. All are handled in `plugin/al.lua`:

| Method | Direction | Purpose |
|---|---|---|
| `al/setActiveWorkspace` | client → server | Trigger project/symbol indexing. Must be sent after attach. |
| `al/activeProjectLoaded` | server → client | Server notifies when indexing is complete. This is a REQUEST, not a notification — client must respond. |
| `al/progressNotification` | server → client | Loading progress (percent). Notification — no response needed. |
| `al/gotodefinition` | client → server | Go to definition (server has `definitionProvider = false`). Returns `file://` or `al-preview://` URI. |
| `al/previewDocument` | client → server | Fetch source text for an `al-preview://` virtual document. Payload: `{ Uri = uri }`. Response: `{ content = "..." }`. |

### `al/setActiveWorkspace` — critical payload format

The payload **must** be wrapped as `{ currentWorkspaceFolderPath, settings }`. Sending the settings fields at the top level causes silent server-side deserialization failure — the project never loads and `al/gotodefinition` fails with `projectId = null`.

```lua
client:request("al/setActiveWorkspace", {
  currentWorkspaceFolderPath = {
    uri   = "file://" .. root,          -- "file:///path/to/project"
    name  = vim.fn.fnamemodify(root, ":t"),
    index = 0,
  },
  settings = {
    workspacePath                       = root,
    alResourceConfigurationSettings     = {
      packageCachePaths    = { root .. "/.alpackages" },
      assemblyProbingPaths = {},        -- MUST be non-null array; empty avoids network-mount hang
      enableCodeAnalysis   = true,
      backgroundCodeAnalysis = "Project",
      enableCodeActions    = true,
      incrementalBuild     = true,
    },
    setActiveWorkspace                  = true,
    dependencyParentWorkspacePath       = vim.NIL,  -- null
    expectedProjectReferenceDefinitions = proj_refs, -- array of {appId,name,publisher,version}
    activeWorkspaceClosure              = {},
  },
}, callback, bufnr)
```

**`assemblyProbingPaths` must be a non-null JSON array.** Omitting it causes `ArgumentNullException("path")` crash. The VSCode default `['./.netpackages']` hangs indefinitely on network-mounted (CIFS/SMB) paths — use `{}`.

### `al/activeProjectLoaded` — must return a response

This is a server-initiated **request** (has an `id`). The Neovim `vim.lsp.handlers` callback must return `vim.NIL` to send a null JSON-RPC response back. Without this, Neovim throws an error and the server may stall.

```lua
vim.lsp.handlers["al/activeProjectLoaded"] = function(err, result, ctx)
  if not err then
    vim.notify("AL: project loaded — gd and K ready", vim.log.levels.WARN)
  end
  return vim.NIL  -- required: send null response to server
end
```

### `gd` keymap override

The server has `definitionProvider = false` — `textDocument/definition` returns nothing. `gd` must be overridden to use `al/gotodefinition`. Use `vim.schedule` to defer the keymap so it wins over the user's generic `LspAttach` handler.

**`al/gotodefinition` returns two types of location:**

1. **`file://` URI** — a real file on disk (project source). Open with `vim.cmd("edit ...")`.
2. **`al-preview://` URI** — a virtual document served by the language server (symbol stubs from `.app` packages). Must be fetched via `al/previewDocument { Uri = uri }` → `result.content`. Display in a read-only `nofile` scratch buffer with `filetype=al`. The content has Windows line endings (`\r\n`) — strip before splitting.

**Do not use `vim.lsp.util.jump_to_location` or `vim.lsp.util.show_document`** — both are deprecated or fail with "cursor position outside buffer" when the target file is not yet open. Open the file manually then set cursor with `pcall(nvim_win_set_cursor, ...)`.

**`al/previewDocument`** — payload: `{ Uri = "al-preview://..." }`, response: `{ content = "..." }`. The URI comes directly from the `al/gotodefinition` result. Scratch buffers are named after the URI so repeated `gd` calls reuse the same buffer.

### Pending requests

`al/setActiveWorkspace` and `al/gotodefinition` always appear as "pending" in `client.requests` — the server responds via `window/logMessage` notifications rather than proper JSON-RPC responses. This is expected behaviour.

### Non-standard completion item labels

The AL server sends completion item `label` fields as objects `{ label = "begin" }` rather than plain strings as the LSP spec requires. This crashes nvim-cmp in two ways: `string.byte` gets a table (`matcher.lua`), and `strdisplaywidth` gets a dict (`entry.lua`).

**Important:** `vim.lsp.handlers["textDocument/completion"]` and the `handlers` table in `vim.lsp.start` do NOT intercept this — nvim-cmp calls `client:request("textDocument/completion", ..., its_own_callback)` and the response goes directly to that callback, bypassing all handler tables.

The fix is to monkey-patch `client.request` in the `LspAttach` handler so the completion callback is always wrapped to normalise labels:

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
              if type(item.label) == "table" then
                item.label = item.label.label or ""
              end
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

The `_al_completion_patched` guard prevents double-wrapping when `LspAttach` fires once per buffer.

## Compiling

`:ALCompile [dir]` runs `alc /project:<root> /packagecachepath:<root>/.alpackages` asynchronously. The project root is the nearest directory containing `app.json`. Extra flags are passed via `config.alc_extra_args`.

**Output window:** a centered floating window opens immediately showing the full alc command and streaming all raw compiler output live. On completion a summary line is appended. Errors are highlighted red (`DiagnosticError`), warnings yellow (`DiagnosticWarn`), success green (`DiagnosticOk`). Press `q` or `<Esc>` to close.

**Quickfix list** is also populated with parsed errors/warnings for jump-to-error via `<leader>aq`.

Error line format parsed from alc output:
```
/path/to/file.al(line,col): error|warning ALxxxx: message
```

## Snippets

Snippets use LuaSnip's `from_vscode` loader pointed at this plugin directory. `package.json` declares `contributes.snippets[0].language = "al"`. Adding new snippets: edit `snippets/al.json` and call `:ALReloadSnippets`.

## Keymaps (AL buffers only)

| Key | Mode | Action |
|---|---|---|
| `<leader>ab` | n | `:ALCompile` |
| `<leader>ap` | n | `:ALPublish` |
| `<leader>aP` | n | `:ALPublishOnly` |
| `<leader>as` | n | `:ALDownloadSymbols` |
| `<leader>ao` | n | `:ALOpenAppJson` |
| `<leader>al` | n | `:ALOpenLaunchJson` |
| `<leader>aq` | n | Open quickfix list |
| `<leader>ac` | n | `:ALSelectCops` — select active code cops |
| `<leader>ad` | n | Buffer diagnostics list (Telescope or `vim.diagnostic.setloclist`) |
| `<leader>ah` | n | `:ALHelp` — toggle AL Help panel (MS Learn docs as Markdown) |
| `<leader>aH` | n | `:ALHelpTopics` — AL Help topic picker |
| `<leader>an` | n | `:ALNewObject` — AL Object Wizard |
| `<leader>ae` | n | `:ALExplorer` — browse all AL objects |
| `<leader>af` | n | `:ALExplorerProcs` — procedures in current file |
| `<leader>ag` | n | `:ALSearch` — live grep across all AL files |
| `<C-Space>` / `<Nul>` | i | Trigger object ID completion (`<C-x><C-u>`) |
| `<F5>` / `<leader>adl` | n | `:ALLaunch` — compile, publish, attach debugger |
| `<leader>ads` | n | `:ALSnapshotStart` |
| `<leader>adf` | n | `:ALSnapshotFinish` |
| `<leader>add` | n | `:ALDebugSetup` |
| `gd` | n | AL go to definition (via `al/gotodefinition`) |
| `<C-o>` | n | Navigate back from `gd` (standard Neovim jumplist) |

**Inside `:ALExplorer` picker:**

| Key | Action |
|---|---|
| `<C-s>` | Cycle sort mode: type → id → publisher → name |
| `<C-f>` | Jump to live grep (`:ALSearch`) |
| `<CR>` | Open file at object declaration |

Global LSP keymaps (`K`, `gr`, `<leader>rn`, etc.) are set by the user's `init.lua` via the `LspAttach` autocmd and apply to AL buffers too.

## User commands

| Command | Description |
|---|---|
| `:ALCompile [dir]` | Compile project with `alc` |
| `:ALPublish [dir]` | Compile then publish `.app` to BC |
| `:ALPublishOnly [dir]` | Publish existing `.app` to BC (skip compile) |
| `:ALDownloadSymbols [dir]` | Download `.app` symbol packages from BC |
| `:ALLaunch [dir]` | Compile, publish then attach debugger (F5 equivalent) |
| `:ALSnapshotStart` | Start a BC snapshot debugging session |
| `:ALSnapshotFinish` | Download snapshot file and open it |
| `:ALDebugSetup` | Configure nvim-dap for AL live attach |
| `:ALHelp [url]` | Toggle AL Help panel (MS Learn AL docs as Markdown); optional URL/slug argument |
| `:ALHelpTopics` | Open AL Help topic picker |
| `:ALNewObject [dir]` | AL Object Wizard: interactively create a new AL object file |
| `:ALExplorer [dir]` | Browse all AL objects across project + symbol packages |
| `:ALExplorerProcs` | Browse procedures/triggers in the current file |
| `:ALSearch [dir]` | Live grep across all AL files (project + symbol packages) |
| `:ALNextId` | Show next free object ID for the type on the current line |
| `:ALSelectCops` | Select active code cops for this project (Telescope or vim.ui.select) |
| `:ALOpenAppJson` | Edit project `app.json` |
| `:ALOpenLaunchJson` | Edit `.vscode/launch.json` |
| `:ALReloadSnippets` | Reload LuaSnip snippets |
| `:ALClearCredentials` | Clear cached BC credentials |
| `:ALInfo` | Show project and extension info |

## Project root detection (`lsp.get_root()`)

All commands use `lsp.get_root()` (including `compile.lua` which no longer has its own `find_project_root()`). Resolution order:

1. Search upward from the current buffer for `app.json` (fast path — works when editing an `.al` file)
2. Scan downward from `vim.fn.getcwd()` for all `app.json` files
3. If one found → use it; if multiple → prompt user to pick via `vim.fn.inputlist`

This supports multi-project workspaces (e.g. App + Test app in one workspace folder).

## Symbol downloads (`symbols.lua`)

`:ALDownloadSymbols` always includes the implicit Microsoft base packages even when `app.json` has no explicit dependencies:
- `Microsoft / System` — version from `app.platform` (defines Label, Text, Integer, etc.)
- `Microsoft / System Application` — version from `app.application`
- `Microsoft / Business Foundation` — version from `app.application` (BC 22+)
- `Microsoft / Base Application` — version from `app.application` (**contains Customer, Vendor, etc.**)
- `Microsoft / Application` — version from `app.application` (country/localization layer on top of Base Application)

**Full BC 22+ chain:** `System` → `System Application` → `Business Foundation` → `Base Application` → `Application`. Each package depends on the one below it. All must be present or the AL server cannot resolve types.

Explicit dependencies are appended after these, with duplicates skipped.

## AL project layout expected

```
<project>/
  app.json          ← manifest (publisher, name, version, dependencies)
  .alpackages/      ← downloaded symbol packages (.app files)
  .snapshots/       ← snapshot debug files (git-ignored)
  .vscode/
    launch.json     ← BC server connection for publish/debug
  src/              ← AL source files (*.al)
```

## BC dev API endpoints

All three feature modules hit the BC dev endpoint. On-prem base: `http[s]://<server>/<serverInstance>`. Cloud base: `https://api.businesscentral.dynamics.com/v2.0/<tenant>/<env>`.

| Feature | Method | Path |
|---|---|---|
| Download symbols | GET | `/dev/packages?publisher=…&appName=…&versionText=…&tenant=…` |
| Publish | POST | `/dev/apps?tenant=…&SchemaUpdateMode=…` |
| Snapshot start | POST | `/dev/debugging/snapshots` |
| Snapshot download | GET | `/dev/debugging/snapshots/<sessionId>` |

## `connection.lua` — credential resolution order

1. `al_username` / `al_password` fields in `launch.json` (non-standard, user-added)
2. `AL_BC_USERNAME` / `AL_BC_PASSWORD` env vars
3. Interactive `vim.fn.input` / `vim.fn.inputsecret` prompt

For AAD/Entra: `AL_BC_TOKEN` env var → Azure CLI `az account get-access-token` → interactive prompt.

**Important**: `"authentication": "Windows"` uses NTLM/Negotiate (`--ntlm --negotiate -u :`) and will silently fail on Linux without a Kerberos ticket — no prompt is shown. Use `"UserPassword"` for on-prem or `"MicrosoftEntraID"` for cloud.

Cloud `launch.json` example:
```json
{
  "type": "al",
  "request": "launch",
  "name": "BC Cloud",
  "environmentType": "Sandbox",
  "environmentName": "your-env",
  "primaryTenantDomain": "yourtenant.onmicrosoft.com",
  "authentication": "MicrosoftEntraID"
}
```
Bearer token via Azure CLI: `az account get-access-token --resource https://api.businesscentral.dynamics.com --query accessToken -o tsv`

## BC Dark colorscheme (`colors/bc_dark.lua`)

A per-buffer colorscheme applied automatically when an AL file is opened, restored to the previous colorscheme on `BufLeave`. Matches the user's VSCode TextMate colour settings:

| Element | Colour |
|---|---|
| Background | `#010704` |
| Foreground | `#efefef` |
| Comments | `#04b925` (green) |
| AL keywords / object types / built-in types | `#f6fa16` (yellow) — `Type`, `Structure` groups |
| Strings | `#ce8349` (orange) |
| Numbers / constants | `#2fafff` (blue) |

**Implementation note:** `ftplugin/al.lua` saves `vim.g.colors_name` before applying `bc_dark`, then uses a `BufLeave` autocmd to restore it and a `BufEnter` autocmd to re-apply it. Both are permanent (no `once=true`) so the theme toggles correctly across repeated focus changes — LSP hover floats, `gd` navigation to other files, split switching, etc. Do not use `BufWinLeave` (fires on float open/close, causing spurious restores) or `once=true` (breaks after the first focus change).

**Syntax string regions use `oneline`** on `alString`, `alVerbatim`, and `alQuotedIdent` in `syntax/al.vim`. Without `oneline`, unclosed quote characters bleed highlight colour across the rest of the file.

## AL Explorer (`lua/al/explorer.lua`)

Telescope pickers for navigating AL objects across the whole project and its symbol packages.

### Object picker (`M.objects`)

Runs `rg` with the AL object declaration pattern across:
1. The project root (source files)
2. Every extracted symbol package cache under `~/.cache/nvim/alnvim/symbols/`

Each entry shows: `[src]`/`[sym]` tag, publisher, object type, numeric ID, object name, filename.

Sort modes cycled with `<C-s>`: **type** (default) → **id** → **publisher** → **name**.

### Symbol package extraction (`ensure_extracted`)

`.app` files in `.alpackages/` are zip archives containing `src/*.al` stubs. `ensure_extracted` unpacks them to a cache dir keyed on the sanitised app filename (spaces → underscores). A `.ok` stamp file records the extraction time; re-extraction is skipped if the stamp is newer than the `.app` file.

**Important:** `unzip` exits with code 1 as a warning when one glob pattern matches nothing (not a failure). Use `vim.fn.isdirectory(dir .. "/src")` to check success — do not rely on `vim.v.shell_error`.

Publisher is extracted from the `.app` filename format `Publisher_Name_Major.Minor.Build.Rev.app` by stripping the trailing version segment then taking everything before the first underscore.

### Procedures picker (`M.procedures`)

Runs `rg` on the current buffer file only, matching `procedure`/`trigger` declarations. Jumps within the same buffer.

### Search (`M.search`)

Uses `telescope.builtin.live_grep` with `search_dirs` set to the same project + symbol package dirs used by the object picker. Filters to `*.al`/`*.AL` files.

## Object ID completion (`lua/al/ids.lua`)

Suggests the next free object ID(s) from `app.json`'s `idRanges` when creating a new AL object.

### Trigger

In insert mode, on a line starting with an AL object type keyword followed by a space (e.g. `codeunit `), press `<C-Space>` (mapped to `<C-x><C-u>` / `completefunc`). A popup appears with the next available IDs per range.

**Linux terminal note:** Most terminals send `0x00` (NUL) for Ctrl+Space. Both `<C-Space>` and `<Nul>` are mapped to `<C-x><C-u>` in `ftplugin/al.lua`.

### completefunc bridge

`completefunc` requires a Vimscript-callable global name. A named global `_G.ALCompleteObjectId` bridges to `require("al.ids").complete`. Using `v:lua` syntax is avoided as it can be rejected on some Neovim versions.

### Object types with IDs

`table`, `tableextension`, `page`, `pageextension`, `pagecustomization`, `codeunit`, `report`, `reportextension`, `query`, `xmlport`, `enum`, `enumextension`, `permissionset`, `permissionsetextension`, `profile`, `controladdin`. Types without numeric IDs (`interface`, `entitlement`, etc.) do not trigger the popup.

### Completion item format

```
word: "50042"
abbr: "50042"
menu: "[50000-50149 · 42 used]"
info:  "42 of 150 IDs used in range 50000-50149"
```

Up to 5 free IDs are shown per range so the user can choose a round number if preferred. `get_used_ids` scans the project with `rg -i` to find all IDs already assigned to that object type.

### Normal-mode helper

`:ALNextId` calls `M.show_next()` which notifies the next 3 free IDs for the object type on the current line (no insert mode required).

## AL Help panel (`lua/al/help.lua`)

`:ALHelp [url]` / `<leader>ah` toggles a left-side vertical split (85 cols, fixed width) showing
MS Learn AL documentation fetched as Markdown from the MicrosoftDocs GitHub repo.
`:ALHelpTopics` / `<leader>aH` opens a topic picker without toggling the panel.

**Source:** `https://raw.githubusercontent.com/MicrosoftDocs/dynamics365smb-devitpro-pb/main/dev-itpro/developer/<slug>.md`

Requires `curl` and an internet connection.

### Rendering — smd (preferred) vs render-markdown fallback

The panel has two rendering paths:

| Condition | Rendering |
|---|---|
| `smd` on `$PATH` | ANSI-styled terminal buffer via `smd` (colours, headings, code blocks) |
| `smd` absent | `nofile` buffer with `filetype=markdown` + `render-markdown.nvim` |

`smd` is optional. When absent the panel falls back to a `nofile` buffer with `filetype=markdown` (rendered by render-markdown.nvim if installed, otherwise plain text).

When smd is active: each page navigation runs `smd <tmpfile>` via `vim.fn.jobstart`
(no PTY — stdout is a pipe, so smd auto-selects `cat` rather than `less`).
The full ANSI output is collected via `stdout_buffered = true` then written to a
`nvim_open_term` channel buffer. Since no job is attached to the channel the user
always enters the buffer in Normal mode — no `<C-\><C-n>` required.

**Link navigation (smd path):** Before writing to the temp file, `preprocess_links_for_smd`
rewrites internal devenv links from `[text](devenv-foo.md)` to
`[text (→devenv-foo)](devenv-foo.md)`. smd still styles the link (underline/colour) and
hides the URL, but `(→devenv-foo)` survives in the rendered display text.
`follow_link` "Try 0" matches `%(→(devenv%-[^)]+)%)` on the current terminal line and
navigates directly — no fuzzy text matching needed.

**Link navigation (nofile path):** "Try 1" parses `[text](url)` markdown syntax directly
from the line (the raw markdown is displayed as-is via render-markdown).

### Behaviour

- **First open**: fetches the default page async via `curl`, displays it via smd or render-markdown
- **Close** (toggle off): closes the window; buffer and history are preserved
- **Re-open**: shows existing content; smd path creates a fresh terminal buffer per navigation
- **`:ALHelp <url>`**: accepts a full MS Learn URL or a bare slug; extracts the slug automatically
- Focus returns to the editing window automatically after the panel opens

### Keymaps inside the panel

| Key | Action |
|---|---|
| `<CR>` | Follow link — smd path: matches `(→devenv-slug)` in line; nofile path: parses `[text](url)` syntax |
| `u` / `<BS>` | Go back (history stack) |
| `r` | Reload current page |
| `t` | Open topic picker |
| `q` | Close panel |

### Topic list

35 curated topics covering language fundamentals, all object types, events, pages/UI, API/integration,
and testing. Displayed via `vim.ui.select`; selecting a topic fetches and replaces the panel content.

### URL resolution

`to_slug()` accepts:
- Full MS Learn URL — extracts the last path segment
- Relative `.md` filename (from markdown links) — strips the extension
- Bare `devenv-*` slug — used as-is

### Content processing

YAML front matter (`--- … ---`) and `[!INCLUDE [...](…)]` directives are stripped before display.

## Code Cop selector (`lua/al/cops.lua`)

`:ALSelectCops` / `<leader>ac` — pick which of the four AL code analyzers are active for the current project.

### The four cops

| Token | Name | Notes |
|---|---|---|
| `${CodeCop}` | CodeCop | General AL coding guidelines — always useful |
| `${PerTenantExtensionCop}` | PerTenantExtensionCop | Per-tenant extension rules |
| `${UICop}` | UICop | UI / control add-in rules |
| `${AppSourceCop}` | AppSourceCop | AppSource submission rules — strict, not needed for internal apps |

Default (no saved config): CodeCop + PerTenantExtensionCop + UICop. AppSourceCop is opt-in.

### Config persistence

Selection is saved to `<root>/.vscode/alnvim.json` as `{ "codeAnalyzers": [...] }`. The file can be committed alongside `launch.json` or git-ignored. Other keys in the file are preserved on write.

### Live apply

After the user confirms, `cops.apply()` re-sends `al/setActiveWorkspace` with the updated `codeAnalyzers` list — changes take effect immediately without restarting the LSP server.

### Picker variants

- **Telescope present**: multi-select picker (`<Tab>` to toggle, `<CR>` to apply).
- **No Telescope**: iterative `vim.ui.select` loop showing `[x]`/`[ ]` state with an Apply and Cancel option.

## AL Text Objects (`lua/al/textobj.lua`)

Buffer-local, loaded from `ftplugin/al.lua`.

| Keys | Mode | Selects |
|---|---|---|
| `af` / `if` | o, x | around / inside the procedure or trigger under cursor |
| `aF` / `iF` | o, x | around / inside the nearest begin/end (or case/end) block |

**`proc_bounds`** walks backward for a `procedure`/`trigger` line, then forward for the
`end;` at the same indentation level. A separate forward pass finds the `begin` line at
that same indent (after any `var` section) for the `if` variant.

**`block_bounds`** tracks depth by counting `begin`/`case` (+1) and `end` (−1), walking
backward to the owning `begin`/`case` then forward to its closing `end`.

## AL Object Wizard (`lua/al/wizard.lua`)

`:ALNewObject [dir]` / `<leader>an` walks through a `vim.ui.select` + `vim.ui.input` prompt
sequence to create a new AL object file, then opens it.

### Supported types (12)

| Type | ID | Extra prompts |
|---|---|---|
| Table | yes | DataClassification (select from 7 options) |
| TableExtension | yes | `extends`: picker of all tables (project + symbols) |
| Page | yes | PageType (select from 13 options), SourceTable (input) |
| PageExtension | yes | `extends`: picker of all pages (project + symbols) |
| Codeunit | yes | — |
| Report | yes | SourceTable (input) |
| Query | yes | SourceTable (input) |
| XmlPort | yes | — |
| Enum | yes | Extensible (true/false select) |
| EnumExtension | yes | `extends`: picker of all enums (project + symbols) |
| Interface | **no** | — |
| PermissionSet | yes | — |

### Prompt flow

1. `vim.ui.select` — pick object type
2. `vim.ui.input` for ID (pre-filled via `ids.M.next_id(root, type)` — skipped for Interface)
3. `vim.ui.input` for object name
4. Type-specific extra prompts (chained callbacks)
5. File written to `<root>/src/<obj_type>/`, opened in editor

Cancellation at any step (Esc / nil return) aborts cleanly with a WARN notify.

### Extends picker (extension types)

For TableExtension, PageExtension and EnumExtension the `extends` prompt uses
`vim.ui.select` populated by scanning the project + extracted symbol packages via
`explorer.M.build_search_dirs`. Falls back to a free-text input if no objects are found.

### File naming (CRS convention)

`<root>/src/<obj_type>/<id>.<SanitisedName>.<FileType>.al` e.g. `src/table/50100.My_Table.Table.al`.
Interface omits the ID: `src/interface/My_Interface.Interface.al`.
The target directory is created if absent. If the file already exists, an overwrite
confirmation is shown via `vim.ui.select`.

### ID suggestion

Uses `ids.M.next_id(root, obj_type)` which is a thin wrapper around the existing local helpers
`get_ranges` / `get_used_ids` / `free_ids` in `ids.lua`.

## AL File Organiser (`wizard.M.organise_file`)

A `BufWritePost` autocmd in `ftplugin/al.lua` automatically moves any saved AL file into
`<root>/src/<obj_type>/` if it isn't already there.

### Trigger

Fires on every `:w` of an AL buffer. Skips silently if:
- The file is not inside a project root (no `app.json` found)
- The file is already under `src/<type>/…` (correct location)
- The object type cannot be determined from the file content

### Detection

Reads the first 50 buffer lines looking for the AL object type keyword:
- Types with IDs: matches `^\s*<keyword>\s+\d+` (table, page, codeunit, etc.)
- Interface: matches `^\s*interface\s+["']` (no numeric ID)

### Move

Uses `vim.fn.rename` (atomic on the same filesystem) to move the file, then
`vim.api.nvim_buf_set_name` to update the buffer path in place. No buffer reload
required — the user continues editing at the new path transparently.

**Supported type folders:** `table`, `tableextension`, `page`, `pageextension`,
`pagecustomization`, `codeunit`, `report`, `reportextension`, `query`, `xmlport`,
`enum`, `enumextension`, `interface`, `permissionset`, `permissionsetextension`,
`profile`, `profileextension`, `controladdin`.

## `compile.lua` on_success callback

`M.compile(project_dir, extra_args, on_success)` — `on_success()` is called inside `vim.schedule` only when `exit_code == 0` and the quickfix list is empty. `publish.lua` uses this to chain upload after a clean build.

## Inspecting the AL extension protocol

When debugging LSP issues, search `~/.vscode/extensions/ms-dynamics-smb.al-*/dist/extension.js` (minified) for method names and payload shapes. Useful patterns:

```bash
# Find setActiveWorkspace payload structure
python3 -c "
with open('extension.js') as f: c = f.read()
idx = c.find('activeWorkspaceClosure')
print(c[max(0,idx-2000):idx+500])
"
```

Enable debug logging temporarily to capture the full JSON-RPC exchange:
```lua
vim.lsp.log.set_level(vim.log.levels.DEBUG)
-- log is at vim.lsp.get_log_path()
```

## Adding future features

- **DAP launch mode (done)**: `:ALLaunch` compiles with `alc` then calls `dap.run()` with `request = "launch"`. The adapter (EditorServices.Host) handles publishing to BC internally — VSCode never does a direct HTTP POST to `/dev/apps`. Direct HTTP publish (`application/octet-stream`) returns HTTP 415 for cloud environments because the cloud API does not expose that endpoint to external clients.

  **Critical adapter startup args** (from `extension.js` `DebugAdapterExecutable`):
  ```lua
  dap.adapters.al = {
    type    = "executable",
    command = host,
    args    = { "/startDebugging", "/projectRoot:" .. root },  -- REQUIRED
    options = {
      env = {
        DOTNET_ROOT             = "/usr/share/dotnet",
        DISPLAY                  = os.getenv("DISPLAY") or "",
        WAYLAND_DISPLAY          = os.getenv("WAYLAND_DISPLAY") or "",
        DBUS_SESSION_BUS_ADDRESS = os.getenv("DBUS_SESSION_BUS_ADDRESS") or "",
        XDG_RUNTIME_DIR          = os.getenv("XDG_RUNTIME_DIR") or "",
      },
    },
  }
  ```
  Without `/startDebugging` the binary starts in LSP mode and hangs waiting for an LSP `initialize` request. Without `/projectRoot` the adapter cannot locate the project. Display env vars are forwarded so the adapter subprocess can invoke `xdg-open` if needed.

  **breakOnError / breakOnRecordWrite must be booleans** (adapter 16.x+): The C# deserialiser is strict — sending the string `"All"` causes `Could not convert string to boolean`. `debug.lua` converts via `to_break_bool()`: `"All"`, `"ExcludeTry"`, `"ExcludeTemporary"` → `true`; `"None"` / `nil` → `false`.

  **launchBrowser**: Force `launchBrowser = false` in the DAP config — the adapter's `xdg-open` call fails on Linux. If `launch.json` has `launchBrowser = true`, open the URL from Lua using `conn.webclient_url(cfg)` after `dap.run()`.

  **WebClient URL**: `conn.webclient_url(cfg)` returns the correct URL for both cloud and on-prem:
  - Cloud: `https://businesscentral.dynamics.com/<tenant>/<env>`
  - On-prem: `http[s]://<server>/<serverInstance>/WebClient/?<ObjType>=<ObjId>&tenant=<tenant>`
- **Treesitter grammar**: No community grammar exists yet. Generate from `alsyntax.tmlanguage` with `tree-sitter generate`.
