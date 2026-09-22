-- The panel's winbar: the counts of what it holds, or a status in their place.

local config = require("greplace.config").current

local M = {}

---@param n    integer
---@param word string
---@return string  "1 file", "2 files"
local function plural(n, word)
    return string.format("%d %s", n, n == 1 and word or word .. "s")
end

--- Draw the panel's winbar: what the panel currently holds, left-aligned.
--- `text` stands in while there is nothing to count -- the search is still
--- running, or it produced no list.
---@param bufnr     integer
---@param text      string?  what stands in for the counts: a status, or a
---                          final message
---@param st        greplace.Stats?  the counts of a rendered list
---@param truncated boolean  the list is the first `limit` matches of more
function M.set_winbar(bufnr, text, st, truncated)
    if not config.winbar then return end

    if not text then
        text = st and string.format("%s (%d changed)  %s (%d changed)",
            plural(st.files, "file"), st.changed_files,
            plural(st.lines, "line"), st.changes) or ""
    end

    -- A truncated list is a partial answer to the query: the matches beyond
    -- the limit were never collected, so nothing in the panel hints at them.
    -- Say so while the panel still lists the full `limit` of them. Once lines
    -- are removed from it, the counts no longer sit at the limit, and the note
    -- would only be noise; an undo that brings them back brings it back too.
    local note = ""
    if truncated and (not st or st.lines >= config.limit) then
        note = string.format("  %%#GreplaceLimit#limit of %d reached",
            config.limit)
    end

    -- `text` is not always the plugin's own words: a query the user typed and
    -- rg's stderr both reach here through `M.set_message`, and a `%` in a
    -- winbar is a format item -- `%f` draws the file name, `%{...}` evaluates
    -- a Vim expression. Double every one so it draws as itself.
    text = text:gsub("%%", "%%%%")

    -- Trailing `%=` so the text sits left and the highlight does not run on
    -- past it.
    local bar = string.format(" %%#GreplaceStatus#%s%s%%=", text, note)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        -- Only when it differs: setting an option redraws the bar, and this
        -- runs behind every edit.
        if vim.api.nvim_win_get_buf(win) == bufnr and vim.wo[win].winbar ~= bar then
            vim.wo[win].winbar = bar
        end
    end
end

return M
