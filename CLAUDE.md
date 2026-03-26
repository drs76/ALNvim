# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ALNvim is a Neovim plugin (Lua) that adds Business Central AL language support, loaded via the Neovim 0.11+ built-in `vim.pack.add()` API. It integrates the AL language server shipped with the MS AL VSCode extension at `~/.vscode/extensions/ms-dynamics-smb.al-16.3.2065053`.

## Structure

| Path | Purpose |
|---|---|
| `plugin/al.lua` | Auto-loaded entry point: registers LSP config, creates user commands |
| `lua/al/init.lua` | `require('al').setup(opts)` – user-facing configuration |
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

## AL Toolchain paths (hard-coded)

```
~/.vscode/extensions/ms-dynamics-smb.al-16.3.2065053/
  bin/linux/Microsoft.Dynamics.Nav.EditorServices.Host   ← LSP server (stdio)
  bin/linux/alc                                          ← AL compiler
  bin/linux/altool                                       ← AL tools helper
  bin/linux/aldoc                                        ← AL documentation generator
```

Both `alc` and the LSP host are shipped without the exec bit. `plugin/al.lua` sets it at startup via `vim.uv.fs_chmod`.

## LSP

The AL language server speaks standard LSP over stdio. It is registered via:

```lua
vim.lsp.config("al_language_server", { cmd = { lsp_bin }, filetypes = { "al" }, root_markers = { "app.json" } })
vim.lsp.enable("al_language_server")
```

If the server fails to attach, check `vim.lsp.get_clients()` and `:checkhealth lsp`. The server may need additional `initializationOptions` – inspect `~/.vscode/extensions/ms-dynamics-smb.al-16.3.2065053/dist/extension.js` (minified) for hints.

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
| `<leader>ao` | `:ALOpenAppJson` |
| `<leader>al` | `:ALOpenLaunchJson` |
| `<leader>aq` | Open quickfix list |

Global LSP keymaps (`gd`, `gr`, `K`, `<leader>rn`, etc.) are set by the user's `init.lua` via the `LspAttach` autocmd and apply to AL buffers too.

## User commands

| Command | Description |
|---|---|
| `:ALCompile [dir]` | Compile project with `alc` |
| `:ALPublish [dir]` | Compile (future: deploy to BC) |
| `:ALOpenAppJson` | Edit project `app.json` |
| `:ALOpenLaunchJson` | Edit `.vscode/launch.json` |
| `:ALReloadSnippets` | Reload LuaSnip snippets |
| `:ALInfo` | Show project and extension info |

## AL project layout expected

```
<project>/
  app.json          ← manifest (publisher, name, version, dependencies)
  .alpackages/      ← downloaded symbol packages (.app files)
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

For AAD/Entra: `AL_BC_TOKEN` env var or interactive prompt.

## `compile.lua` on_success callback

`M.compile(root, extra_args, on_success)` — `on_success()` is called inside `vim.schedule` only when exit_code == 0 and the quickfix list is empty. `publish.lua` uses this to chain upload after a clean build.

## Adding future features

- **DAP launch mode**: Map the `launch` request type (publish-and-debug). The adapter init options are not publicly documented; inspect the DAP exchange with `:DapLog`.
- **Treesitter grammar**: No community grammar exists yet. Generate from `alsyntax.tmlanguage` with `tree-sitter generate`.
- **AL Explorer**: Telescope extension that greps for AL object declarations and presents them as a picker.
