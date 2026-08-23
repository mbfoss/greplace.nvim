local plenary_dir = os.getenv("NVIM_PLENARY_DIR") or "/tmp/plenary.nvim"

-- Presence of the directory is not enough: an interrupted or partial clone
-- leaves a directory whose `plugin/plenary.vim` is missing, so
-- `PlenaryBustedDirectory` never gets defined and the run hangs/errors. Key the
-- decision off that plugin file, and wipe a broken tree before re-cloning.
local plugin_file = plenary_dir .. "/plugin/plenary.vim"
if vim.fn.filereadable(plugin_file) == 0 then
  if vim.fn.isdirectory(plenary_dir) == 1 then
    print("removing incomplete plenary clone at " .. plenary_dir)
    vim.fn.delete(plenary_dir, "rf")
  end
  print("cloning plenary into " .. plenary_dir)
  local out = vim.fn.system({
    "git", "clone", "--depth", "1",
    "https://github.com/nvim-lua/plenary.nvim", plenary_dir,
  })
  if vim.v.shell_error ~= 0 or vim.fn.filereadable(plugin_file) == 0 then
    error("failed to clone plenary into " .. plenary_dir .. "\n" .. out)
  end
end

-- Tests must not see the developer's own editing history: a real shada file
-- carries global marks (`'A`-`'Z`, `'0`-`'9`) that the marks picker would list
-- alongside the ones a test sets.
vim.opt.shadafile = "NONE"

vim.opt.rtp:append(".")
vim.opt.rtp:append(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
