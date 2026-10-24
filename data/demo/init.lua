-- Minimal, self-contained init for the README recordings.
local demo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(demo .. "/../..", ":p")

vim.opt.rtp:append(demo) -- data/demo/colors/greplace.lua
vim.opt.rtp:append(root) -- the plugin itself

vim.o.number = true
vim.o.relativenumber = false
vim.o.cursorline = true
vim.o.signcolumn = "no"
vim.o.wrap = false
vim.o.scrolloff = 5
vim.o.showtabline = 2
vim.o.laststatus = 2
vim.o.cmdheight = 1
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.mouse = ""
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.undofile = false
vim.o.backup = false
vim.o.shortmess = vim.o.shortmess .. "I"
vim.opt.clipboard = ""
vim.o.fillchars = "eob: "
vim.g.mapleader = " "

vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.cmd("colorscheme greplace")

-- Statusline: the plugin on the left, the open file on the right.
vim.api.nvim_set_hl(0, "DemoStatusLeft", { fg = "#2e2f33", bg = "#90b8e3", bold = true })
vim.api.nvim_set_hl(0, "DemoStatusRight", { fg = "#dcdce4", bg = "#46474f" })
vim.o.statusline = "%#DemoStatusLeft# greplace.nvim %#DemoStatusRight#%= %t "

require("nvim_demo").setup({ fg = "#2e2f33", bg = "#90b8e3", fill = "#3a3b41" })

-- A taller panel than the default so a whole result list is visible, and a
-- narrower location column so the match text keeps most of the width.
require("greplace").setup({ height_ratio = 0.45, path_width = 44 })

-- The recordings start on the workspace's README rather than an empty buffer.
if vim.fn.filereadable("README.md") == 1 then
    vim.cmd.edit("README.md")
end
