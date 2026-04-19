# ALNvim Cheatsheet

> **Leader key = `Space`**
> AL-specific keys are only active in `.al` / `.dal` buffers.
> LSP keys require the AL language server to be attached (`:ALInfo` to verify).

---

## AL: Build & Deploy

| Key | Action |
|---|---|
| `<Space>ab` | Compile project with `alc` → errors in quickfix |
| `<Space>ap` | Compile **then** publish `.app` to Business Central |
| `<Space>aP` | Publish existing `.app` to BC (skip compile) |
| `<Space>as` | Download symbol packages from BC into `.alpackages/` |

---

## AL: Project Files

| Key | Action |
|---|---|
| `<Space>ao` | Open `app.json` |
| `<Space>al` | Open `.vscode/launch.json` |
| `<Space>aq` | Open quickfix list (build errors/warnings) |

---

## AL: Debugging

| Key | Action |
|---|---|
| `<Space>ads` | Start BC snapshot debug session |
| `<Space>adf` | Finish snapshot — download trace file to `.snapshots/` |
| `<Space>add` | Configure nvim-dap for AL live attach |

After `:ALDebugSetup`, use standard nvim-dap keys (install nvim-dap separately):

| Key | Action |
|---|---|
| `<F5>` | Continue / start (`:DapContinue`) |
| `<F10>` | Step over |
| `<F11>` | Step into |
| `<F12>` | Step out |
| `<Space>db` | Toggle breakpoint (`:DapToggleBreakpoint`) |

> Map the nvim-dap keys yourself in `init.lua` — they are not set by default.

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
| `gi` | Go to implementation |
| `<Space>rn` | Rename symbol |
| `<Space>ca` | Code action (fix suggestion) |
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

## AI Assistant (Claude Code)

| Key | Mode | Action |
|---|---|---|
| `<Space>cc` | n | Toggle Claude Code terminal (40% split) |

Chat persists when hidden — toggle reopens same session.

---

## File Navigation

| Key | Action |
|---|---|
| `<Space>f` | Find files (mini.pick) |
| `<Space>h` | Search help |
| `<Space>e` | Open file browser (Oil) |
| `;` | Dashboard |

---

## Editor Essentials

| Key | Action |
|---|---|
| `<Space>w` | Save file |
| `<Space>q` | Quit |
| `<Space>o` | Save + source current Lua file |
| `<Space>y` | Yank to system clipboard |
| `<Space>d` | Delete to system clipboard |

---

## Commands Quick Reference

| Command | Description |
|---|---|
| `:ALCompile` | Compile with alc |
| `:ALPublish` | Compile + publish to BC |
| `:ALPublishOnly` | Publish without recompiling |
| `:ALDownloadSymbols` | Fetch `.alpackages` from BC |
| `:ALSnapshotStart` | Begin snapshot debug session |
| `:ALSnapshotFinish` | End session + download trace |
| `:ALDebugSetup` | Wire nvim-dap for AL attach |
| `:ALOpenAppJson` | Edit `app.json` |
| `:ALOpenLaunchJson` | Edit `.vscode/launch.json` |
| `:ALReloadSnippets` | Reload LuaSnip snippets |
| `:ALInfo` | Show project + extension info |
