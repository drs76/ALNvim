# ALNvim Cheatsheet

> **Leader key = `Space`**
> AL-specific keys are only active in `.al` / `.dal` buffers.
> LSP keys require the AL language server to be attached (`:ALInfo` to verify).

---

## AL: Build & Deploy

| Key | Action |
|---|---|
| `<Space>aa` | **ALActions** — picker of every AL command with descriptions (global, any buffer) |
| `<Space>ab` | Compile project with `al compile` → output panel + quickfix |
| `<Space>ap` | Compile **then** publish `.app` to Business Central (`al publishapp`) |
| `<Space>aP` | Publish existing `.app` to BC (skip compile) |
| `<Space>as` | Download symbol packages into `.alpackages/` (server or NuGet/AppSource) |
| `<Space>aA` | Silent analyze pass — refresh diagnostics without the panel |
| `<Space>at` | Run tests — pick a test codeunit (from the built `.app`) then methods. Pass/fail → quickfix |
| `<Space>aT` | Run the `[Test]` procedure under the cursor |
| `<Space>ar` | Run object — open this page/report/table in the BC web client |
| `<Space>ax` | Build reference docs with `al doc build` into `.aldoc/` |

---

## AL: Project Files & Config

| Key | Action |
|---|---|
| `<Space>ao` | Open `app.json` |
| `<Space>al` | Open `.vscode/launch.json` |
| `<Space>aq` | Open quickfix list (build errors/warnings) |
| `<Space>ad` | Diagnostics for the current buffer (Telescope or loclist) |
| `<Space>aC` | Select active code cops (`.vscode/alnvim.json`) |
| `<Space>aB` | Select browser for BC launch |
| `<Space>am` / `<Space>aM` | Write / show the AL MCP entry in `<project>/.claude/settings.json` |
| `<Space>aN` | Add namespace to all source files |
| `<Space>acu` | Add missing `using` statements (server-only) |

---

## AL: Create & Navigate

| Key | Action |
|---|---|
| `<Space>an` | New object wizard (18 types) |
| `<Space>aR` | Generate permission set for all project objects |
| `<Space>av` | Preview page layout |
| `<Space>aw` / `<Space>aW` | Report Layout Wizard / open existing layout |
| `<Space>ae` | AL Explorer — objects (project + symbol packages); `<C-s>` sort, `<C-f>` grep |
| `<Space>af` | AL Explorer — procedures in the current file |
| `<Space>ag` | Live grep across all AL files |
| `<Space>aD` | Git diff explorer |
| `<Space>aF` | Find related — event publisher / handler function / table trigger |
| `<Space>ah` / `<Space>aH` / `<Space>aG` | MS Learn AL docs / help topic picker / AL guidelines |
| `gd` / `<C-o>` | Go to definition (symbol packages too) / jump back |
| `grn` / `<Space>rn` | Rename quoted identifier project-wide |
| `af` / `if` | Text object: around / inside procedure or trigger |
| `aF` / `iF` | Text object: around / inside `begin…end` block |
| `<C-Space>` (insert) | Object ID completion on an object-type line |

---

## AL: Code Actions & Refactoring

| Key | Action |
|---|---|
| `<Space>aca` | All code actions — Lua actions + server actions when supported (n/v) |
| `<Space>acf` | Quick fixes for the cursor line — Create procedure (AL0118/AL0132), remove unused var (AA0137) / assignment (AA0206), add `()` (AA0008) |
| `<Space>acr` | Refactor actions: extract, Validate/Evaluate, publishers, promote… (n/v) |
| `<Space>acl` | Extract string to Label (`:ALExtractLockedLabel` for a locked one) |
| `<Space>ace` | Extract selection to local procedure (v) |
| `<Space>acs` | Create user snippet from selection (v) |
| `<Space>acx` | Fix cops — apply every AA0137/AA0206/AA0008 fix project-wide |
| `<Space>acE` | Option field under cursor → new enum object |
| `<Space>acF` / `<Space>acn` | Fix all / organise namespaces — server-only (not on the agentic LSP) |

---

## AL: Debugging & Profiling

| Key | Action |
|---|---|
| `<F5>` / `<Space>adl` | Compile, publish and attach the debugger |
| `<Space>ads` / `<Space>adf` | Start / finish BC snapshot debug session (curl route) |
| `<Space>adS` / `<Space>adF` | Arm / collect snapshot debugging via `al launchsnapshotmcpproxy` |
| `<Space>adp` | Arm CPU profiling on a BC session id (`al launchprofilingmcpproxy`) |
| `<Space>adP` | Collect profiles → `.profiles/<ts>/*.alcpuprofile`, open hot-function viewer |
| `<Space>ado` | Open newest `.alcpuprofile` (viewer: `<CR>` jumps to source, `q` closes) |
| `<Space>add` | Configure nvim-dap for AL |
| `<Space>adX` | Close all debug windows, return to editing |

**nvim-dap keys** (when nvim-dap is installed):

| Key | Action |
|---|---|
| `<F9>` / `<Space>adb` | Toggle breakpoint |
| `<Space>adB` | Conditional breakpoint |
| `<F10>` / `<F12>` | Step over |
| `<F11>` | Step into |
| `<Space>adc` | Continue |
| `<Space>adq` | Terminate session |
| `<Space>adi` | Inspect variable under cursor |

---

## AL: AI

| Key | Action |
|---|---|
| `<Space>ai` | Claude Code in a terminal split at the project root (`:ALClaude`) |
| `<Space>ak` | Pi agent in a terminal split (`:ALPi`) |
| `<Space>aI` | Toggle inline ghost completions (Ollama FIM); `<M-l>` accepts |

---

## Quickfix Navigation  *(build errors)*

| Key | Action |
|---|---|
| `<Space>aq` | Open quickfix window |
| `:cn` | Jump to next error |
| `:cp` | Jump to previous error |
| `:cc N` | Jump to error number N |
| `:cfirst` | Jump to first error |
| `:clast` | Jump to last error |
| `<C-w>q` | Close quickfix window |

---

## LSP  *(active in any AL buffer once server attaches)*

| Key | Action |
|---|---|
| `K` | Hover — show type signature / docs |
| `gd` | Go to definition |
| `gr` | Find all references |
| `<Space>rn` / `grn` | Rename (quoted identifiers project-wide) |
| `<Space>aca` | AL code actions — see "Code Actions & Refactoring" above |
| `:ALInlayHints` | Toggle inlay hints (only when the server advertises them. Tool 30.0.42 does not) |
| `<Space>D` | Open diagnostic details float |
| `[d` | Jump to previous diagnostic |
| `]d` | Jump to next diagnostic |
| `<Space>lf` | Format document |

---

## Completion  *(insert mode)*

| Key | Action |
|---|---|
| `<C-Space>` | Trigger completion manually |
| `<Tab>` | Select next item / expand snippet / jump to next tabstop |
| `<S-Tab>` | Select previous item / jump to previous tabstop |
| `<CR>` | Confirm selected item |
| `<C-e>` | Dismiss completion menu |
| `<C-f>` | Scroll documentation down |
| `<C-b>` | Scroll documentation up |

---

## Snippets  *(type prefix in insert mode, then `<Tab>` to expand)*

Loaded from the AL extension's own snippet files, then ALNvim's (`terror`,
`tmessage`, `tconfirm`, `tfindset`, `tsetrange`, `ton*` triggers, `thttpclient`,
`tjsonparse`), then yours (`:ALCreateSnippet`) — a later file wins on the same
prefix. The MS snippets below need the extension installed. It also ships
`treportext`, `tpagecust`, `tprofile`, `tpermissionset`, `tentitlement`,
`tcontroladdin` and more.

### Object templates

| Prefix | Object |
|---|---|
| `ttable` | Table (with fields, keys, DataClassification) |
| `ttableext` | Table extension |
| `tpage` | Page (layout, area, group, actions) |
| `tpageext` | Page extension |
| `tcodeunit` | Codeunit with OnRun |
| `treport` | Report (dataset, dataitem, requestpage) |
| `tquery` | Query with elements |
| `tenum` | Enum with two values |
| `tenumext` | Enum extension |
| `tinterface` | Interface |

### Fields & page controls

| Prefix | Expands to |
|---|---|
| `tfield` | Table field definition |
| `tpagefield` | Page field with ApplicationArea + ToolTip |

### Procedures & triggers

| Prefix | Expands to |
|---|---|
| `tprocedure` | Procedure with var block |
| `ttrigger` | Trigger skeleton |
| `tonaftergetrecord` | `OnAfterGetRecord` trigger |
| `toninsert` | `OnInsertRecord` trigger |
| `tonmodify` | `OnModifyRecord` trigger |
| `tondelete` | `OnDeleteRecord` trigger |
| `tonvalidate` | `OnValidate` field trigger |

### Control flow

| Prefix | Expands to |
|---|---|
| `tif` | `if … then begin … end;` |
| `tifelse` | `if … then begin … end else begin … end;` |
| `tcaseof` | `case … of … end;` |
| `tcaseelse` | `case … of … else … end;` |
| `tfor` | `for … := … to … do begin … end;` |
| `tforeach` | `foreach … in … do begin … end;` |
| `twhile` | `while … do begin … end;` |
| `trepeat` | `repeat … until …;` |
| `tfindset` | `if Rec.FindSet() then repeat … until Rec.Next() = 0;` |
| `tsetrange` | `Rec.SetRange(Field, From, To);` |
| `twithdo` | `with … do begin … end;` |

### Events

| Prefix | Expands to |
|---|---|
| `teventsub` | `[EventSubscriber(…)]` + local procedure |
| `teventint` | `[IntegrationEvent(…)]` |
| `teventbus` | `[BusinessEvent(…)]` |
| `teventinternal` | `[InternalEvent(…)]` |
| `teventexternal` | `[ExternalBusinessEvent(…)]` |

### Dialogs & errors

| Prefix | Expands to |
|---|---|
| `terror` | `error('… %1', Var);` |
| `tmessage` | `Message('… %1', Var);` |
| `tconfirm` | `if not Confirm(…) then exit;` |
| `tassert` | `asserterror …` + error check |

### HTTP & JSON

| Prefix | Expands to |
|---|---|
| `thttpclient` | `HttpClient` GET skeleton with response check |
| `tjsonparse` | `JsonObject.ReadFrom` + `Get` + `AsValue` |

---

## Folding  *(AL uses `#region` / `#endregion`)*

| Key | Action |
|---|---|
| `za` | Toggle fold under cursor |
| `zo` | Open fold |
| `zc` | Close fold |
| `zR` | Open **all** folds in buffer |
| `zM` | Close **all** folds in buffer |
| `zj` / `zk` | Jump to next / previous fold |

---

## File Navigation

| Key | Action |
|---|---|
| `<Space>f` | Find files (fff, falls back to Snacks picker) |
| `<Space>sg` | Live grep |
| `<Space>sr` | Recent files |
| `<Space>h` | Search help |
| `<Space>e` | File browser — **mini.files** (Miller columns, floating) |
| `<Space>E` | File browser — Snacks sidebar |
| `;` | Dashboard |

---

## mini.files  *(`<Space>e`)*

Miller-column browser: parent on the left, current in the middle, **preview on the
right**. The preview follows the cursor but is not focused — nothing in it is
selectable until you move into it.

| Key | Action |
|---|---|
| `l` | Go **in** — focus the right column / open file |
| `h` | Go **out** — back to the left column |
| `L` | Go in **and close** the explorer (files only) |
| `H` | Go out plus |
| `q` / `<Esc>` | Close |
| `g?` | Show all mappings |

> There is **no `<CR>` mapping** — mini.files navigates with `h` / `l` only.
> This is the usual surprise coming from tree-style explorers.

**File operations are buffer edits, not commands.** Rename by editing the line,
`dd` to delete, `p` to move — then press `=` to apply. Nothing touches disk until
`=`, and deletes go to trash (`permanent_delete = false`), so a mistaken `dd` +
`=` is recoverable.

---

## Editor Essentials

| Key | Action |
|---|---|
| `<Space>w` | Save file |
| `<Space>q` | Close **buffer** (`:bdelete`) — not quit |
| `<Space>o` | Save + source current Lua file |
| `<Space>y` | Yank to system clipboard |
| `<Space>d` | Delete to system clipboard |

---

## Commands Quick Reference

Every `:AL*` command registered by `plugin/al.lua` (and `lua/al/agent.lua`). `[dir]` = optional project root.

| Command | Description |
|---|---|
| `:ALActions` | Actions picker — every command below with a description |
| `:ALInfo` | Extension, tool, LSP backend, inlay-hint support, project root and probing paths |
| `:ALUpdate` | Fast-forward this ALNvim checkout from `origin` — only on a clean `master`/`main`; never switches branch; no-op with a warning when `ALNVIM_DEV` is set |
| `:ALInstallExtension` / `:ALUpdateExtension` | Install / update the MS AL VS Code extension (VSIX) |
| `:ALInstallDotnetTool` | Install or update the AL dotnet tool |
| `:ALNewProject` | New project from the built-in Hello World or an extension template (Agent, Copilot, …) |
| `:ALCompile [dir]` | Compile with `al compile` → panel + quickfix |
| `:ALAnalyze` | Silent compile pass → diagnostics only |
| `:ALPublish [dir]` | Compile + publish to BC (`al publishapp`) |
| `:ALPublishOnly [dir]` | Publish without recompiling |
| `:ALDownloadSymbols [dir]` | Download symbols (picker: server or global) |
| `:ALDownloadSymbolsGlobal [dir]` | Download symbols from NuGet/AppSource only |
| `:ALSetNuGetFeeds [dir]` | Custom public NuGet feeds for global download (tool 30+) |
| `:ALLaunch [dir]` | Compile, publish and attach the debugger (F5) |
| `:ALDebugSetup` | Wire nvim-dap for AL |
| `:ALDapOutput` / `:ALDapClose` | Show adapter output / close all debug windows |
| `:ALSnapshotStart` / `:ALSnapshotFinish` | Snapshot debug session via the dev API (curl) |
| `:ALSnapshotCapture [dir]` / `:ALSnapshotCollect [dir]` | Snapshot debugging through `al launchsnapshotmcpproxy` |
| `:ALProfileCapture [dir]` | Arm a profiling schedule on a BC session (prompts for session id and window) |
| `:ALProfileCollect [dir]` | Stop it, save `.alcpuprofile`s under `.profiles/`, open the viewer |
| `:ALProfileOpen [file]` | Hot-function viewer (self/total ms per frame. Default newest profile) |
| `:ALRunTests[!] [dir]` | `al runtests --raw` for a picked codeunit/methods (`!` = test under cursor); compiles first when no `.app` |
| `:ALListTests [dir]` | Test codeunits and methods in the built `.app` (`al listtests --appfile`) |
| `:ALDoc [dir]` | `al doc build` → `<root>/.aldoc` |
| `:ALRunObject` | Open the object declared in the buffer in the web client |
| `:ALOpenAppJson` / `:ALOpenLaunchJson` | Edit `app.json` / `.vscode/launch.json` |
| `:ALSelectCops` / `:ALSelectBrowser` | Code cop picker / browser picker (`.vscode/alnvim.json`) |
| `:ALMcpSetup` / `:ALMcpRemove` / `:ALMcpStatus [dir]` | AL MCP server entry in `<project>/.claude/settings.json` |
| `:ALClaude` / `:ALPi` | AI agent in a terminal split at the project root (`:ALOllamaChat` = alias of `:ALClaude`) |
| `:ALGhostToggle` | Toggle Ollama ghost completions |
| `:ALInlayHints` | Toggle LSP inlay hints for this buffer |
| `:ALReindex` | Re-send `al/setActiveWorkspace` (EditorServices) |
| `:ALClearCredentials` | Forget session-cached BC credentials |
| `:ALNewObject [dir]` | Object wizard — 18 types incl. report/permission-set extensions, profile, page customization, control add-in, entitlement |
| `:ALGeneratePermissionSet [dir]` | Scan objects → `.PermissionSet.al` |
| `:ALNextId` | Notify the next free object IDs for the type on the current line |
| `:ALAddNamespace [dir]` | Add `namespace` to every source file |
| `:ALChangeNamespace [old new]` | Move the project's namespaces from `old` to `new` (prefix): `namespace`, `using`, qualified references |
| `:ALAddUsings` | Add missing `using` statements (server-only) |
| `:ALPreviewPage` | Preview page layout |
| `:ALReportLayout` / `:ALOpenLayout` | Report Layout Wizard / open existing layout |
| `:ALExplorer [dir]` / `:ALExplorerReopen` / `:ALExplorerProcs` | Object list / reopen from cache / procedures in file |
| `:ALSearch [dir]` | Live grep across AL files |
| `:ALDiff [dir]` | Git diff explorer |
| `:ALRenameObject` | Rename quoted identifier project-wide |
| `:ALCodeAction [kind]` | Code-action picker (`refactor`, `quickfix`, `source`, `navigate`). Takes a range |
| `:ALFixCops [dir]` | Analyze, then apply all AA0137/AA0206/AA0008 fixes bottom-up per file. Buffers edited, not written |
| `:ALRefactorToEnum [extensible]` | Option field under cursor → new enum object (`ids.next_id`), field retyped `Enum "Name"` |
| `:ALFindRelated` | Publisher / handler / table trigger for the cursor line → quickfix (jumps when there is one hit) |
| `:ALRefactorValidate` / `:ALRefactorEvaluate` | `X := Y;` → `Validate(X, Y);` / `Evaluate(X, Y);` (range) |
| `:ALExtractLabel` / `:ALExtractLockedLabel` | String under cursor → Label variable (locked variant adds `Locked = true`) |
| `:ALExtractProcedure` | Visual selection → new local procedure |
| `:ALMakeVarGlobal` | Move local variable under cursor to the global var block |
| `:ALAddPublishers` | Add OnBefore/OnAfter IntegrationEvent publishers to the current procedure |
| `:ALPromoteAction` | Add `actionref` for the action under cursor to `area(Promoted)` |
| `:ALCreateHandler` | Stub a missing test handler named in `[HandlerFunctions]` |
| `:ALCreateSnippet` | Save visual selection as a user snippet |
| `:ALReloadSnippets` | Re-merge extension + ALNvim + user snippets |
| `:ALHelp [url]` / `:ALHelpTopics` / `:ALGuidelines` | MS Learn docs / topic picker / alguidelines.dev |
