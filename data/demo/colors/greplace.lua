-- A small dark colorscheme for the README recordings: warm pastels on a
-- near-black background, so the panel's green/yellow markers and the match
-- highlight have room to stand out.

local c = {
    bg = "#2e2f33",
    bg_float = "#46474f",
    bg_line = "#3a3b41",
    bg_visual = "#3c4a66",
    bg_panel = "#34353a",
    line = "#585963",
    overlay = "#6e6f77",
    muted = "#a0a2ad",
    fg_dim = "#dcdce4",
    fg = "#f2f2f5",

    red = "#ecaaaa",
    orange = "#ecba8a",
    yellow = "#edd897",
    green = "#a2d4a2",
    teal = "#8bcec9",
    sky = "#97ccdf",
    blue = "#90b8e3",
    lavender = "#b9a8e9",
    pink = "#e4a8ca",
    amber = "#d8a866",
    lime = "#b2d87c",
    mauve = "#be94c8",
    indigo = "#7e97d8",

    bg_green = "#324637",
    bg_amber = "#4B4336",
    bg_teal = "#304944",
}

vim.g.colors_name = "greplace"
if vim.fn.exists("syntax_on") then vim.cmd("syntax reset") end
vim.o.background = "dark"
vim.o.termguicolors = true

local function hl(group, opts)
    if type(opts) == "string" then
        vim.api.nvim_set_hl(0, group, { link = opts })
        return
    end
    local val = {}
    if opts.fg then val.fg = opts.fg end
    if opts.bg then val.bg = opts.bg end
    if opts.sp then val.sp = opts.sp end
    if opts.bold then val.bold = true end
    if opts.italic then val.italic = true end
    vim.api.nvim_set_hl(0, group, val)
end

-- Core
hl("Normal", { fg = c.fg, bg = c.bg })
hl("NormalNC", { fg = c.fg, bg = c.bg })
hl("NormalFloat", { fg = c.fg, bg = c.bg_float })
hl("FloatBorder", { fg = c.overlay, bg = c.bg_float })
hl("FloatTitle", { fg = c.blue, bg = c.bg_float, bold = true })
hl("Cursor", { fg = c.bg, bg = c.fg })
hl("Visual", { bg = c.bg_visual })
hl("VisualNOS", { bg = c.bg_visual })
hl("Search", { fg = c.bg, bg = c.yellow })
hl("IncSearch", { fg = c.bg, bg = c.amber, bold = true })
hl("CurSearch", { fg = c.bg, bg = c.amber })

-- Chrome
hl("StatusLine", { fg = c.fg_dim, bg = c.bg_float })
hl("StatusLineNC", { fg = c.muted, bg = c.bg_float })
hl("WinBar", { fg = c.fg_dim, bg = c.bg_float })
hl("WinBarNC", { fg = c.muted, bg = c.bg_float })
hl("WinSeparator", { fg = c.line })
hl("TabLine", { fg = c.muted, bg = c.bg_panel })
hl("TabLineFill", { fg = c.muted, bg = c.bg_panel })
hl("TabLineSel", { fg = c.lime, bg = c.bg_panel, bold = true })
hl("Title", { fg = c.blue, bold = true })
hl("CursorLine", { bg = c.bg_line })
hl("CursorLineNr", { fg = c.fg_dim, bg = c.bg_line, bold = true })
hl("LineNr", { fg = c.muted, bg = c.bg })
hl("SignColumn", { fg = c.muted, bg = c.bg })
hl("NonText", { fg = c.overlay })
hl("SpecialKey", { fg = c.overlay })
hl("Whitespace", { fg = c.overlay })

-- Popup menu
hl("PMenu", { fg = c.fg, bg = c.bg_float })
hl("PMenuSel", { fg = c.bg, bg = c.blue })
hl("PMenuSbar", { bg = c.bg_panel })
hl("PMenuThumb", { bg = c.overlay })

-- Messages
hl("ModeMsg", { fg = c.lime })
hl("MoreMsg", { fg = c.green })
hl("Question", { fg = c.sky })
hl("WarningMsg", { fg = c.amber })
hl("ErrorMsg", { fg = c.red, bg = c.bg })
hl("Error", { fg = c.red, bg = c.bg })

-- Syntax
hl("Comment", { fg = c.muted, italic = true })
hl("String", { fg = c.green })
hl("Character", { fg = c.green })
hl("Number", { fg = c.orange })
hl("Float", { fg = c.orange })
hl("Boolean", { fg = c.orange })
hl("Constant", { fg = c.orange })
hl("Identifier", { fg = c.sky })
hl("Function", { fg = c.blue })
hl("Keyword", { fg = c.lavender })
hl("Conditional", { fg = c.lavender })
hl("Repeat", { fg = c.lavender })
hl("Statement", { fg = c.lavender })
hl("Operator", { fg = c.mauve })
hl("Exception", { fg = c.red })
hl("PreProc", { fg = c.indigo })
hl("Include", { fg = c.indigo })
hl("Define", { fg = c.lavender })
hl("Type", { fg = c.yellow })
hl("StorageClass", { fg = c.yellow })
hl("Structure", { fg = c.yellow })
hl("Special", { fg = c.teal })
hl("Tag", { fg = c.amber })
hl("Label", { fg = c.yellow })
hl("Delimiter", { fg = c.pink })
hl("Todo", { fg = c.amber, bold = true })

-- Treesitter groups the panel links to, and Lua files use.
hl("@module", { fg = c.indigo })
hl("@comment", { fg = c.muted, italic = true })
hl("@function", { fg = c.blue })
hl("@function.call", { fg = c.blue })
hl("@keyword", { fg = c.lavender })
hl("@string", { fg = c.green })
hl("@number", { fg = c.orange })
hl("@variable", { fg = c.fg })
hl("@property", { fg = c.sky })
hl("@operator", { fg = c.mauve })
hl("@punctuation.bracket", { fg = c.fg_dim })
hl("@punctuation.delimiter", { fg = c.pink })

-- Diff, for `:Greplace diff`
hl("DiffAdd", { bg = c.bg_green })
hl("DiffDelete", { fg = c.overlay })
hl("DiffChange", { bg = c.bg_amber })
hl("DiffText", { bg = c.bg_teal, bold = true })
