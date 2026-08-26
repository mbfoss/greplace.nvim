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
local strutil  = require("greplace.util.strutil")
local throttle = require("greplace.util.throttle")

local _NAME    = "greplace://replace"
local _ns      = vim.api.nvim_create_namespace("greplace.anchor")
local _ns_hl   = vim.api.nvim_create_namespace("greplace.match")
local _ns_st   = vim.api.nvim_create_namespace("greplace.status")

-- The panel opens the moment a search is triggered, before there is anything
-- to show, so the results land in a window that is already there rather than
-- one that appears seconds later under the cursor. Until they do, the buffer
-- holds a single blank line carrying the status as virtual text: that the
-- search is running, and afterwards whatever came of it if it produced no list
-- to render.

---@class greplace.Entry
---@field path    string   absolute file path
---@field relpath string
---@field lnum    integer  1-indexed line in the source file
---@field text    string   the source line as it was when the panel rendered

---State of the one panel buffer: the anchor extmark id of each match, and the
---query it was built from.
---@class greplace.PanelState
---@field query   string
---@field root    string
---@field flags   table?   `:Gsearch` flags the search was run with, so
---                        that re-running it means the same search
---@field entries table<integer, greplace.Entry>  keyed by anchor extmark id
---@field virt    table<integer, table[]>  each anchor's virtual text chunks
---@field hidden  table<integer, boolean>  anchors whose line has been removed
---@field truncated boolean  the search stopped at the match limit, so this is
---                          the first `limit` matches of more

---@type table<integer, greplace.PanelState>
local _state = {}

---@class greplace.Region
---@field entry greplace.Entry
---@field lines string[]  replacement text: 0 lines leaves the source alone

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

--- Which anchors have had their line removed: an anchor owns the rows from its
--- own down to the next anchor's, so it is empty when the next one has caught
--- up with it (or when it has been pushed past the end of the buffer). Removing
--- a line drops that match from the replacement; it never touches the file.
---@param bufnr integer
---@param marks integer[][]  anchors in buffer order, as `nvim_buf_get_extmarks`
---@param total integer      the buffer's line count
---@return table<integer, boolean> empty  keyed by extmark id
local function empty_anchors(bufnr, marks, total)
    -- A buffer emptied outright (`ggdG`) still holds one empty line, which
    -- would otherwise read as "blank out the last source line" rather than as
    -- the "drop every match" that it plainly is.
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
--- has been removed. Without this a removed line's anchor -- which survives, so
--- that the write knows to leave that match out -- would keep drawing its
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
        -- An anchor pushed past the last line (the final match's line removed)
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

---@class greplace.Stats
---@field files   integer  distinct files still listed
---@field lines   integer  matches still listed (a removed one does not count)
---@field changes integer  listed matches whose text no longer matches the source

--- Count what the panel currently holds. A removed line drops out of every
--- count -- it is no longer part of the replacement -- and a match whose region
--- has grown to several lines is still one changed match, not several.
---@param bufnr integer
---@return greplace.Stats?  nil when the buffer is not a rendered panel
function M.stats(bufnr)
    local state = _state[bufnr]
    if not state then return end

    -- One read of the whole buffer rather than one per anchor: this runs on
    -- every edit that could move an anchor, and a result list can be long.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local total = #lines
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1, {})
    local empty = empty_anchors(bufnr, marks, total)

    local files, stats = {}, { files = 0, lines = 0, changes = 0 }
    for i, mark in ipairs(marks) do
        local id, row = mark[1], mark[2]
        local entry   = state.entries[id]
        if entry and not empty[id] then
            local stop = marks[i + 1] and marks[i + 1][2] or total
            stats.lines = stats.lines + 1
            if not files[entry.path] then
                files[entry.path] = true
                stats.files = stats.files + 1
            end
            -- Unchanged means exactly one line, holding what was rendered.
            if stop ~= row + 1 or lines[row + 1] ~= entry.text then
                stats.changes = stats.changes + 1
            end
        end
    end
    return stats
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
---@param status string?
local function set_winbar(bufnr, status)
    if not config.options.winbar then return end
    if not _state[bufnr] then return end

    -- A final message outlives the buffer write that showed it: writing the
    -- status line into the buffer is itself an edit, and the throttled redraw
    -- it triggers would otherwise put the counts of an empty panel back.
    local text = status or _state[bufnr].message
    if not text then
        local st = M.stats(bufnr)
        text = st and string.format("%s  %s  %s",
            plural(st.files, "file"), plural(st.lines, "line"),
            plural(st.changes, "change")) or ""
    end

    -- A truncated list is a partial answer to the query, and one that stays
    -- partial: the matches beyond the limit were never collected, so nothing
    -- in the panel hints at them. Say so for as long as the panel holds that
    -- list -- including while the counts move under editing, since those counts
    -- are what would otherwise read as the whole story.
    local limit = ""
    if _state[bufnr].truncated then
        limit = string.format("  %%#GreplaceLimit#limit of %d reached",
            config.options.limit)
    end

    -- Trailing `%=` so the text sits left and the highlight does not run on
    -- past it; `status` is plugin text, so there is no `%` to escape.
    local bar = string.format(" %%#GreplaceSeparator#%s%s%%=", text, limit)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            vim.wo[win].winbar = bar
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

--- Show everything the panel had to leave out about the line under the cursor:
--- the full path (the panel's own column is cropped), where the match came
--- from, and the source line as it was when the panel rendered it -- what the
--- write compares against, so it is worth being able to see.
---@param bufnr integer
local function hover(bufnr)
    local row   = vim.api.nvim_win_get_cursor(0)[1]
    local entry = M.entry_at(bufnr, row - 1)
    if not entry then
        vim.notify("greplace: no match on this line", vim.log.levels.WARN)
        return
    end

    local loaded = util.find_buf(entry.path)
    local lines  = {
        "**" .. vim.fn.fnamemodify(entry.path, ":t") .. ":" .. entry.lnum .. "**",
        "",
        "- path: `" .. entry.path .. "`",
        "- relative: `" .. entry.relpath .. "`",
        "- line: `" .. entry.lnum .. "`",
        "- buffer: " .. (loaded and ("`" .. loaded .. "` (loaded)") or "not loaded"),
        "",
        "```",
        entry.text,
        "```",
    }
    vim.lsp.util.open_floating_preview(lines, "markdown", {
        border   = "rounded",
        wrap     = false,
        focus_id = "greplace.hover",
    })
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
        -- `nested`, because the write loads the files it edits into buffers:
        -- without it their `BufReadPost`/`FileType` never fire (autocommands
        -- do not nest by default), so those buffers come up with no filetype
        -- and hence no syntax, treesitter or LSP -- and stay that way, being
        -- already loaded by the time the user opens one.
        nested = true,
        callback = function() on_write(bufnr) end,
    })
    if config.options.keys.open and config.options.keys.open ~= "" then
        vim.keymap.set("n", config.options.keys.open, function() jump(bufnr) end, {
            buffer = bufnr,
            desc   = "greplace: open the source of the line under the cursor",
        })
    end
    if config.options.keys.hover and config.options.keys.hover ~= "" then
        vim.keymap.set("n", config.options.keys.hover, function() hover(bufnr) end, {
            buffer = bufnr,
            desc   = "greplace: show the full details of the match under the cursor",
        })
    end

    -- `on_lines` rather than `TextChanged`: it catches every kind of change,
    -- including one made from a mapping or a script mid-command, and it fires
    -- as the change lands rather than on the way back to the main loop.
    -- Its callback runs in a context where the API is off limits, hence the
    -- `vim.schedule`; one pending pass is enough however many lines changed.
    local pending = false
    -- The counts do move on a single-line edit -- typing into a line is what
    -- makes it a change -- so unlike `sync_virt` the winbar cannot skip those.
    -- Throttled instead, since it costs a scan of every anchor and no one reads
    -- a counter mid-keystroke. `on_lines` runs where the API is off limits,
    -- hence the `vim.schedule` inside the throttled body rather than around it.
    local bump = throttle.throttle_wrap(120, function()
        vim.schedule(function() set_winbar(bufnr) end)
    end)
    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, _, _, first, last_old, last_new)
            if not _state[bufnr] then return true end -- detach with the panel
            bump()
            -- A change confined to one line cannot make an anchor's region
            -- empty or fill it again: no anchor moved relative to another, and
            -- none was added or removed. That is every keystroke of ordinary
            -- typing, and skipping it here keeps a large panel's edits from
            -- paying for a full anchor scan per character.
            if first + 1 == last_old and last_old == last_new then return end
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

--- The window showing the panel in the current tabpage, if it has one.
---@param bufnr integer
---@return integer? win
function M.win(bufnr)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then return win end
    end
end

--- Put the panel back on screen (or move the cursor into it, if it is already
--- there), leaving its contents -- unapplied edits included -- as they are.
---@param bufnr  integer
---@param height integer
function M.show(bufnr, height)
    show(bufnr, height)
end

--- Take the panel off screen -- every window showing it in this tabpage, so
--- that "off screen" is what it means even after the panel window was split.
--- The buffer stays (`bufhidden = "hide"`), so the list and any edits in it
--- survive until it is shown again.
---@param bufnr integer
---@return boolean closed  false if it was not on screen to begin with
function M.close(bufnr)
    local closed = false
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        -- The last window of a tabpage cannot be closed; leaving it be is a
        -- better answer than the error `nvim_win_close` would raise.
        if vim.api.nvim_win_get_buf(win) == bufnr
            and #vim.api.nvim_tabpage_list_wins(0) > 1 then
            vim.api.nvim_win_close(win, false)
            closed = true
        end
    end
    return closed
end

--- Width of the `file:line` column: the widest location in the list, but never
--- more than `path_width` -- one very deep path must not push every line of the
--- panel halfway across the window. Anything longer than that is cropped on the
--- left in `render`, so the column is exactly this wide.
---@param matches greplace.Match[]
---@return integer width
local function location_width(matches)
    local width = 0
    for _, m in ipairs(matches) do
        width = math.max(width, vim.fn.strdisplaywidth(m.relpath .. ":" .. m.lnum))
    end
    return math.min(width, math.max(config.options.path_width or width, 2))
end

--- Rewrite the whole buffer with undo turned off, so that `u` cannot walk back
--- past what was just drawn. The panel reuses one buffer across searches and
--- across the loading status that precedes each of them, and every one of those
--- is a write of the whole buffer: without this, an undo from a freshly
--- rendered result list restores the previous search -- or the blank
--- "searching ..." line -- and leaves anchors pointing at rows that no longer
--- hold their match. A change made while `undolevels` is -1 clears the undo
--- history along with itself (`:h clear-undo`), which is exactly the state the
--- panel wants: editable from here on, with nothing behind it.
---@param bufnr integer
---@param lines string[]
local function set_lines_no_undo(bufnr, lines)
    local levels = vim.api.nvim_get_option_value("undolevels", { buf = bufnr })
    vim.api.nvim_set_option_value("undolevels", -1, { buf = bufnr })
    local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("undolevels", levels, { buf = bufnr })
    if not ok then error(err) end
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
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_st, 0, -1)
    set_lines_no_undo(bufnr, lines)

    local width   = location_width(matches)
    state.entries = {}
    state.virt    = {}
    state.hidden  = {}

    for row, m in ipairs(matches) do
        -- Cropped on the left: the tail -- file name and line number -- is what
        -- tells one match from another, while the leading directories are the
        -- part they tend to share. `K` shows the whole path.
        local location = strutil.crop_for_ui(
            string.format("%s:%d", m.relpath, m.lnum), width, true)
        local pad      = string.rep(" ",
            math.max(0, width - vim.fn.strdisplaywidth(location)))
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
    set_winbar(bufnr)
end

--- Put a one-line status in the panel: the buffer holds a single blank,
--- unmodifiable line, and the message rides on it as virtual text so it can
--- never be mistaken for a result line to edit.
---@param bufnr integer
---@param chunks table[]  virtual text chunks, as `nvim_buf_set_extmark`
local function set_status(bufnr, chunks)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_hl, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_st, 0, -1)
    set_lines_no_undo(bufnr, { "" })
    vim.api.nvim_buf_set_extmark(bufnr, _ns_st, 0, 0, {
        virt_text     = chunks,
        virt_text_pos = "inline",
    })
    vim.bo[bufnr].modified   = false
    vim.bo[bufnr].modifiable = false
end

--- Replace the "searching" status with a final message -- "no matches", or
--- the error that ended the search. The panel stays up: it was opened on the
--- user's keystroke, and yanking it away again is more startling than leaving
--- it saying what happened.
---@param bufnr integer
---@param msg   string
---@param hl    string?
function M.set_message(bufnr, msg, hl)
    if not _state[bufnr] then return end
    _state[bufnr].message = msg
    set_status(bufnr, { { msg, hl or "GreplaceSeparator" } })
    set_winbar(bufnr, msg)
end

--- Open the panel before there are any results, showing the query and that the
--- search is running. `M.open` takes the same buffer over when it comes back.
---@param opts { query:string, root:string, flags:table?, height:integer, on_write:fun(bufnr:integer) }
---@return integer bufnr
function M.open_loading(opts)
    local bufnr   = M.find_buf() or create_buf(opts.on_write)
    _state[bufnr] = {
        query   = opts.query,
        root    = opts.root,
        flags   = opts.flags,
        source  = "search",
        entries = {},
        virt    = {},
        hidden  = {},
        truncated = false,
    }
    show(bufnr, opts.height)
    set_winbar(bufnr, "searching ...")
    set_status(bufnr, {
        { "searching for ", "GreplaceSeparator" },
        { opts.query,       "GreplaceMatch" },
        { " ...",           "GreplaceSeparator" },
    })
    return bufnr
end

--- Open (or reuse) the panel for a result set.
---@param matches  greplace.Match[]
---@param opts     { query:string, root:string, flags:table?, height:integer, truncated:boolean?, source:string?, on_write:fun(bufnr:integer) }
---@return integer bufnr
function M.open(matches, opts)
    local bufnr = M.find_buf() or create_buf(opts.on_write)
    _state[bufnr] = {
        query     = opts.query,
        root      = opts.root,
        flags     = opts.flags,
        -- Where the list came from, so a re-run knows what to run again: a
        -- search ("search", the default) or the quickfix list ("quickfix").
        source    = opts.source or "search",
        entries   = {},
        virt      = {},
        hidden    = {},
        truncated = opts.truncated or false,
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
--- splits the source line; an empty region -- the user deleted it from the
--- panel -- leaves the source line alone.
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
        -- `Label` rather than `Search`: the panel is an ordinary buffer that
        -- is searched with `/` like any other, and painting the matches in
        -- `Search` would leave the query's own hits indistinguishable from
        -- them.
        GreplaceMatch          = { link = "Label" },
        GreplaceLimit          = { link = "WarningMsg" },
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
