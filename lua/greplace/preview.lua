local M = {}

-- ---------------------------------------------------------------------------
-- `:Greplace diff`: what writing the panel would do, before it is done.
--
-- The caller applies the panel's edits to copies of the files they belong to
-- (`greplace.apply.preview`), and the difference is shown here as one unified diff,
-- file after file, in a read-only buffer on a tab of its own. Nothing is
-- loaded and no buffer is touched: the preview is thrown away with its tab,
-- and the panel is where the edits are made, and written, as ever.
-- ---------------------------------------------------------------------------

local ui = require("greplace.util.ui")

local _buffer_name = "greplace://greplace-diff"

--- The preview's buffer while there is one. Only one is kept: the buffer wipes
--- when its tab goes, and clears this as it does.
---@type integer?
local _bufnr = nil

-- `vim.text.diff` in newer Neovim, where `vim.diff` is deprecated; only the
-- older name exists in 0.11.
---@diagnostic disable-next-line: deprecated
local _diff = vim.text and vim.text.diff or vim.diff

--- One unified diff per changed file, `---`/`+++` headers included, led by a
--- note for each edit the write would leave out.
---@param preview greplace.Preview
---@return string[]
local function render(preview)
    local lines = {}
    for _, skip in ipairs(preview.skipped) do
        lines[#lines + 1] = ("# skipped %s:%d (%s)")
            :format(skip.entry.relpath, skip.entry.lnum, skip.reason)
    end
    for _, file in ipairs(preview.files) do
        -- Both sides end in a newline, so a change to the last line is not
        -- also reported as the loss of one.
        local diff = _diff(
            table.concat(file.before, "\n") .. "\n",
            table.concat(file.after, "\n") .. "\n",
            { result_type = "unified", ctxlen = 3 }) --[[@as string]]
        lines[#lines + 1] = "--- a/" .. file.relpath
        lines[#lines + 1] = "+++ b/" .. file.relpath
        vim.list_extend(lines, vim.split(diff, "\n", { trimempty = true }))
    end
    return lines
end

--- Close the preview, if one is open: once the edits it shows are applied, it
--- is out of date.
function M.close()
    if _bufnr then vim.api.nvim_buf_delete(_bufnr, { force = true }) end
end

--- Show what writing the panel would change.
---@param preview greplace.Preview  as `greplace.apply.preview` works it out
---@return integer? bufnr  the preview's buffer; nil when there is nothing to show
function M.open(preview)
    if #preview.files == 0 and #preview.skipped == 0 then
        vim.notify("greplace: no changes to preview", vim.log.levels.INFO)
        return
    end

    -- One preview at a time, and never a stale one: an earlier one still
    -- open is replaced rather than left showing the edits as they were.
    M.close()

    local bufnr = ui.create_scratch_buffer(false, nil, function() _bufnr = nil end)
    _bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, _buffer_name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, render(preview))
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype   = "diff"
    vim.cmd.sbuffer({ bufnr, mods = { tab = vim.fn.tabpagenr() } })

    -- Deleting the buffer closes its window, and with it the tab.
    vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(bufnr, { force = true }) end, {
        buffer = bufnr,
        desc   = "greplace: close the preview",
    })

    if #preview.skipped > 0 then
        vim.notify(("greplace: %d edit(s) would be skipped; see the top of the preview")
            :format(#preview.skipped), vim.log.levels.WARN)
    end
    return bufnr
end

return M
