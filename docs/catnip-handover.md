# ALNvim × Catnip — handover for the integration work

Date 2026-11-22. ALNvim `master` `97d818b`. Catnip config `~/.config/nvim` `94aa6c5` (+ uncommitted work).
Neovim `v0.13.0-dev-100`. AL tool `30.0.42`. Backend `al_agentic_lsp`.

This replaces `docs/catnip-ui-audit.md` (2026-11-16) as the working document. The audit's
inventory of windows is still correct for everything not named below; this document covers
what changed since, what is broken now, and what to build.

Every claim carries one of three labels:

- **[measured]** — run on this machine on 2026-11-22 (headless, real config or `-u NONE`).
- **[read]** — from reading the code; not run.
- **[unverified]** — a hypothesis; check before you build on it.

## 1. What you are asked to do

1. Make ALNvim's windows, prompts and output views behave as native Catnip views when Catnip
   is the host, and behave exactly as before when it is not. ALNvim is a public plugin;
   Catnip is one user's config.
2. Fix the completion ("intellisense") problems in section 5. The largest one is not about
   Catnip at all: the first completion of a session takes 6–9 seconds.

Rule for conflicts: **Catnip's behaviour wins.** Do not add features back that Catnip removed,
and do not change files under `~/.config/nvim` unless section 7 lists it as a request for the owner.

## 2. How Catnip handles windows — the contract

All of this is from `~/.config/nvim/lua/catnip/*.lua` and `lua/config/ui.lua`.

| Rule | Where | What it means for a plugin |
|---|---|---|
| A tab is a workspace. Each has its own directory (`:tcd`) and tab variables `catnip_kind`, `catnip_repo`, `catnip_root`. | `catnip_workspaces.lua:158-161` | Module-level singletons ("the build window", "the project") are wrong as soon as two AL projects are open. `:tabnew` inherits the tab directory **[measured]**. |
| Output is an **owned float**, never a split. `require('catnip.ui').output({ id, title, lines, focus })` returns a view: `open`, `close`, `append`, `set_lines`, `lines`, `edit_file`, `dispose`, `is_open`. One view per `id`. The buffer outlives the window (`bufhidden=hide`), `q`/`<Esc>` close, focus returns to the window that was current at open. | `catnip/ui.lua` | Closing a view must never stop the job that feeds it. |
| Source opened *from* a view is a **managed child tab**: `view:edit_file({ file, line, col })` hides the view, runs `:tabnew <file>`, sets `vim.t.catnip_child_editor`, and reopens the view with its cursor when that tab closes. | `catnip/ui.lua:118-182` | Never `:split` or `:edit` into "some window" from an output view. |
| Lists of locations are a **linked navigator**: `require('catnip.navigator').navigator({ id, title, items })`, items `{ file, line, col, severity = 'E'|'W', message }`. List on the left, read-only preview on the right, `<CR>` opens a managed child tab. Preview reads the file from disk; it does not load a buffer or start an LSP client. | `catnip/navigator.lua` | Quickfix + `:copen` is the non-Catnip fallback. |
| When the last listed buffer is deleted, Catnip opens the dashboard (global `BufDelete`). | `config/ui.lua:464` | Plugin scratch buffers must be unlisted. `_al_startup_.al` already is. |
| `:q` on the last file window does not exit: Catnip opens the dashboard beside it (global `QuitPre`), unless `vim.t.catnip_child_editor` is set. | `config/ui.lua:491` | Do not set that tab variable yourself; only Catnip's `edit_file` owns it. |
| `vim.ui.select` / `vim.ui.input` are **dressing.nvim** **[measured]**. Pickers Catnip opens itself are Snacks or fff. Telescope is installed but Catnip does not use it for its own UI. | `plugins.lua`, `config/ui.lua` | `vim.ui.*` calls already look right. Telescope pickers work but look foreign. |
| `:` is a Noice popup; Noice messages, notify, popupmenu and LSP views are **off**. | `catnip_noice.lua` | `vim.fn.inputlist()` and `vim.fn.input()` depend on the message area. Avoid them. |
| One global statusline (`laststatus=3`, `vim.o.statusline` set by `catnip_statusline.lua`). | `catnip_statusline.lua:49-51` | A window-local `statusline` replaces Catnip's for that window. |
| No format on save. Formatting is manual: `:Format` / `<leader>uf` (conform, LSP fallback for AL). | `catnip_formatter.lua` | ALNvim formats on save with no switch — see D6. |
| Normal-mode `<Tab>` / `<S-Tab>` are `<C-w>w` / `<C-w>W`. | `config/ui.lua` | Do not map `<Tab>` in normal mode in plugin buffers that sit beside editing windows. |
| Catnip registers no global `WinClosed` repair hook, and a view only watches its own window id. | `catnip/ui.lua:90`, `:160` | Same rule for ALNvim: scoped autocmds only (the audit's grep test still applies). |

## 3. What ALNvim does today

Three commits since the audit (`0ea0801`, `1f40de6`, `5187298`) wired Catnip into compile only:

- `compile.lua:302-331` `build_output_sink`: with `opts.catnip`, output goes to the Catnip view
  `alnvim.build.output`; `<CR>` on a diagnostic line calls `view:edit_file`.
- `:ALCompile` and `:ALCompileCatnip` both call `compile_catnip` (`plugin/al.lua:544-564`).
  `:ALCompileLegacy` is the old bottom split. `:ALBuildOutput` reopens the view.
  `:ALCatnipDiagnostics` opens the navigator on the last finished build (`catnip_diagnostics.lua`).

Everything else is as the audit describes: seven hand-built floats, the agent split, the diff
panel, six quickfix users, nine Telescope pickers.

## 4. Defects — fix these first

Ordered by how soon a user hits them.

### D1. Compiling from a second tab throws the user into the first tab **[measured]**

The build view is one view with one id. `View:open` (`catnip/ui.lua:77-84`) sees the view is
already open — in another tab — and calls `nvim_set_current_win` on it. Neovim switches tab.
Repro (`-u NONE`, Catnip on the rtp): open view in tab A, `:tabnew`, call `ui.output` with the
same id → current tab is A.

Fix in ALNvim (no Catnip change needed): before `ui.output(...)`, get the existing view with
`ui.get(id)`; if it is open and its window's tabpage is not the current one, `view:close()`
first. `close()` does not move focus when the view is not focused.

### D2. One build view for every project

`id = 'alnvim.build.output'` is shared, and each compile starts with `lines = {}`. Two builds
at once (two projects, or `:ALCompile` twice) interleave in one buffer, and the second wipes
the first's output while its job still runs. `M._catnip_build_view` and `M._catnip_last_qf`
are single module fields for the same reason.

Fix: key by root — id `alnvim.build:<root>`, and `M._builds[root] = { view, qf, job }`.
A second compile for a root whose job is still running should stop the old job
(`jobstop`, with the same generation guard `analyze_diagnostics` uses) before clearing the view.

### D3. `:ALCompile` warns on every build when Catnip is absent **[read]**

`compile.lua:327`: `AL: Catnip UI unavailable; using the legacy build panel`, level WARN, on
each compile, for every ALNvim user who is not this one. The default command of a public
plugin must not depend on a private config. Fixed by the host adapter (W1): detection is
silent and happens once.

### D4. Only `:ALCompile` uses the Catnip view **[read]**

`publish.lua:143`, `tests.lua:203`, `debug.lua:770` and `:807` call `compile.compile(root, nil, cb)`
without `opts.catnip`. So `:ALPublish`, `:ALRunTests` (when it has to build) and `:ALLaunch`
still open the bottom split — the exact layout change Catnip forbids — and then a second,
unrelated float from `altool.output_float`.

Fix: the *caller* must not choose the sink. `compile.compile` asks the host adapter. Remove
`opts.catnip` and `compile_catnip`.

### D5. AL windows lose the Catnip statusline **[measured]**

`ftplugin/al.lua:30-46` sets a window-local `statusline` on `BufEnter` of every AL buffer and
restores it on `BufLeave`. With `laststatus=3` the current window's value is the one drawn, so
in AL buffers the Catnip line (branch, version) is replaced by ALNvim's.

Fix: `setup({ statusline = true })`, default `true` (unchanged for other users). When `false`,
the ftplugin sets nothing. `require('al.status').get()` stays public so a host can embed it —
see request R1.

Related, same module: `status.lua` holds **one** `_s` table for the whole session. With two AL
projects in two tabs it shows whichever attached last. Key the state by root and let `get()`
resolve the root of the current buffer (cache per bufnr; `get()` runs on every redraw, keep the
250 ms string cache per root).

### D6. Format on save cannot be turned off **[read]**

`ftplugin/al.lua:132-141` formats in `BufWritePre` whenever the client can format. There is no
option. Catnip's formatter module states "Intentionally NO format_on_save".

Fix: `setup({ format_on_save = true })`, default `true`. Whether the Catnip config sets it to
`false` is the owner's decision (question Q1) — do not decide it in the plugin.

### D7. `:ALClaude` / `:ALPi` add a split every time **[read]**

`agent.lua:21`: `botright vsplit` + `enew` + terminal, no record of it. See W5.

### D8. The project picker uses `inputlist` **[read]**

`lsp.lua:100`. Under Catnip the message area is not where the user is looking, and the
handbook already records a headless start blocking on it (HANDBOOK SE-7). `get_root()` is
synchronous and has dozens of callers — **do not make it async in this pass.** Do this instead:

1. Memoise the answer per working directory (`vim.fn.getcwd()` is tab-aware, so this is
   per-workspace under Catnip). Ask once, not on every command.
2. Never prompt when `vim.v.vim_did_enter == 0` or there is no UI attached
   (`#vim.api.nvim_list_uis() == 0`); return nil.

### D9. Stale wording and duplicate commands

- `:ALCompileCatnip` is now identical to `:ALCompile`. Remove it once W1 lands.
- Comments at `compile.lua:565`, `:580` and `plugin/al.lua:561`, `:570` still say "opt-in" and
  "`:ALCompile` keeps its existing output panel". Both are false since `5187298`.
- `:ALBuildOutput`, `:ALCompileLegacy`, `:ALCatnipDiagnostics` are missing from the command list
  in `CLAUDE.md`, from `docs/cheatsheet.md` (line 325 still says "panel + quickfix") and from
  `actions.lua`. `tests/actions_spec.lua` checks actions against commands, not the reverse.

## 5. Work packages — window handling

### W1. Host adapter: `lua/al/host.lua` (do this first; everything else uses it)

One module knows that Catnip exists. No other module may `require('catnip.*')`.

```lua
-- setup({ ui = "auto" })   "auto" | "catnip" | "native"
local host = require("al.host")

host.name()                      -- "catnip" | "native"; detected once, silently
host.output({ id, title })       -- -> sink
host.locations({ id, title, items, qf_title })   -- navigator, or setqflist + copen
host.edit(file, line, col, { from = sink })      -- child tab, or best edit window
```

`sink` is the one output object for the whole plugin:

| Member | Catnip | Native |
|---|---|---|
| `sink.buf` | view buffer | scratch buffer, `bufhidden=hide` |
| `sink:append(lines)` | `view:append` | append + follow tail |
| `sink:clear()` | `view:set_lines({})` | same |
| `sink:open({ focus })` | D1 guard, then `view:open` | centred float (today's `output_float` geometry) |
| `sink:close()` / `sink:close_later(ms)` | `view:close` | close window, keep buffer |
| `sink:on_enter(fn)` | buffer-local `<CR>` → `fn(line)` | same |

Detection: `pcall(require, 'catnip.ui')` and check `type(ui.output) == 'function'`; cache the
result; `"catnip"` forced but missing → one WARN at `setup()`, not per command.

`host.edit` native path is the target-window logic now inside `open_build_win`
(`compile.lua:139-160`, `:193-210`) — move it, do not copy it.

### W2. Compile on the adapter

- `compile.compile` builds its sink from `host.output({ id = "alnvim.build:" .. root, ... })`.
  Delete `build_output_sink`, `compile_catnip`, `opts.catnip`.
- Native sink for compile keeps the bottom split (that is what non-Catnip users have), so
  `host.output` takes `native = "split"` for this one caller.
- After a failed build under Catnip, add a buffer-local `d` in the build view that opens the
  navigator on that build's diagnostics, and say so in the summary line
  (`── 3 error(s), 1 warning(s) ──  d: browse`). Today the user must know `:ALCatnipDiagnostics`.
- `buf_highlight` runs on `sink.buf`; it already works on the Catnip buffer.

### W3. Every other output float on the adapter

Replace, in this order (each is small once W1 exists):

| Site | Id | Notes |
|---|---|---|
| `altool.output_float` / `altool.run` (`altool.lua:199-227`) | `alnvim.tool:<root>` | Publish, symbols, tests, doc. Keep: live stream (AAD device code), stays open on failure, `close_later(2500)` on success. Gain: reopen last output — add `:ALToolOutput`. |
| `symbols.lua:174-223` status float | same sink | MCP route for old tools. |
| `install.lua:272-324` `make_window` | `alnvim.install` | Stop entering the float; today `:q` before completion loses the log. |
| `debug.lua:290-372` adapter output | `alnvim.dap` | Already has the right lifecycle; move last, or leave. |
| `connection.lua:177-230` az-login terminal | — | A terminal, not a text sink. Leave as is. |

`profile.lua` viewer and `preview.lua` are *interactive* floats, not output. Leave them floats;
only route their "open source" action through `host.edit` so it lands in a child tab under
Catnip instead of whatever window was current.

### W4. Location lists

`fixes.lua:511`, `:716`, `:744` and `tests.lua:325` call `setqflist` then `:copen`. Change to
`host.locations(...)`: it always fills quickfix (users expect `:cnext`), then opens the
navigator under Catnip or `:copen` natively. Generalise `catnip_diagnostics.to_items` into the
adapter; delete the module.

### W5. Agent terminal

Track `{ buf, win }` per `(command, root)`. Second call: window valid → focus it; buffer valid
→ show it again; else create. Under Catnip open it in a float sized like an output view;
natively keep `botright vsplit`. Closing the window never stops the job. Note Catnip already
has its own Claude terminal on `<leader>cc` (`config/ai.lua`); do not touch that.

### W6. Pickers (lowest priority)

Telescope pickers work under Catnip; they only look different. Do not rewrite them in this
pass. Two cheap steps:

- `setup({ picker = "auto" | "telescope" | "select" })`; `"select"` forces the existing
  `vim.ui.select` fallbacks so Catnip can have one look for the simple pickers
  (actions, wizard source-table, help topics).
- Export `require('al.actions').list()` → `{ name, command, key, desc }`. Catnip's palette keeps
  its own hard-coded table and has drifted (request R2).

Explorer, procedures, grep and diff need preview and extra keys; a Snacks backend is a
separate task and needs multi-select for cops / test methods / layout types.

### Tabs: remaining singletons to key by root **[read]**

`compile._build_win`, `explorer._last` / `_return_au`, `debug._current_root`, `profile._profile`
/ `_snapshot`, `status._s`. Check each: if two AL projects in two tabs can both reach it, key it
by root. `explorer._last` matters most — `:ALExplorerReopen` in tab B must not show tab A's list.

## 6. Completion review

### Measurements (project: 2 AL files, 5 symbol packages, Base Application 21)

| What | Result |
|---|---|
| `initialize` round trip | ~0.5 s |
| **First semantic request after start** (completion or hover) | **6.2–8.6 s**, the same after 0.5 s idle and after 20 s idle — the server loads symbols lazily, on demand |
| First completion *after* a warm-up hover | 1.0 s |
| Member completion (`Cust.`), warm | 37–58 ms, 330 items, 110 KB |
| Statement start, warm | 17–84 ms, 205 items, 75 KB |
| Type position (`Record ▏`), warm | 300–570 ms **every request**, 1725 items, 587 KB |
| Signature help / hover / formatting / documentSymbol | 49 / 20 / 100 / 15 ms |
| Result shape | bare array, no `isIncomplete`; documentation inline |
| `label` | an object on all 330 items — the label patch is still required |
| `filterText` | always quoted, also for bare names: label `Abs`, filterText `"Abs"` |
| `completionProvider` | `triggerCharacters = { ".", '"' }`, no `resolveProvider`; `completionItem/resolve` is never answered |
| `textDocumentSync.change` | `1` — **full document** on every change |
| Capabilities sent | Neovim defaults; `cmp_nvim_lsp` capabilities are not passed |
| `publishDiagnostics` | none in 20 s before the first request **[unverified after warm-up]** |

nvim-cmp settings in the Catnip config: `debounce 60`, `throttle 30`, `fetching_timeout 500`,
sources for AL = `nvim_lsp`, `luasnip`.

### C1. Warm the server on attach (the one that matters)

Today `agentic_lsp.on_attach` calls `status.set_lsp_ready()` at once
(`agentic_lsp.lua:206`), the statusline says "ready", and the user's first `.` waits 6–9 s.
cmp gives a source 500 ms before it draws without it, so the first menu shows snippets only
and the AL items arrive seconds later or seem never to come.

Do this:

1. In `on_attach`, once per client: `status.set_lsp_loading()`, then send one
   `textDocument/hover` followed by one `textDocument/completion` for the attached buffer, and
   discard both results. Hover alone left the first completion at 1.0 s **[measured]**.
2. `status.set_lsp_ready()` in the callback of the second request, or after a 30 s cap.
3. The `VimEnter` auto-start already starts a client on the `_al_startup_.al` anchor
   (`plugin/al.lua:934-975`). Warm from there too, so the load is over before a file is opened.
   **[unverified]** whether a request on that empty, not-on-disk document triggers the symbol
   load. Test it; if it does not, warm on the first real buffer.
4. `agentic_lsp.restart` (after a symbol download) goes through `M.start`, so it warms again.
   The startup poller (`startup.poll`) waits on `status.is_ready()` — it will now wait for the
   real thing, which is correct.

Acceptance: fresh Neovim, open an AL file, wait for "ready", type `Cust.` → the response to the
first user-triggered completion arrives in under 300 ms.

### C2. One completion patch, and fix `filterText` in it

The `client.request` wrapper exists twice: `plugin/al.lua:263-290` and
`agentic_lsp.lua:172-199`. Move it to `lsp.patch_completion(client)` and call it from both.

In the same loop, when `label` is not quoted and `filterText` is the label in quotes, drop the
quotes. cmp scores `Ab` against `Abs` at 21.6 and against `"Abs"` at 13.2 **[measured]**: every
bare identifier loses its prefix bonus, while really quoted names (`"Sales Header"`) need the
user to type the quote to get it. Leave `filterText` alone when the label itself is quoted.

Add a spec with a recorded response (label object, quoted filterText, bare array and
`{ items = … }` list forms).

### C3. Object-ID completion as a completion source

Two problems with `ftplugin/al.lua:276-285`:

- It binds insert-mode `<C-Space>` buffer-locally. nvim-cmp also maps `<C-Space>`
  (`cmp.mapping.complete()`), and cmp re-maps buffer-locally over an existing buffer map,
  keeping it only as a *fallback* that `complete()` never calls **[read]** (`cmp/utils/keymap.lua:127-133`).
  One of the two is dead in AL buffers depending on load order. Confirm which in a real
  terminal; either answer is a bug.
- `completefunc` is synchronous, so the first call per type runs `rg` over the project on the
  main thread (`ids.lua` caches after that).

Fix: register a cmp source `al_ids` when nvim-cmp is present. `is_available` → filetype `al`;
`complete` → only when the line is `<object type> <digits?>`, items from `free_ids` in `ids.lua` (a local today — export it), the
`rg` pass through `explorer.rg_async`. The ID then appears in the normal menu with no key.
Keep `completefunc` + `<C-x><C-u>` for users without cmp, and stop mapping `<C-Space>` when cmp
is loaded.

### C4. Stop configuring the user's cmp from the ftplugin

`ftplugin/al.lua:327-339` calls `cmp.setup.buffer({ sources = … })` on every `FileType al`
(the ftplugin re-runs on `:e`). It overrides whatever the user configured for AL — including
the `al_ids` source from C3 and Catnip's own `cmp.setup.filetype("al", …)`, which is the same
list today. Move it to `setup()`, run once, behind `completion = { configure_cmp = true }`,
and include `al_ids`.

### C5. Pass completion capabilities

Neither `vim.lsp.start` call passes `capabilities`. Add `setup({ capabilities = nil })`; when
nil, use `cmp_nvim_lsp.default_capabilities()` if it loads, else `blink.cmp`'s
`get_lsp_capabilities()` if it loads, else Neovim's default. Apply to both backends.
Low impact on tool 30.0.42 — it sends no commit characters or preselect and has no resolve —
so this is correctness for later tool versions, not a speed-up. Do it last.

### C6. Things measured and deliberately left alone

- **Full-document sync.** The server asks for it; the client cannot negotiate incremental.
  Neovim debounces `didChange` 150 ms and flushes before any request, so results are correct.
  Add a passthrough `setup({ lsp_flags = {} })` → `flags` and change nothing by default.
  If typing lags in a very large object, measure before raising `debounce_text_changes`.
- **587 KB type lists.** No `isIncomplete`, so cmp asks once per word and filters locally.
  Nothing to do client-side. A 570 ms answer misses cmp's 500 ms `fetching_timeout`, so the
  menu opens with snippets and fills in — request R3.
- **Semantic tokens** are switched off in `on_init`. Keep; `syntax/al.vim` owns highlighting.
- **Resolve.** Not advertised, so cmp never asks. `renameProvider` is already cleared for the
  same "advertised or assumed but never answered" reason.
- **Signature help** works (49 ms) on Neovim's default insert `<C-s>`. No auto-popup; that is a
  host choice.

### C7. Ghost text (small)

`ghost.lua` checks `cmp.visible()` only when a suggestion *arrives*. If the cmp menu opens
afterwards, both show. Subscribe to `cmp.event:on('menu_opened', …)` when cmp is present and
clear the ghost. Also the request sends the whole file above the cursor as the prefix
(`ghost.lua` `request`); cap it (last ~150 lines) — prompt evaluation time on the model server
grows with it **[unverified, not timed]**.

## 7. Requests for the Catnip owner (not for the coder to change)

| | Request | Why |
|---|---|---|
| R1 | Embed `%{v:lua.require('al.status').get()}` in `catnip_statusline.lua`, and set `statusline = false` in `require("al").setup{}` once D5 ships. | AL state back on the one global line. |
| R2 | `al_command_palette.lua` lists `ALGoto` and `ALInlineHints`, which do not exist (the real one is `ALInlayHints`), and has no group for commands added since (`ALBuildOutput`, `ALCatnipDiagnostics`, `ALChangeNamespace` fall into "Other AL Commands"). Read `require('al.actions').list()` after W6. | One source of truth. |
| R3 | For AL only, raise cmp `performance.fetching_timeout` to ~1000 ms. | Type-position lists take 300–570 ms. |
| R4 | `View:open` in `catnip/ui.lua`: when the view is open in another tabpage, close it there and open here instead of focusing it. | Root cause of D1; ALNvim works around it. |
| Q1 | Should AL format on save under Catnip? | D6 adds the switch; the value is yours. |
| Q2 | Agent terminal under Catnip: float or split? | W5 assumes float. |

## 8. Tests

House rule (`CLAUDE.md`, Tests): each new test must fail against the code before the fix.
`tests/run.sh` runs `-u NONE`, so Catnip is not there. Add a fake:
`tests/fakes/catnip/ui.lua` and `navigator.lua` implementing the surface in section 2 and
recording every call (record all calls, not the last one). One fake per file.

| Test | Proves |
|---|---|
| host: `ui="auto"` without Catnip → native, zero notifications | D3 |
| host: `ui="catnip"` without Catnip → exactly one WARN at setup | W1 |
| compile from tab B while the root's view is open in tab A → current tab is still B | D1 |
| two roots compile → two view ids; neither `set_lines({})` hits the other | D2 |
| `publish`, `tests`, `debug.launch` compile paths create no split under the fake host | D4 |
| ftplugin with `statusline=false` leaves `vim.wo.statusline` empty; with `true` sets it | D5 |
| `format_on_save=false` → no `textDocument/formatting` request on `:w` | D6 |
| second `agent.claude()` → same buffer, window count unchanged | D7 |
| `get_root` with several `app.json` and no UI → returns nil, does not block | D8 |
| completion patch: label object, quoted filterText on bare label, both result shapes | C2 |
| warm-up: `is_ready()` false until the second warm-up response; true after; true after 30 s cap | C1 |
| `al_ids` source: offered only on object-header lines; no sync `rg` (stub `systemlist` and fail if called) | C3 |
| existing: nothing in `lua/al` registers an unscoped `BufDelete`/`WinClosed`/`QuitPre` | contract |

Catnip's own lifecycle tests live in `~/.config/nvim/tests/` (`catnip_output_editor.lua`,
`catnip_main_editor.lua`, `dashboard_return.lua`). Run them after W2 with the dev checkout
loaded (`ALNVIM_DEV` is set on this machine) — they are the real-host check the fake cannot give.

Manual check list under the real config, one pass at the end:

1. Dashboard → `a` → `ALCompile`: view opens; `<CR>` on an error → child tab; `:q` → view back,
   cursor kept; `q` → dashboard focused.
2. Two workspace tabs, two AL projects: compile in each; no tab jump; each `:ALBuildOutput`
   shows its own build.
3. `:ALPublish`: no bottom split at any point.
4. Open a file from `:ALExplorer` when it is the only listed buffer, then `<leader>q`: the
   dashboard hook and explorer return-on-close both fire. Decide what should win and write it
   down — **[unverified]**, not tested here.
5. Fresh start, wait for "ready", type `Cust.`: items at once.

## 9. Order of work

1. C1, C2 — completion; independent of Catnip, largest effect.
2. W1, then D1–D4 through W2.
3. D5, D6, D8, D9 — options and clean-up.
4. W3, W4, W5.
5. C3, C4, C5, C7.
6. W6.

Each numbered group is one PR. Update `CLAUDE.md` (module table: `host.lua`; command list;
the Compiling section's description of the panel) and `docs/handbook.md` Status and Sharp
edges in the PR that changes the behaviour.

## 10. How the numbers were taken

Headless Neovim against a copy of `~/Documents/ALTest`:

- Real config: `cd <project> && nvim --headless -c 'luafile probe.lua'` — capabilities,
  cmp config, statusline, `vim.ui.select` owner, warm completion timings (through ALNvim's patch).
- `-u NONE` with a client started by hand on `al launchlspserver <root> --packagecachepath …` —
  cold-start timing with 0.5 s and 20 s idle before the first request, raw `label` shape,
  and the Catnip view tab test with `~/.config/nvim` on the runtimepath.

Timing each request: `client:request(method, params, cb, 0)` with `vim.uv.hrtime()` around it
and `vim.wait` on the callback. Three server processes ran at once for the cold-start runs, so
the absolute cold figure is inflated; 6.2 s was the least loaded. Re-measure on a real project
(Base Application 27, more packages) before quoting it.
