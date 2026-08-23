local M = {}

-- ---------------------------------------------------------------------------
-- The `greplace://replace` scratch buffer.
--
-- Every line holds one matched line verbatim, so it can be edited as ordinary
-- text. The `file:line` location is not part of the line: it is inline virtual
-- text on an extmark anchored at column 0. That extmark is also the only record
-- of where a line came from, and because extmarks travel with the edits around
-- them, it still points at the right buffer row after lines have been inserted,
-- joined or deleted. `M.regions()` reads those anchors back at write time.
-- ---------------------------------------------------------------------------

local config   = require("greplace.config")
local util     = require("greplace.util")
local ui       = require("greplace.util.ui")

local _NAME    = "greplace://replace"
local _ns      = vim.api.nvim_create_namespace("greplace.anchor")
local _ns_hl   = vim.api.nvim_create_namespace("greplace.match")

---@class greplace.Entry
---@field path    string   absolute file path
---@field relpath string
---@field lnum    integer  1-indexed line in the source file
---@field text    string   the source line as it was when the panel rendered

---State of the one panel buffer: the anchor extmark id of each match, and the
---query it was built from.
---@class greplace.PanelState
---@field query   string
---@field regex   boolean
---@field root    string
---@field entries table<integer, greplace.Entry>  keyed by anchor extmark id
---@field virt    table<integer, table[]>  each anchor's virtual text chunks
---@field hidden  table<integer, boolean>  anchors whose line has been deleted

---@type table<integer, greplace.PanelState>
local _state = {}

---@class greplace.Region
---@field entry greplace.Entry
---@field lines string[]  replacement text: 0 lines deletes the source line

---@return integer? bufnr
function M.find_buf()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(bufnr):sub(- #_NAME) == _NAME
            and vim.api.nvim_buf_is_valid(bufnr) then
            return bufnr
        end
    end
end

---@param bufnr integer
---@return greplace.PanelState?
function M.state(bufnr)
    return _state[bufnr]
end

---@param bufnr integer
function M.is_panel(bufnr)
    return _state[bufnr] ~= nil
end

--- Which anchors have had their line deleted: an anchor owns the rows from its
--- own down to the next anchor's, so it is empty when the next one has caught
--- up with it (or when it has been pushed past the end of the buffer).
---@param bufnr integer
---@param marks integer[][]  anchors in buffer order, as `nvim_buf_get_extmarks`
---@param total integer      the buffer's line count
---@return table<integer, boolean> empty  keyed by extmark id
local function empty_anchors(bufnr, marks, total)
    -- A buffer emptied outright (`ggdG`) still holds one empty line, which
    -- would otherwise read as "blank out the last source line" rather than as
    -- the deletion of every match that it plainly is.
    local blank = total == 1
        and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""

    local empty = {}
    for i, mark in ipairs(marks) do
        local id, row  = mark[1], mark[2]
        local next_row = marks[i + 1] and marks[i + 1][2] or total
        empty[id] = blank or next_row <= row
    end
    return empty
end

--- Show each anchor's location again, or hide it where the line it belonged to
--- has been deleted. Without this a deleted line's anchor -- which survives, so
--- that the write can delete the source line too -- would keep drawing its
--- `file:line` inline on whatever row it collapsed onto, stacked in front of
--- that row's own location.
---@param bufnr integer
local function sync_virt(bufnr)
    local state = _state[bufnr]
    if not state then return end

    local total = vim.api.nvim_buf_line_count(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1, {})
    local empty = empty_anchors(bufnr, marks, total)

    for _, mark in ipairs(marks) do
        local id, row, col = mark[1], mark[2], mark[3]
        local hide = empty[id] or false
        -- An anchor pushed past the last line (the final match's line deleted)
        -- has no row to draw on and cannot be re-set at one either -- moving it
        -- back onto the last line would make the anchor above it look like the
        -- deleted one instead. It draws nothing as it is, so leave it be.
        --
        -- Otherwise only when it changes: this runs on every edit, and
        -- re-setting every anchor of a long result list per keystroke is not
        -- free.
        if state.entries[id] and row < total and state.hidden[id] ~= hide then
            state.hidden[id] = hide
            vim.api.nvim_buf_set_extmark(bufnr, _ns, row, col, {
                id            = id,
                virt_text     = not hide and state.virt[id] or nil,
                virt_text_pos = "inline",
                right_gravity = false,
            })
        end
    end
end

--- The match a buffer row belongs to: the nearest anchor at or above `row`,
--- since an anchor owns everything from its own row down to the next one.
---@param bufnr integer
---@param row   integer  0-indexed
---@return greplace.Entry? entry
---@return integer?        anchor_row  0-indexed row the anchor sits on
function M.entry_at(bufnr, row)
    local state = _state[bufnr]
    if not state then return end
    -- Searching backwards from `row` and stopping at the first hit avoids
    -- walking every anchor in a long result list.
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { row, -1 }, 0, { limit = 1 })
    local mark  = marks[1]
    if not mark then return end
    return state.entries[mark[1]], mark[2]
end

--- Open the source of the line under the cursor, in a regular window (never
--- over the panel itself), on the line the match came from.
---@param bufnr integer
local function jump(bufnr)
    local pos = vim.api.nvim_win_get_cursor(0)
    local row, col = pos[1], pos[2]
    local entry, anchor_row = M.entry_at(bufnr, row - 1)
    if not entry then
        vim.notify("greplace: no match on this line", vim.log.levels.WARN)
        return
    end
    -- The panel line is the source line verbatim, so on the anchor's own row
    -- the column carries over; on a row the user added below it, it does not.
    local target_col = anchor_row == row - 1 and col or 0
    if ui.smart_open_file(entry.path, entry.lnum, target_col, true) == -1 then
        vim.notify("greplace: cannot open " .. entry.relpath, vim.log.levels.ERROR)
    end
end

---@param on_write fun(bufnr:integer)
---@return integer bufnr
local function create_buf(on_write)
    -- Set here rather than at startup: the groups are `default` links, which a
    -- later `:colorscheme` clears, and nothing needs them before there is a
    -- panel to draw.
    M.setup_highlights()

    local bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, _NAME)

    vim.bo[bufnr].buftype   = "acwrite"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile  = false
    vim.bo[bufnr].filetype  = "greplace"

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        desc   = "greplace: apply edits to buffers in memory",
        callback = function() on_write(bufnr) end,
    })
    if config.options.keys.open and config.options.keys.open ~= "" then
        vim.keymap.set("n", config.options.keys.open, function() jump(bufnr) end, {
            buffer = bufnr,
            desc   = "greplace: open the source of the line under the cursor",
        })
    end

    -- `on_lines` rather than `TextChanged`: it catches every kind of change,
    -- including one made from a mapping or a script mid-command, and it fires
    -- as the change lands rather than on the way back to the main loop.
    -- Its callback runs in a context where the API is off limits, hence the
    -- `vim.schedule`; one pending pass is enough however many lines changed.
    local pending = false
    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function()
            if not _state[bufnr] then return true end -- detach with the panel
            if pending then return end
            pending = true
            vim.schedule(function()
                pending = false
                sync_virt(bufnr)
            end)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer   = bufnr,
        callback = function() _state[bufnr] = nil end,
    })
    return bufnr
end

--- Show the panel in a split, reusing the window it already occupies.
---@param bufnr  integer
---@param height integer
local function show(bufnr, height)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    vim.cmd(string.format("botright %dsplit", height))
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.wo[0][0].number         = false
    vim.wo[0][0].relativenumber = false
    vim.wo[0][0].wrap           = false
    vim.wo[0][0].signcolumn     = "no"
    -- The panel keeps its window: <CR> (and anything else that opens a file)
    -- must land in a regular window rather than covering the results.
    vim.wo[0][0].winfixbuf      = true
end

---@param matches greplace.Match[]
---@return integer width
local function location_width(matches)
    local width = 0
    for _, m in ipairs(matches) do
        width = math.max(width, vim.fn.strdisplaywidth(m.relpath .. ":" .. m.lnum))
    end
    return width
end

--- Write the match list into the panel buffer and (re)anchor one extmark per
--- match. Entries are keyed by the returned extmark ids.
---@param bufnr   integer
---@param matches greplace.Match[]
local function render(bufnr, matches)
    local state   = assert(_state[bufnr])
    local lines   = {}
    for i, m in ipairs(matches) do lines[i] = m.text end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_hl, 0, -1)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local width   = location_width(matches)
    state.entries = {}
    state.virt    = {}
    state.hidden  = {}

    for row, m in ipairs(matches) do
        local location = string.format("%s:%d", m.relpath, m.lnum)
        local pad      = string.rep(" ", width - vim.fn.strdisplaywidth(location))
        local virt     = {
            { location, m.bufnr and "GreplaceBufferLocation" or "GreplaceLocation" },
            { pad .. " │ ",                                   "GreplaceSeparator" },
        }
        local id       = vim.api.nvim_buf_set_extmark(bufnr, _ns, row - 1, 0, {
            virt_text     = virt,
            virt_text_pos = "inline",
            -- Text typed at the start of a line belongs after the location, so
            -- the anchor must not drift right with it.
            right_gravity = false,
        })
        state.virt[id]    = virt
        state.hidden[id]  = false
        state.entries[id] = {
            path    = m.path,
            relpath = m.relpath,
            lnum    = m.lnum,
            text    = m.text,
        }
        for _, sm in ipairs(m.subs) do
            vim.api.nvim_buf_set_extmark(bufnr, _ns_hl, row - 1, sm.s, {
                end_col  = math.min(sm.e, #m.text),
                hl_group = "GreplaceMatch",
            })
        end
    end

    vim.bo[bufnr].modified = false
end

--- Open (or reuse) the panel for a result set.
---@param matches  greplace.Match[]
---@param opts     { query:string, regex:boolean?, root:string, height:integer, on_write:fun(bufnr:integer) }
---@return integer bufnr
function M.open(matches, opts)
    local bufnr = M.find_buf() or create_buf(opts.on_write)
    _state[bufnr] = {
        query   = opts.query,
        regex   = opts.regex or false,
        root    = opts.root,
        entries = {},
        virt    = {},
        hidden  = {},
    }
    show(bufnr, opts.height)
    render(bufnr, matches)
    return bufnr
end

--- Re-render the panel from entries that were just applied, so the shown lines
--- and line numbers match the buffers again.
---@param bufnr   integer
---@param entries greplace.Entry[]  in display order
function M.refresh(bufnr, entries)
    local matches = {} ---@type greplace.Match[]
    for i, e in ipairs(entries) do
        matches[i] = {
            path    = e.path,
            relpath = e.relpath,
            lnum    = e.lnum,
            text    = e.text,
            subs    = {},
            bufnr   = util.find_buf(e.path),
        }
    end
    render(bufnr, matches)
end

--- Read the edited buffer back as one replacement region per anchor: the lines
--- from an anchor's row up to the next anchor's row. A region of several lines
--- splits the source line; an empty region deletes it.
---@param bufnr integer
---@return greplace.Region[] regions  in buffer order
function M.regions(bufnr)
    local state = _state[bufnr]
    if not state then return {} end

    local total = vim.api.nvim_buf_line_count(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1, {})
    local empty = empty_anchors(bufnr, marks, total)
    local out   = {}

    for i, mark in ipairs(marks) do
        local id, row = mark[1], mark[2]
        local entry   = state.entries[id]
        if entry then
            local next_mark = marks[i + 1]
            local stop      = next_mark and next_mark[2] or total
            out[#out + 1]   = {
                entry = entry,
                lines = not empty[id]
                    and vim.api.nvim_buf_get_lines(bufnr, row, stop, false)
                    or {},
            }
        end
    end
    return out
end

--- Define the plugin's highlight groups as `default` links, so a colorscheme
--- that defines them itself wins. Called whenever a panel is created and again
--- after every colorscheme change, both of which clear such links.
function M.setup_highlights()
    local defaults = {
        GreplaceLocation       = { link = "Directory" },
        GreplaceBufferLocation = { link = "Special" },
        GreplaceSeparator      = { link = "Comment" },
        GreplaceMatch          = { link = "Search" },
    }
    for name, def in pairs(defaults) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
    end
end

vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("greplace.highlights", { clear = true }),
    desc     = "greplace: re-define highlight groups cleared by the new colorscheme",
    callback = function() M.setup_highlights() end,
})

return M
