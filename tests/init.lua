-- Busted helper: loaded once, inside Neovim, before any spec runs.
--
-- busted runs under `tests/nvim-lua` (see `.busted`), so the specs get a real
-- Neovim (and with it the `vim` API) rather than a bare Lua interpreter.

-- Absolute paths throughout: the specs `chdir` into temporary directories, so
-- a relative runtimepath or `package.path` entry would stop resolving mid-run.
local root = vim.uv.cwd()

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
    root .. "/lua/?.lua",
    root .. "/lua/?/init.lua",
    package.path,
}, ";")

-- The shim starts Neovim with `-u NONE`, which also means "no plugin scripts and
-- no filetype detection". Put back the parts of an ordinary session the specs
-- assume: this plugin's own commands and autocmds, and `:filetype on` (a file
-- loaded by the panel is expected to arrive with its filetype set).
vim.cmd("filetype plugin indent on")
for _, file in ipairs(vim.fn.glob(root .. "/plugin/**/*.{lua,vim}", false, true)) do
    vim.cmd.source(file)
end

-- Tests must not see the developer's own editing history: a real shada file
-- carries global marks (`'A`-`'Z`, `'0`-`'9`) that the marks picker would list
-- alongside the ones a test sets.
vim.opt.shadafile = "NONE"
