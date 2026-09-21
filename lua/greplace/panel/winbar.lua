-- The panel's winbar: the counts of what it holds, or a status in their place.

local config = require("greplace.config").current

local M = {}

---@class greplace.Stats
---@field files   integer  distinct files still listed
---@field lines   integer  matches still listed (a removed one does not count)
---@field changes integer  listed matches whose text no longer matches the source

--- What the panel currently holds. A removed line drops out of every count --
--- it is no longer part of the replacement. The counts are kept up to date by
--- `redraw`, which runs shortly after an edit rather than within it.
---@param state greplace.PanelState?
---@return greplace.Stats?  nil when the panel holds no rendered list
function M.stats(state)
    return state and state.stats and vim.deepcopy(state.stats)
end

---@param n    integer
---@param word string
---@return string  "1 file", "2 files"
local function plural(n, word)
    return string.format("%d %s", n, n == 1 and word or word .. "s")
end

--- Draw the panel's winbar: what the panel currently holds, left-aligned.
--- `status` stands in while there is nothing to count -- the search is still
--- running, or it produced no list.
---@param bufnr  integer
---@param state  greplace.PanelState
---@param status string?
function M.set_winbar(bufnr, state, status)
    if not config.winbar then return end

    -- A final message outlives the buffer write that showed it, so that any
    -- redraw of the winbar puts it back rather than the counts of an empty
    -- panel.
    local st   = state.stats
    local text = status or state.message
    if not text then
        text = st and string.format("%s  %s  %s",
            plural(st.files, "file"), plural(st.lines, "line"),
            plural(st.changes, "change")) or ""
    end

    -- A truncated list is a partial answer to the query: the matches beyond
    -- the limit were never collected, so nothing in the panel hints at them.
    -- Say so while the panel still lists the full `limit` of them. Once lines
    -- are removed from it, the counts no longer sit at the limit, and the note
    -- would only be noise; an undo that brings them back brings it back too.
    local limit = ""
    if state.truncated and (not st or st.lines >= config.limit) then
        limit = string.format("  %%#GreplaceLimit#limit of %d reached",
            config.limit)
    end

    -- `text` is not always the plugin's own words: a query the user typed and
    -- rg's stderr both reach here through `M.set_message`, and a `%` in a
    -- winbar is a format item -- `%f` draws the file name, `%{...}` evaluates
    -- a Vim expression. Double every one so it draws as itself.
    text = text:gsub("%%", "%%%%")

    -- Trailing `%=` so the text sits left and the highlight does not run on
    -- past it.
    local bar = string.format(" %%#GreplaceStatus#%s%s%%=", text, limit)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        -- Only when it differs: setting an option redraws the bar, and this
        -- runs behind every edit.
        if vim.api.nvim_win_get_buf(win) == bufnr and vim.wo[win].winbar ~= bar then
            vim.wo[win].winbar = bar
        end
    end
end

return M
