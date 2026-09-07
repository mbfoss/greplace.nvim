-- The panel's winbar: the counts of what it holds, or a status in their place.

local config = require("greplace.config").current

local M = {}

---@param n    integer
---@param word string
---@return string  "1 file", "2 files"
local function plural(n, word)
    return string.format("%d %s", n, n == 1 and word or word .. "s")
end

--- Draw the panel's winbar: what it currently holds, left-aligned.
---@param bufnr     integer
---@param text      string?  a status or final message instead of the counts
---@param st        greplace.Stats?  the counts of a rendered list
---@param truncated boolean  the list is the first `limit` matches of more
function M.set_winbar(bufnr, text, st, truncated)
    if not config.winbar then return end

    if not text then
        text = st and string.format("%s (%d changed)  %s (%d changed)",
            plural(st.files, "file"), st.changed_files,
            plural(st.lines, "line"), st.changes) or ""
    end

    -- A truncated list is partial: the matches beyond the limit were never
    -- collected. Say so while the count still sits at the limit, and no
    -- longer -- removal makes the note noise; undo restores both.
    local note = ""
    if truncated and (not st or st.lines >= config.limit) then
        note = string.format("  %%#GreplaceLimit#limit of %d reached",
            config.limit)
    end

    -- `text` can be a user query or rg's stderr, and `%` is a winbar format
    -- item, so double every one to draw it literally.
    text = text:gsub("%%", "%%%%")

    -- Trailing `%=` so the text sits left and the highlight does not run on
    -- past it.
    local bar = string.format(" %%#GreplaceStatus#%s%s%%=", text, note)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        -- Only when it differs: setting an option redraws the bar, and this
        -- runs behind every edit.
        if vim.api.nvim_win_get_buf(win) == bufnr and vim.wo[win][0].winbar ~= bar then
            vim.wo[win][0].winbar = bar
        end
    end
end

return M
