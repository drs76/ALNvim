-- Business Central Dark colorscheme for Neovim
-- Derived from the official VS Code "Business Central Dark" theme
-- shipped with ms-dynamics-smb.al extension (themes/BC_dark.json).
--
-- Key palette:
--   Background   #1E1E1E   Foreground    #D4D4D4
--   Teal (brand) #00747F   Light teal    #62CFD7
--   Selection    #093B42   Search hi     #005760
--   Comments     #64707D   Strings       #CE9178
--   Keywords     #00747F   Functions     #DCDCAA
--   Types        #4EC9B0   Variables     #9CDCFE
--   Numbers      #9FD89F   Constants     #62CFD7
--   Error        #D13438

vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then vim.cmd("syntax reset") end
vim.g.colors_name = "bc_dark"
vim.o.background  = "dark"

local hi = vim.api.nvim_set_hl

-- ── Editor chrome ─────────────────────────────────────────────────────────────
hi(0, "Normal",       { bg = "#1E1E1E", fg = "#D4D4D4" })
hi(0, "NormalFloat",  { bg = "#252526", fg = "#D4D4D4" })
hi(0, "FloatBorder",  { bg = "#252526", fg = "#00747F" })
hi(0, "SignColumn",   { bg = "#1E1E1E" })
hi(0, "LineNr",       { fg = "#404040" })
hi(0, "CursorLineNr", { fg = "#00747F", bold = true })
hi(0, "CursorLine",   { bg = "#252526" })
hi(0, "ColorColumn",  { bg = "#252526" })
hi(0, "Visual",       { bg = "#093B42" })
hi(0, "VisualNOS",    { bg = "#003A40" })
hi(0, "Search",       { bg = "#005760", fg = "#D4D4D4" })
hi(0, "IncSearch",    { bg = "#00747F", fg = "#FFFFFF" })
hi(0, "CurSearch",    { bg = "#00747F", fg = "#FFFFFF" })
hi(0, "MatchParen",   { bg = "#005760", bold = true })
hi(0, "NonText",      { fg = "#404040" })
hi(0, "Whitespace",   { fg = "#404040" })
hi(0, "VertSplit",    { fg = "#404040", bg = "#1E1E1E" })
hi(0, "WinSeparator", { fg = "#404040", bg = "#1E1E1E" })
hi(0, "Folded",       { bg = "#252526", fg = "#56616C" })
hi(0, "FoldColumn",   { bg = "#1E1E1E", fg = "#56616C" })
hi(0, "EndOfBuffer",  { fg = "#2A2A2A" })

-- ── Status / tab line ─────────────────────────────────────────────────────────
hi(0, "StatusLine",   { bg = "#00747F", fg = "#FFFFFF" })
hi(0, "StatusLineNC", { bg = "#252526", fg = "#A6A6A6" })
hi(0, "TabLine",      { bg = "#252526", fg = "#A6A6A6" })
hi(0, "TabLineSel",   { bg = "#1E1E1E", fg = "#D4D4D4", bold = true })
hi(0, "TabLineFill",  { bg = "#252526" })
hi(0, "WildMenu",     { bg = "#005760", fg = "#D4D4D4" })

-- ── Popup / completion menu ───────────────────────────────────────────────────
hi(0, "Pmenu",        { bg = "#252526", fg = "#D4D4D4" })
hi(0, "PmenuSel",     { bg = "#005760", fg = "#D4D4D4" })
hi(0, "PmenuSbar",    { bg = "#404040" })
hi(0, "PmenuThumb",   { bg = "#00747F" })

-- ── Syntax ────────────────────────────────────────────────────────────────────
hi(0, "Comment",        { fg = "#64707D", italic = true })   -- neutral gray

hi(0, "String",         { fg = "#CE9178" })  -- orange
hi(0, "Character",      { fg = "#CE9178" })

hi(0, "Number",         { fg = "#9FD89F" })  -- soft green
hi(0, "Float",          { fg = "#9FD89F" })

hi(0, "Function",       { fg = "#DCDCAA" })  -- yellow (entity.name.function)
hi(0, "Identifier",     { fg = "#9CDCFE" })  -- light blue (variable)

hi(0, "Type",           { fg = "#4EC9B0" })  -- aqua (entity.name.type / built-in types)
hi(0, "Structure",      { fg = "#4EC9B0" })  -- aqua (object types: codeunit, table, page…)
hi(0, "Typedef",        { fg = "#4EC9B0" })

-- Keywords, control flow, operators → teal
hi(0, "Keyword",        { fg = "#00747F" })
hi(0, "Conditional",    { fg = "#00747F" })
hi(0, "Repeat",         { fg = "#00747F" })
hi(0, "Statement",      { fg = "#00747F" })
hi(0, "Label",          { fg = "#00747F" })
hi(0, "Operator",       { fg = "#00747F" })
hi(0, "Exception",      { fg = "#00747F" })
hi(0, "StorageClass",   { fg = "#00747F" })
hi(0, "PreProc",        { fg = "#00747F" })
hi(0, "Include",        { fg = "#00747F" })
hi(0, "Define",         { fg = "#00747F" })
hi(0, "Macro",          { fg = "#00747F" })

-- Language constants → light teal (constant.language)
hi(0, "Boolean",        { fg = "#62CFD7" })
hi(0, "Constant",       { fg = "#62CFD7" })

-- Special / punctuation
hi(0, "Special",        { fg = "#D4D4D4" })
hi(0, "SpecialChar",    { fg = "#CE9178" })
hi(0, "Delimiter",      { fg = "#D4D4D4" })
hi(0, "SpecialComment", { fg = "#56616C" })
hi(0, "Debug",          { fg = "#D13438" })
hi(0, "Underlined",     { underline = true })
hi(0, "Ignore",         { fg = "#404040" })
hi(0, "Error",          { fg = "#D13438", bold = true })
hi(0, "Todo",           { fg = "#1E1E1E", bg = "#00747F", bold = true })

-- ── Diagnostics ───────────────────────────────────────────────────────────────
hi(0, "DiagnosticError",          { fg = "#D13438" })
hi(0, "DiagnosticWarn",           { fg = "#CCA700" })
hi(0, "DiagnosticInfo",           { fg = "#00747F" })
hi(0, "DiagnosticHint",           { fg = "#56616C" })
hi(0, "DiagnosticUnnecessary",    { fg = "#56616C" })
hi(0, "DiagnosticUnderlineError", { undercurl = true, sp = "#D13438" })
hi(0, "DiagnosticUnderlineWarn",  { undercurl = true, sp = "#CCA700" })

-- ── Git / diff ────────────────────────────────────────────────────────────────
hi(0, "DiffAdd",    { bg = "#0A2A12" })
hi(0, "DiffDelete", { bg = "#2A0A0A" })
hi(0, "DiffChange", { bg = "#093B42" })
hi(0, "DiffText",   { bg = "#005760" })
hi(0, "Added",      { fg = "#9FD89F" })
hi(0, "Removed",    { fg = "#D13438" })
hi(0, "Changed",    { fg = "#00747F" })

-- ── LSP ───────────────────────────────────────────────────────────────────────
hi(0, "LspReferenceText",  { bg = "#093B42" })
hi(0, "LspReferenceRead",  { bg = "#093B42" })
hi(0, "LspReferenceWrite", { bg = "#005760" })
