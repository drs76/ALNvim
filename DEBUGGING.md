# AL Live Debugging with nvim-dap

## Prerequisites

- [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed and on the pack path
- A valid `.vscode/launch.json` in your project root
- MS AL extension installed (`~/.vscode/extensions/ms-dynamics-smb.al-*`)

---

## Quick Start

1. Open any `.al` file in your project
2. Press `<F9>` to set a breakpoint on an executable line
3. Press `<F5>` (or `<leader>adl`) to compile, publish and attach
4. Perform the action in the BC client that triggers your code
5. Neovim will pause at the breakpoint — use the step keys to navigate

---

## Keymaps (AL buffers only)

| Key | Action |
|---|---|
| `<F5>` / `<leader>adl` | Compile → publish → attach debugger |
| `<F9>` / `<leader>adb` | Toggle breakpoint on current line |
| `<leader>adB` | Set conditional breakpoint (prompts for AL expression) |
| `<F10>` | Step over |
| `<F11>` | Step into |
| `<F12>` | Step out |
| `<leader>adc` | Continue (resume execution) |
| `<leader>adq` | Terminate debug session |
| `<leader>adi` | Hover inspect — show value of variable under cursor |
| `<leader>add` | Reconfigure DAP adapter without re-launching |

---

## Cloud (Sandbox/Production) vs On-Prem

### Cloud

`launch.json` must have `environmentType: "Sandbox"` or `"Production"`.

ALNvim sends a DAP **launch** request — the adapter handles publishing to BC internally.
For cloud environments the HTTP publish endpoint is not exposed to external clients (returns HTTP 415).

**OAuth2 device login flow:** On first launch (or after token expiry) the adapter initiates
a device code login:

1. A `WARN` notification appears: `AL: Device login — code XXXX-XXXX copied to clipboard`
2. The Microsoft login page opens automatically in your browser
3. Paste the code from your clipboard (it was copied automatically)
4. Complete sign-in — the adapter resumes automatically
5. The BC web client opens with the debug context attached

After auth the adapter fires `al/openUri` with the real BC URL (includes debug session context).
The browser is opened from Lua — no `xdg-open` involvement from the adapter itself.

### On-Prem

`launch.json` has no `environmentType`, or `environmentType: "OnPrem"`.

ALNvim compiles with `alc`, POSTs the `.app` directly to the BC dev endpoint, then sends
a DAP **attach** request. The BC web client is opened from `conn.webclient_url(cfg)` if
`launchBrowser: true` is set in `launch.json`.

---

## Setting Breakpoints

- Breakpoints must be on **executable lines** — not blank lines, `begin`, `end`, `var`, comments
- Good lines: assignments, procedure calls, `if` conditions, `Message(...)`, field accesses
- The adapter does not support column breakpoints — ALNvim strips the column field automatically
- Conditional breakpoints accept AL expressions: `Rec."No." = 'C00010'`, `Amount > 1000`

---

## Inspecting Variables

| Method | How |
|---|---|
| Hover (`<leader>adi`) | Float showing the value of the identifier under cursor |
| `:DapToggleRepl` | Opens a REPL — evaluate AL expressions in the current scope |
| nvim-dap-ui | Install [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui) for a full variables/watch/call stack panel |

---

## launch.json Reference

```jsonc
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "al",
      "request": "launch",
      "name": "BC Sandbox",
      "environmentType": "Sandbox",
      "environmentName": "your-env-name",
      "primaryTenantDomain": "yourtenant.onmicrosoft.com",
      "authentication": "MicrosoftEntraID",
      "breakOnError": "All",          // "All" | "ExcludeTry" | "ExcludeTemporary" | "None"
      "breakOnNext": "WebClient",     // "WebClient" | "WebServiceClient" | "Background"
      "breakOnRecordWrite": "None",
      "launchBrowser": true,          // ALNvim reads this; adapter's own open is suppressed
      "startupObjectType": "Page",
      "startupObjectId": 22,
      "schemaUpdateMode": "synchronize"
    },
    {
      "type": "al",
      "request": "attach",
      "name": "BC On-Prem",
      "server": "http://myserver",
      "serverInstance": "BC",
      "authentication": "UserPassword",
      "al_username": "admin",         // ALNvim extension — not standard AL
      "al_password": "password",      // ALNvim extension — not standard AL
      "tenant": "default",
      "breakOnError": "All",
      "breakOnNext": "WebClient",
      "launchBrowser": true
    }
  ]
}
```

**Notes:**
- `breakOnError: "All"` / `"ExcludeTry"` / `"ExcludeTemporary"` are all treated as `true` by the adapter (16.x+); `"None"` → `false`. ALNvim patches the JSON before launch.
- `launchBrowser: true` in launch.json → ALNvim opens the URL from Lua. The adapter's own `xdg-open` call is suppressed by a no-op stub.
- `al_username` / `al_password` are ALNvim-specific fields for on-prem credential storage. Alternatively use `AL_BC_USERNAME` / `AL_BC_PASSWORD` env vars.

---

## Troubleshooting

### "Debug adapter didn't respond"

The adapter takes 15–30s on first launch (downloading symbols, authenticating).
ALNvim sets `initialize_timeout_sec = 30`. If it still times out, your network may be slow —
check `:DapLog` for the last message received.

### "Specified argument was out of the range of valid values (Parameter 'index')"

The adapter couldn't find the source file in its indexed project. Causes:
- Breakpoint is in a file outside the project root (e.g. a symbol stub)
- Session was started before the project finished indexing — wait for `ready` in the statusline, then re-launch

### "Session still initializing" when calling DapContinue

The adapter hasn't sent `event_initialized` yet. Usually means it's waiting for:
- OAuth2 device login (check for the device code notification)
- Symbol download / project index (watch the statusline)

### Breakpoint not hit

- Make sure the code path is actually reached in the BC client
- Verify `breakOnNext` matches the client type: `"WebClient"` for browser, `"WebServiceClient"` for API calls, `"Background"` for job queue
- Check `breakOnError` is not `"None"` if you expect an error to trigger the break

### Checking the raw DAP exchange

```vim
:lua vim.fn.setenv("NVIM_DAP_LOG_LEVEL", "TRACE")
:DapSetLogLevel TRACE
```

Log path:
```vim
:lua print(vim.fn.stdpath("cache") .. "/nvim/dap.log")
```

### Restarting a stale session

```vim
:lua require("dap").terminate()
:lua require("dap").run_last()
```

Or just `<F5>` again — ALNvim re-registers the adapter on every launch.

---

## Snapshot Debugging (no nvim-dap required)

BC records a full server-side execution trace.

1. `<leader>ads` — start snapshot session (configure `breakOnNext` in launch.json first)
2. Perform the action in the BC client
3. `<leader>adf` — download the `.snapshots` file and open it in Neovim

Snapshot files open in the BC Snapshot Debugger (requires the AL extension).
