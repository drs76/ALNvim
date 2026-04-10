-- Business Central Yellow colorscheme for Neovim
-- Background: #010704  Foreground: #efefef
-- Comments: #04b925  AL keywords/operators: #f6fa16
vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then vim.cmd("syntax reset") end
vim.g.colors_name = "bc_yellow"
vim.o.background  = "dark"

local hi = vim.api.nvim_set_hl

-- ── Editor chrome ─────────────────────────────────────────────────────────────
hi(0, "Normal",       { bg = "#010704", fg = "#efefef" })
hi(0, "NormalFloat",  { bg = "#0d0d0d", fg = "#efefef" })
hi(0, "FloatBorder",  { bg = "#0d0d0d", fg = "#04b925" })
hi(0, "SignColumn",   { bg = "#010704" })
hi(0, "LineNr",       { fg = "#555555" })
hi(0, "CursorLineNr", { fg = "#3ce775", bold = true })
hi(0, "CursorLine",   { bg = "#0d1a0d" })
hi(0, "ColorColumn",  { bg = "#0d1a0d" })
hi(0, "Visual",       { bg = "#1a3a1a" })
hi(0, "VisualNOS",    { bg = "#1a3a1a" })
hi(0, "Search",       { bg = "#2a3a00", fg = "#efefef" })
hi(0, "IncSearch",    { bg = "#3ce775", fg = "#010704" })
hi(0, "CurSearch",    { bg = "#3ce775", fg = "#010704" })
hi(0, "MatchParen",   { bg = "#2a3a00", bold = true })
hi(0, "NonText",      { fg = "#333333" })
hi(0, "Whitespace",   { fg = "#333333" })
hi(0, "VertSplit",    { fg = "#333333", bg = "#010704" })
hi(0, "WinSeparator", { fg = "#333333", bg = "#010704" })
hi(0, "Folded",       { bg = "#0d0d0d", fg = "#555555" })
hi(0, "FoldColumn",   { bg = "#010704", fg = "#555555" })
hi(0, "EndOfBuffer",  { fg = "#222222" })

-- ── Status / tab line ─────────────────────────────────────────────────────────
hi(0, "StatusLine",   { bg = "#0b0b0b", fg = "#4ed705" })
hi(0, "StatusLineNC", { bg = "#0b0b0b", fg = "#555555" })
hi(0, "TabLine",      { bg = "#0b0b0b", fg = "#555555" })
hi(0, "TabLineSel",   { bg = "#010704", fg = "#efefef", bold = true })
hi(0, "TabLineFill",  { bg = "#0b0b0b" })
hi(0, "WildMenu",     { bg = "#1a3a1a", fg = "#efefef" })

-- ── Popup menu ────────────────────────────────────────────────────────────────
hi(0, "Pmenu",        { bg = "#0d0d0d", fg = "#efefef" })
hi(0, "PmenuSel",     { bg = "#1a3a1a", fg = "#efefef" })
hi(0, "PmenuSbar",    { bg = "#222222" })
hi(0, "PmenuThumb",   { bg = "#04b925" })

-- ── Syntax ────────────────────────────────────────────────────────────────────
hi(0, "Comment",      { fg = "#04b925", italic = true })
hi(0, "String",       { fg = "#efefef" })
hi(0, "Character",    { fg = "#efefef" })
hi(0, "Number",       { fg = "#efefef" })
hi(0, "Float",        { fg = "#efefef" })
hi(0, "Function",     { fg = "#efefef" })
hi(0, "Identifier",   { fg = "#efefef" })
hi(0, "Type",         { fg = "#f6fa16" })  -- keyword.other.builtintypes (Record, Integer, Text…)
hi(0, "Structure",    { fg = "#f6fa16" })  -- keyword.other.applicationobject (codeunit, table, page…)
hi(0, "Typedef",      { fg = "#f6fa16" })
-- AL keywords, operators, object types, constants → #f6fa16 (yellow)
hi(0, "Keyword",      { fg = "#f6fa16" })
hi(0, "Conditional",  { fg = "#f6fa16" })
hi(0, "Repeat",       { fg = "#f6fa16" })
hi(0, "Statement",    { fg = "#f6fa16" })
hi(0, "Label",        { fg = "#f6fa16" })
hi(0, "Operator",     { fg = "#f6fa16" })
hi(0, "Exception",    { fg = "#f6fa16" })
hi(0, "StorageClass", { fg = "#f6fa16" })
hi(0, "Boolean",      { fg = "#f6fa16" })
hi(0, "Constant",     { fg = "#f6fa16" })
-- preprocessor / attributes
hi(0, "PreProc",      { fg = "#f6fa16" })
hi(0, "Include",      { fg = "#f6fa16" })
hi(0, "Define",       { fg = "#f6fa16" })
hi(0, "Macro",        { fg = "#f6fa16" })
-- special / punctuation
hi(0, "Special",      { fg = "#efefef" })
hi(0, "SpecialChar",  { fg = "#efefef" })
hi(0, "Delimiter",    { fg = "#efefef" })
hi(0, "SpecialComment", { fg = "#04b925" })
hi(0, "Debug",        { fg = "#ea0408" })
hi(0, "Underlined",   { underline = true })
hi(0, "Ignore",       { fg = "#333333" })
hi(0, "Error",        { fg = "#ea0408", bold = true })
hi(0, "Todo",         { fg = "#010704", bg = "#04b925", bold = true })

-- ── Diagnostics ───────────────────────────────────────────────────────────────
hi(0, "DiagnosticError",          { fg = "#ea0408" })
hi(0, "DiagnosticWarn",           { fg = "#f0c722" })
hi(0, "DiagnosticInfo",           { fg = "#04b925" })
hi(0, "DiagnosticHint",           { fg = "#555555" })
hi(0, "DiagnosticUnnecessary",    { fg = "#ce8349" })
hi(0, "DiagnosticUnderlineError", { undercurl = true, sp = "#ea0408" })
hi(0, "DiagnosticUnderlineWarn",  { undercurl = true, sp = "#f0c722" })

-- ── Git / diff ────────────────────────────────────────────────────────────────
hi(0, "DiffAdd",    { bg = "#0a2a0a" })
hi(0, "DiffDelete", { bg = "#2a0a0a" })
hi(0, "DiffChange", { bg = "#0a1a2a" })
hi(0, "DiffText",   { bg = "#1a3a1a" })
hi(0, "Added",      { fg = "#04b925" })
hi(0, "Removed",    { fg = "#ea0408" })
hi(0, "Changed",    { fg = "#f6fa16" })

-- ── LSP ───────────────────────────────────────────────────────────────────────
hi(0, "LspReferenceText",  { bg = "#1a3a1a" })
hi(0, "LspReferenceRead",  { bg = "#1a3a1a" })
hi(0, "LspReferenceWrite", { bg = "#1a3a1a" })
