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
| `lua/al/compile.lua` | Async `alc` compiler integration with quickfix output |
| `lua/al/symbols.lua` | Download `.app` symbol packages from BC dev endpoint |
| `lua/al/publish.lua` | Compile then POST `.app` to BC dev endpoint |
| `lua/al/debug.lua` | Snapshot debugging (BC API) + nvim-dap adapter config |
| `lua/al/snippets.lua` | Loads `snippets/al.json` into LuaSnip via the VSCode loader |
| `ftdetect/al.vim` | Sets `filetype=al` for `*.al` and `*.dal` files |
| `ftplugin/al.lua` | Buffer-local settings and keymaps for AL files |
| `syntax/al.vim` | Vim syntax highlighting derived from `alsyntax.tmlanguage` |
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
| `al/gotodefinition` | client → server | Go to definition (server has `definitionProvider = false`). |

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

The server has `definitionProvider = false` — `textDocument/definition` returns nothing. `gd` must be overridden to use `al/gotodefinition`. Use `vim.schedule` to defer the keymap so it wins over the user's generic `LspAttach` handler:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client or client.name ~= "al_language_server" then return end
    vim.schedule(function()
      vim.keymap.set("n", "gd", function()
        local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
        client:request("al/gotodefinition", { textDocumentPositionParams = params },
          function(err, result)
            if err or not result then return end
            vim.lsp.util.jump_to_location(result, client.offset_encoding)
          end, args.buf)
      end, { buffer = args.buf, desc = "AL: Go to definition" })
    end)
  end,
})
```

### Pending requests

`al/setActiveWorkspace` and `al/gotodefinition` always appear as "pending" in `client.requests` — the server responds via `window/logMessage` notifications rather than proper JSON-RPC responses. This is expected behaviour.

## Compiling

`:ALCompile [dir]` runs `alc /project:<root> /packagecachepath:<root>/.alpackages` asynchronously and populates the quickfix list. The project root is the nearest directory containing `app.json`. Extra flags are passed via `config.alc_extra_args`.

Error line format parsed from alc output:
```
/path/to/file.al(line,col): error|warning ALxxxx: message
```

## Snippets

Snippets use LuaSnip's `from_vscode` loader pointed at this plugin directory. `package.json` declares `contributes.snippets[0].language = "al"`. Adding new snippets: edit `snippets/al.json` and call `:ALReloadSnippets`.

## Keymaps (AL buffers only)

| Key | Action |
|---|---|
| `<leader>ab` | `:ALCompile` |
| `<leader>ap` | `:ALPublish` |
| `<leader>aP` | `:ALPublishOnly` |
| `<leader>as` | `:ALDownloadSymbols` |
| `<leader>ao` | `:ALOpenAppJson` |
| `<leader>al` | `:ALOpenLaunchJson` |
| `<leader>aq` | Open quickfix list |
| `<leader>ads` | `:ALSnapshotStart` |
| `<leader>adf` | `:ALSnapshotFinish` |
| `<leader>add` | `:ALDebugSetup` |
| `gd` | AL go to definition (via `al/gotodefinition`) |
| `<C-o>` | Navigate back from `gd` (standard Neovim jumplist) |

Global LSP keymaps (`K`, `gr`, `<leader>rn`, etc.) are set by the user's `init.lua` via the `LspAttach` autocmd and apply to AL buffers too.

## User commands

| Command | Description |
|---|---|
| `:ALCompile [dir]` | Compile project with `alc` |
| `:ALPublish [dir]` | Compile then publish `.app` to BC |
| `:ALPublishOnly [dir]` | Publish existing `.app` to BC (skip compile) |
| `:ALDownloadSymbols [dir]` | Download `.app` symbol packages from BC |
| `:ALSnapshotStart` | Start a BC snapshot debugging session |
| `:ALSnapshotFinish` | Download snapshot file and open it |
| `:ALDebugSetup` | Configure nvim-dap for AL live attach |
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
- `Microsoft / Application` — version from `app.application`
- `Microsoft / System Application` — version from `app.application`

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

## `compile.lua` on_success callback

`M.compile(root, extra_args, on_success)` — `on_success()` is called inside `vim.schedule` only when exit_code == 0 and the quickfix list is empty. `publish.lua` uses this to chain upload after a clean build.

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

- **DAP launch mode**: Map the `launch` request type (publish-and-debug). The adapter init options are not publicly documented; inspect the DAP exchange with `:DapLog`.
- **Treesitter grammar**: No community grammar exists yet. Generate from `alsyntax.tmlanguage` with `tree-sitter generate`.
- **AL Explorer**: Telescope extension that greps for AL object declarations and presents them as a picker.
