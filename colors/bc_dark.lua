-- Business Central Dark colorscheme for Neovim
-- Converted from ms-dynamics-smb.al extension themes/BC_dark.json
vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") then vim.cmd("syntax reset") end
vim.g.colors_name = "bc_dark"
vim.o.background  = "dark"

local hi = vim.api.nvim_set_hl

-- ── Editor chrome ─────────────────────────────────────────────────────────────
hi(0, "Normal",       { bg = "#1E1E1E", fg = "#D4D4D4" })
hi(0, "NormalFloat",  { bg = "#252526", fg = "#D4D4D4" })
hi(0, "FloatBorder",  { bg = "#252526", fg = "#00747F" })
hi(0, "SignColumn",   { bg = "#1E1E1E" })
hi(0, "LineNr",       { fg = "#858585" })
hi(0, "CursorLineNr", { fg = "#C6C6C6", bold = true })
hi(0, "CursorLine",   { bg = "#2A2A2A" })
hi(0, "ColorColumn",  { bg = "#2A2A2A" })
hi(0, "Visual",       { bg = "#093B42" })
hi(0, "VisualNOS",    { bg = "#093B42" })
hi(0, "Search",       { bg = "#005760", fg = "#D4D4D4" })
hi(0, "IncSearch",    { bg = "#00747F", fg = "#FFFFFF" })
hi(0, "CurSearch",    { bg = "#00747F", fg = "#FFFFFF" })
hi(0, "MatchParen",   { bg = "#005760", bold = true })
hi(0, "NonText",      { fg = "#404040" })
hi(0, "Whitespace",   { fg = "#404040" })
hi(0, "VertSplit",    { fg = "#444444", bg = "#1E1E1E" })
hi(0, "WinSeparator", { fg = "#444444", bg = "#1E1E1E" })
hi(0, "Folded",       { bg = "#252526", fg = "#808080" })
hi(0, "FoldColumn",   { bg = "#1E1E1E", fg = "#808080" })
hi(0, "EndOfBuffer",  { fg = "#404040" })

-- ── Status / tab line ─────────────────────────────────────────────────────────
hi(0, "StatusLine",   { bg = "#00747F", fg = "#FFFFFF" })
hi(0, "StatusLineNC", { bg = "#3C3C3C", fg = "#A6A6A6" })
hi(0, "TabLine",      { bg = "#2D2D2D", fg = "#A6A6A6" })
hi(0, "TabLineSel",   { bg = "#1E1E1E", fg = "#D4D4D4", bold = true })
hi(0, "TabLineFill",  { bg = "#2D2D2D" })
hi(0, "WildMenu",     { bg = "#005760", fg = "#FFFFFF" })

-- ── Popup menu ────────────────────────────────────────────────────────────────
hi(0, "Pmenu",        { bg = "#252526", fg = "#D4D4D4" })
hi(0, "PmenuSel",     { bg = "#005760", fg = "#FFFFFF" })
hi(0, "PmenuSbar",    { bg = "#3C3C3C" })
hi(0, "PmenuThumb",   { bg = "#00747F" })

-- ── Syntax — mapped from BC_dark.json tokenColors ────────────────────────────
-- comment → #64707D
hi(0, "Comment",      { fg = "#64707D", italic = true })
-- string → #CE9178
hi(0, "String",       { fg = "#CE9178" })
hi(0, "Character",    { fg = "#CE9178" })
-- constant.language → #62CFD7  (true/false/nil)
hi(0, "Boolean",      { fg = "#62CFD7" })
hi(0, "Constant",     { fg = "#62CFD7" })
-- constant.numeric → #9FD89F
hi(0, "Number",       { fg = "#9FD89F" })
hi(0, "Float",        { fg = "#9FD89F" })
-- keyword → #00747F (teal)
hi(0, "Keyword",      { fg = "#00747F" })
hi(0, "Conditional",  { fg = "#00747F" })
hi(0, "Repeat",       { fg = "#00747F" })
hi(0, "Statement",    { fg = "#00747F" })
hi(0, "Label",        { fg = "#00747F" })
hi(0, "Operator",     { fg = "#00747F" })
hi(0, "Exception",    { fg = "#00747F" })
-- entity.name.function → #DCDCAA
hi(0, "Function",     { fg = "#DCDCAA" })
-- entity.name.type / class / enum / interface → #4EC9B0
hi(0, "Type",         { fg = "#4EC9B0" })
hi(0, "Structure",    { fg = "#4EC9B0" })
hi(0, "Typedef",      { fg = "#4EC9B0" })
hi(0, "StorageClass", { fg = "#00747F" })
-- variable → #9CDCFE
hi(0, "Identifier",   { fg = "#9CDCFE" })
-- preprocessor / attributes
hi(0, "PreProc",      { fg = "#C586C0" })
hi(0, "Include",      { fg = "#C586C0" })
hi(0, "Define",       { fg = "#C586C0" })
hi(0, "Macro",        { fg = "#C586C0" })
-- special
hi(0, "Special",      { fg = "#D7BA7D" })
hi(0, "SpecialChar",  { fg = "#D7BA7D" })
hi(0, "Delimiter",    { fg = "#D4D4D4" })
hi(0, "SpecialComment", { fg = "#56616C" })
hi(0, "Debug",        { fg = "#D13438" })
hi(0, "Underlined",   { underline = true })
hi(0, "Ignore",       { fg = "#404040" })
hi(0, "Error",        { fg = "#D13438", bold = true })
hi(0, "Todo",         { fg = "#1E1E1E", bg = "#00747F", bold = true })

-- ── Diagnostics ───────────────────────────────────────────────────────────────
hi(0, "DiagnosticError",       { fg = "#D13438" })
hi(0, "DiagnosticWarn",        { fg = "#CCA700" })
hi(0, "DiagnosticInfo",        { fg = "#62CFD7" })
hi(0, "DiagnosticHint",        { fg = "#56616C" })
hi(0, "DiagnosticUnderlineError", { undercurl = true, sp = "#D13438" })
hi(0, "DiagnosticUnderlineWarn",  { undercurl = true, sp = "#CCA700" })

-- ── Git / diff ────────────────────────────────────────────────────────────────
hi(0, "DiffAdd",    { bg = "#1a3a1a" })
hi(0, "DiffDelete", { bg = "#3a1a1a" })
hi(0, "DiffChange", { bg = "#1a2a3a" })
hi(0, "DiffText",   { bg = "#005760" })
hi(0, "Added",      { fg = "#9FD89F" })
hi(0, "Removed",    { fg = "#D13438" })
hi(0, "Changed",    { fg = "#00747F" })

-- ── LSP ───────────────────────────────────────────────────────────────────────
hi(0, "LspReferenceText",  { bg = "#005760" })
hi(0, "LspReferenceRead",  { bg = "#005760" })
hi(0, "LspReferenceWrite", { bg = "#005760" })
