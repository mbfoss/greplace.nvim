local M = {}

-- ---------------------------------------------------------------------------
-- The `greplace://greplace-matches` scratch buffer.
--
-- Every line holds one matched line verbatim, so it can be edited as ordinary
-- text. The `file:line` location is not part of the line: it is inline virtual
-- text on an extmark anchored at column 0. That extmark is also the only record
-- of where a line came from, and because extmarks travel with the edits around
-- them, it still points at the right buffer row after lines have been inserted,
-- joined or deleted. `M.regions()` reads those anchors back at write time.
--
-- Every line stays one line: a change that adds one (`o`, a linewise put, a
-- `<CR>` typed mid-line) or joins two (`J`) is taken back as soon as it lands.
-- A line the user has edited is marked in front of its `│`.
-- ---------------------------------------------------------------------------

local config   = require("greplace.config").current
local util     = require("greplace.util")
local ui       = require("greplace.util.ui")
local strutil  = require("greplace.util.strutil")

local _buffer_name    = "greplace://greplace-matches"
local _ns      = vim.api.nvim_create_namespace("greplace.anchor")
local _ns_hl   = vim.api.nvim_create_namespace("greplace.match")
local _ns_st   = vim.api.nvim_create_namespace("greplace.status")

-- Drawn in front of the location of a match that came from a loaded buffer --
-- and so shows the buffer's text, which may not be what is on disk. A glyph
-- rather than only a highlight, which a colorscheme can leave looking like the
-- plain one.
local _buffer_indicator = "≡ "

-- Drawn in front of the `│` of a match whose line has been edited, so that the
-- lines a write would rewrite stand out from the column alone. Every row
-- reserves its width, so the `│` stays aligned whichever rows carry it.
local _changed_marker = "•"
local _no_marker      = string.rep(" ", vim.fn.strdisplaywidth(_changed_marker))

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
---@field order   integer[]  anchor extmark ids in listing order
---@field index   table<integer, integer>  each anchor's position in `order`
---@field virt    table<integer, table[]>  each anchor's virtual text chunks
---@field hidden  table<integer, boolean>  anchors whose line has been removed
---@field truncated boolean  the search stopped at the match limit, so this is
---                          the first `limit` matches of more
---@field message string?  final status -- "no matches", or the error that
---                       ended the search -- kept so a redraw can restore it
---@field changed table<integer, boolean>  anchors whose line no longer holds
---                       the text it was rendered with, and so draw the marker
---@field lines   string[]?  the buffer's lines, kept in step by `on_lines`; set
---                        once a result list is rendered
---@field changes { first:integer, count:integer, old:string[] }[]  the changes
---                        since the last check, in order: `count` lines from
---                        row `first` replaced `old`
---@field reverting boolean?  `guard_lines` is putting changes back, which are
---                        not themselves changes to record
---@field seq      integer?  the undo state (`seq_cur`) the last check saw
---@field seq_last integer?  the newest undo state (`seq_last`) the last check saw
---@field layouts  table<integer, table<integer, true>>?  the anchors hidden in
---                        each undo state, keyed by `seq_cur`, for putting the
---                        anchors back after an undo or redo
---@field stats   greplace.Stats?  the winbar's counts; set once a result list
---                        is rendered
---@field per_file table<string, integer>?  how many of each file's matches
---                        still have a line, for `stats.files`

---@type table<integer, greplace.PanelState>
local _state = {}

---@class greplace.Region
---@field entry greplace.Entry
---@field lines string[]  replacement text: 0 lines leaves the source alone

---@return integer? bufnr
function M.find_buf()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(bufnr):sub(- #_buffer_name) == _buffer_name
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

--- Which anchors have had their line removed. Deleting a line leaves its
--- anchor on the row of the next match's, so when anchors share a row, the
--- match that owns it is the last one listed there -- the highest extmark id,
--- since ids were handed out in listing order. Not the last in buffer order:
--- marks at one position come back in no particular order. An anchor pushed
--- past the end of the buffer has no line either. Removing a line drops that
--- match from the replacement; it never touches the file.
---@param bufnr integer
---@param marks integer[][]  as `nvim_buf_get_extmarks`, taking in every anchor
---                          of each row they reach
---@param total integer      the buffer's line count
---@return table<integer, boolean> empty  keyed by extmark id
local function empty_anchors(bufnr, marks, total)
    -- A buffer emptied outright (`ggdG`) still holds one empty line, which
    -- would otherwise read as "blank out the last source line" rather than as
    -- the "drop every match" that it plainly is.
    local blank = total == 1
        and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""

    local owner = {}
    for _, mark in ipairs(marks) do
        owner[mark[2]] = math.max(owner[mark[2]] or 0, mark[1])
    end
    local empty = {}
    for _, mark in ipairs(marks) do
        local id, row = mark[1], mark[2]
        empty[id] = blank or row >= total or owner[row] ~= id
    end
    return empty
end

--- Add a match to the winbar's counts (`n = 1`) or take it out (`n = -1`), as
--- its line comes back or is removed.
---@param state greplace.PanelState
---@param id    integer  anchor extmark id
---@param n     1|-1
local function tally(state, id, n)
    local stats, per_file = assert(state.stats), assert(state.per_file)
    local entry = state.entries[id]
    stats.lines = stats.lines + n
    if state.changed[id] then stats.changes = stats.changes + n end
    local left = (per_file[entry.path] or 0) + n
    per_file[entry.path] = left
    -- A file counts while any of its matches does.
    if left == (n > 0 and 1 or 0) then
        stats.files = stats.files + n
    end
end

--- Show or clear an anchor's changed marker. Its virtual text is re-set only
--- while it is drawn: a hidden anchor picks the marker up from `state.virt`
--- when `redraw` shows it again.
---@param bufnr   integer
---@param state   greplace.PanelState
---@param id      integer  anchor extmark id
---@param row     integer
---@param col     integer
---@param changed boolean
local function set_marker(bufnr, state, id, row, col, changed)
    local virt = state.virt[id]
    -- The marker is the chunk just before the `│`, the last one.
    virt[#virt - 1][1] = changed and _changed_marker or _no_marker
    if state.hidden[id] then return end
    vim.api.nvim_buf_set_extmark(bufnr, _ns, row, col, {
        id            = id,
        virt_text     = virt,
        virt_text_pos = "inline",
        right_gravity = false,
    })
end

--- Bring the anchors on rows `lo`..`hi` up to date with their lines, along
--- with the winbar's counts. A change to those rows cannot give a line to, or
--- take one from, an anchor on any other row -- row `hi` included, being where
--- the anchors of lines deleted just above it end up.
---
--- - a removed line's anchor stops drawing its location. Without this, that
---   anchor -- which survives, so that the write knows to leave that match
---   out -- would keep drawing its `file:line` inline on whatever row it
---   collapsed onto, stacked in front of that row's own location.
--- - the changed marker shows while a line no longer holds the text it was
---   rendered with.
---
--- An extmark is only re-set when what it draws changes: this runs on every
--- edit, and re-setting even a handful of anchors per keystroke is not free.
---@param bufnr integer
---@param lo    integer  0-indexed
---@param hi    integer  0-indexed, inclusive
local function redraw(bufnr, lo, hi)
    local state = _state[bufnr]
    if not state or not state.stats then return end

    local total = vim.api.nvim_buf_line_count(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { lo, 0 }, { hi, -1 }, {})
    local empty = empty_anchors(bufnr, marks, total)
    local lines = vim.api.nvim_buf_get_lines(bufnr, lo, math.min(hi + 1, total), false)
    for _, mark in ipairs(marks) do
        local id, row, col = mark[1], mark[2], mark[3]
        local hide = empty[id]
        if state.entries[id] and state.hidden[id] ~= hide then
            state.hidden[id] = hide
            tally(state, id, hide and -1 or 1)
            -- An anchor pushed past the last line (the final match's line
            -- removed) has no row to draw on and cannot be re-set at one
            -- either -- moving it back onto the last line would make the
            -- anchor above it look like the deleted one instead. It draws
            -- nothing as it is, so leave it be.
            if row < total then
                vim.api.nvim_buf_set_extmark(bufnr, _ns, row, col, {
                    id            = id,
                    virt_text     = not hide and state.virt[id] or nil,
                    virt_text_pos = "inline",
                    right_gravity = false,
                })
            end
        end
        if state.entries[id] and not hide and row < total then
            local changed = lines[row - lo + 1] ~= state.entries[id].text
            if changed ~= (state.changed[id] == true) then
                state.changed[id] = changed or nil
                state.stats.changes = state.stats.changes + (changed and 1 or -1)
                set_marker(bufnr, state, id, row, col, changed)
            end
        end
    end
end

--- Whether rows `lo`..`hi` no longer have one line per match: a row no anchor
--- sits on, which a change added, or an anchor part-way along a row, where a
--- change joined the line that anchor starts onto the one above it. Rows no
--- change touched still have theirs.
---@param bufnr integer
---@param lo    integer  0-indexed
---@param hi    integer  0-indexed, inclusive
---@return boolean
local function is_broken(bufnr, lo, hi)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local owned = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns, { lo, 0 }, { hi, -1 }, {})) do
        -- One pushed past the last line has no line of its own to break.
        if mark[2] < total then
            if mark[3] > 0 then return true end
            owned[mark[2]] = true
        end
    end
    for row = lo, math.min(hi, total - 1) do
        if not owned[row] then return true end
    end
    return false
end

--- Put every anchor back at the start of its match's line: the matches that
--- have a line take the rows in the order the search listed them (extmark ids
--- were handed out in that order), and one whose line was removed sits on the
--- next one's row, as a removed line's anchor does.
---@param bufnr integer
---@param state greplace.PanelState
---@return table<integer, integer> rows  each anchor's row, keyed by extmark id
---
--- `from` and `hi` narrow that to the anchors a change can have moved: from
--- the one at position `from` in `state.order`, which goes on row `lo`, up
--- to the first match with a line past row `hi` that is already where it
--- belongs -- as everything after it is then too. Without them, every anchor
--- is laid out.
---@param bufnr integer
---@param state greplace.PanelState
---@param from  integer?  position in `state.order` of the first anchor to lay out
---@param lo    integer?  0-indexed row it goes on
---@param hi    integer?  0-indexed last row a change reached, inclusive
---@return table<integer, integer> rows  the new row of each anchor laid out,
---                                      keyed by extmark id
local function relayout(bufnr, state, from, lo, hi)
    local order = state.order
    local rows, row, last = {}, lo or 0, #order
    for i = from or 1, #order do
        local id = order[i]
        if not state.hidden[id] then
            if hi and row > hi then
                local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns, id, {})
                if pos[1] == row and pos[2] == 0 then
                    last = i - 1
                    break
                end
            end
            rows[id], row = row, row + 1
        end
    end
    -- A removed match sits on the next listed match's row, or past the last
    -- line when there is none: where a removed line leaves its anchor.
    for i = last, from or 1, -1 do
        local id = order[i]
        if rows[id] then row = rows[id] else rows[id] = row end
    end
    for i = from or 1, last do
        local id = order[i]
        vim.api.nvim_buf_set_extmark(bufnr, _ns, rows[id], 0, {
            id            = id,
            virt_text     = not state.hidden[id] and state.virt[id] or nil,
            virt_text_pos = "inline",
            right_gravity = false,
            strict        = false,
        })
    end
    return rows
end

--- Take back a change that added a line to the panel or joined two of its
--- lines. A match is one source line, and the panel is edited line for line:
--- there is nowhere for a new line to go, and a joined line would be two
--- matches' text with the second one's `file:line` drawn in the middle of it.
---
--- Every change since the last check is reverted, newest first, from the old
--- text `on_lines` kept for it; that puts back what 'autoindent' dropped from
--- a line broken with `<CR>`, which joining the halves again would not. The
--- revert is joined to the change's undo block, so that `u` never walks back
--- into the broken state. The cursor stays on the same character of the same
--- match's line, as near as it can.
---@param bufnr integer
---@param lo    integer  0-indexed first row the changes touched
---@param hi    integer  0-indexed last row, inclusive
---@return boolean reverted
local function guard_lines(bufnr, lo, hi)
    local state = _state[bufnr]
    if not state or not state.changes then return false end
    local changes = state.changes
    state.changes = {}

    -- A change confined to one line can neither add a line nor join two.
    local reshaped = vim.iter(changes):any(function(c) return c.count ~= 1 or #c.old ~= 1 end)
    if not reshaped or not next(state.entries) or not is_broken(bufnr, lo, hi) then
        return false
    end

    -- Where the cursor goes: as far into its match's line as it is now, the
    -- match being the last one to start at or before it.
    local cur = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)
    local at, offset = nil, cur and cur[2] or 0
    if cur then
        local mark = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { cur[1] - 1, cur[2] }, 0, { limit = 1 })[1]
        if mark then
            at, offset = mark[1], cur[2] - mark[3]
            for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, mark[2], cur[1] - 1, false)) do
                offset = offset + #line
            end
        end
    end

    -- The anchors from the owner of row `lo - 1` up are where they belong:
    -- no change reached them. Of the anchors on a row, the owner is the one
    -- listed last (see `empty_anchors`).
    local from = 1
    if lo > 0 then
        local owner = 0
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns, { lo - 1, 0 }, { lo - 1, -1 }, {})) do
            owner = math.max(owner, m[1])
        end
        from = (state.index[owner] or 0) + 1
    end
    local total = vim.api.nvim_buf_line_count(bufnr)

    pcall(vim.cmd.undojoin)
    state.reverting = true
    local ok, err = pcall(function()
        for i = #changes, 1, -1 do
            local c = changes[i]
            vim.api.nvim_buf_set_lines(bufnr, c.first, c.first + c.count, false, c.old)
        end
    end)
    state.reverting = false
    if not ok then error(err) end

    -- The revert changed no line past row `hi` but moved them all by the
    -- lines it put back or took away.
    local rows = relayout(bufnr, state, from, lo,
        hi + vim.api.nvim_buf_line_count(bufnr) - total)
    if cur then
        local row = at and (rows[at] or vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns, at, {})[1]) or 0
        local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, math.min(offset, #text) })
    end
    vim.api.nvim_echo({ { "greplace: panel lines cannot be added or joined; change reverted",
        "WarningMsg" } }, false, {})
    return true
end

--- Where the buffer stands in its undo history.
---@param bufnr integer
---@return integer seq_cur
---@return integer seq_last
local function undo_seq(bufnr)
    local tree = vim.fn.undotree(bufnr)
    return tree.seq_cur, tree.seq_last
end

--- Note which anchors are hidden in the undo state the buffer is in, for
--- `restore_layout` to go back to.
---@param state greplace.PanelState
---@param seq   integer
local function save_layout(state, seq)
    local hidden = {}
    for id, hide in pairs(state.hidden) do
        if hide then hidden[id] = true end
    end
    state.layouts[seq] = hidden
end

--- Put the anchors back after an undo or redo. Every undo state holds one line
--- per match -- a change that broke that was reverted within its own undo
--- block -- but undo and redo replay a reverted change and its revert without
--- the `relayout` that followed them, leaving anchors on the wrong rows or
--- part-way along one. Reverting that would be wrong twice over: the lines
--- are right, and the revert would be a new change, branching the undo tree
--- off the state `u` or `<C-r>` just reached. So the anchors are laid out
--- afresh instead, hiding the matches that were hidden in that state.
---@param bufnr integer
---@param state greplace.PanelState
---@param seq   integer
local function restore_layout(bufnr, state, seq)
    local hidden = state.layouts[seq]
    if hidden then
        for id in pairs(state.entries) do
            local hide = hidden[id] == true
            if state.hidden[id] ~= hide then
                state.hidden[id] = hide
                tally(state, id, hide and -1 or 1)
            end
        end
    end
    relayout(bufnr, state)
    redraw(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

---@class greplace.Stats
---@field files   integer  distinct files still listed
---@field lines   integer  matches still listed (a removed one does not count)
---@field changes integer  listed matches whose text no longer matches the source

--- What the panel currently holds. A removed line drops out of every count --
--- it is no longer part of the replacement. The counts are kept up to date by
--- `redraw`, which runs shortly after an edit rather than within it.
---@param bufnr integer
---@return greplace.Stats?  nil when the buffer is not a rendered panel
function M.stats(bufnr)
    local state = _state[bufnr]
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
---@param status string?
local function set_winbar(bufnr, status)
    if not config.winbar then return end
    if not _state[bufnr] then return end

    -- A final message outlives the buffer write that showed it, so that any
    -- redraw of the winbar puts it back rather than the counts of an empty
    -- panel.
    local text = status or _state[bufnr].message
    if not text then
        local st = M.stats(bufnr)
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
    local st    = M.stats(bufnr)
    if _state[bufnr].truncated and (not st or st.lines >= config.limit) then
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
    local mark = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { row, -1 }, 0, { limit = 1 })[1]
    if not mark then return end
    -- Of the anchors on that row, the match that owns it (see `empty_anchors`).
    local id = mark[1]
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns, { mark[2], 0 }, { mark[2], -1 }, {})) do
        id = math.max(id, m[1])
    end
    return state.entries[id], mark[2]
end

--- Open the source of the line under the cursor, in a regular window (never
--- over the panel itself), on the line the match came from. The cursor stays
--- in the panel, so that going down the list shows one match after another.
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
    if ui.smart_open_file(entry.path, entry.lnum, target_col, false) == -1 then
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

--- Move to the edited line nearest the cursor in the direction `dir`, the way
--- `]c`/`[c` step through a diff. `v:count1` times over, so `3]c` moves three
--- edits along; a count that runs off the end stops at the last edit there is
--- rather than going nowhere, which is what makes a large count a way to reach
--- the end of the list.
---@param bufnr integer
---@param dir   integer  1 forwards, -1 backwards
local function goto_change(bufnr, dir)
    local state = _state[bufnr]
    if not state then return end
    if not state.stats or state.stats.changes == 0 then
        vim.api.nvim_echo({ { "greplace: nothing has been edited" } }, false, {})
        return
    end

    local row  = vim.api.nvim_win_get_cursor(0)[1] - 1
    local last = vim.api.nvim_buf_line_count(bufnr) - 1
    -- Strictly past the cursor: sitting on an edit, `]c` moves off it rather
    -- than staying put. With no row left on that side there is nothing to ask
    -- for, and asking anyway would be a range starting outside the buffer.
    if (dir > 0 and row >= last) or (dir < 0 and row <= 0) then
        vim.api.nvim_echo({ { "greplace: no more edits" } }, false, {})
        return
    end

    -- Walked from the cursor rather than gathered and sorted: the anchors come
    -- back in the order they are asked for, so the first edited one found is
    -- the one to move to, and a panel holding thousands of matches is only
    -- walked as far as the next edit. `state.changed` is keyed by anchor, and
    -- an anchor's row is where its line begins, so the row it gives is the
    -- edited line itself. Deleting a line leaves its anchor on the row of the
    -- next one, so an edited row can be reached twice over; being in order,
    -- those repeats are neighbours, and comparing against the row in hand is
    -- enough to count it once.
    local from = dir > 0 and { row + 1, 0 } or { row - 1, -1 }
    local to   = dir > 0 and -1 or 0
    local left, target = vim.v.count1, nil
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns, from, to, {})) do
        if state.changed[mark[1]] and mark[2] ~= target then
            target = mark[2]
            left   = left - 1
            -- The rest of the walk is what a count asked for; the edits beyond
            -- it are no business of this one.
            if left == 0 then break end
        end
    end
    if not target then
        vim.api.nvim_echo({ { "greplace: no more edits" } }, false, {})
        return
    end
    -- A jump, so `''` and `<C-o>` come back to where the cursor was.
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

--- Replace `list[first + 1 .. last]` with `new`, in place: the tail is shifted
--- once, so a change that adds or removes lines allocates no second copy of a
--- list as long as the panel.
---@param list  string[]
---@param first integer
---@param last  integer
---@param new   string[]
local function splice(list, first, last, new)
    local n, shift = #list, #new - (last - first)
    if shift > 0 then
        for i = n, last + 1, -1 do list[i + shift] = list[i] end
    elseif shift < 0 then
        for i = last + 1, n do list[i + shift] = list[i] end
        for i = n, n + shift + 1, -1 do list[i] = nil end
    end
    for i, line in ipairs(new) do list[first + i] = line end
end

---@param on_write  fun(bufnr:integer)  `:w` in the panel
---@param on_delete fun()?  the panel was deleted or wiped out
---@return integer bufnr
local function create_buf(on_write, on_delete)
    -- Set here rather than at startup: the groups are `default` links, which a
    -- later `:colorscheme` clears, and nothing needs them before there is a
    -- panel to draw.
    M.setup_highlights()

    -- Defined with the line watch below, and called from the reload, which
    -- detaches it.
    ---@type fun()
    local watch
    ---@type integer
    local group

    local bufnr
    -- `acwrite`, where a scratch buffer is `nofile`: `:w` is how the edits are
    -- applied. `hide`, so that closing the panel's window keeps the list.
    -- The filetype is not among these options: they are set in no particular
    -- order, and `FileType` handlers should find the buffer as it will stay,
    -- `acwrite` and named, so it is set below, after the name.
    bufnr = ui.create_scratch_buffer(false, {
        buftype   = "acwrite",
        bufhidden = "hide",
    }, function()
        -- The list ends with the buffer: nothing is left to apply, and the
        -- search filling it has nowhere to land.
        _state[bufnr] = nil
        pcall(vim.api.nvim_del_augroup_by_id, group)
        if on_delete then on_delete() end
    end)
    vim.api.nvim_buf_set_name(bufnr, _buffer_name)
    vim.bo[bufnr].filetype = "greplace"

    -- `:bdelete` on an unlisted buffer fires no `BufDelete`: it only unloads
    -- it, leaving a husk -- empty, unwatched, still named like the panel --
    -- that would be found and shown again as though it held a list. So an
    -- unload is made a wipe, which the callback above does see. Not on the
    -- spot: `:edit` unloads too, then refills the buffer through `BufReadCmd`
    -- (below) before anything else runs, and a reload is not the panel's end;
    -- an unload that is still one once the event loop comes round is.
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer   = bufnr,
        desc     = "greplace: a panel unloaded for good is wiped out",
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) and not vim.api.nvim_buf_is_loaded(bufnr) then
                    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
                end
            end)
        end,
    })
    -- A line broken in the panel is always taken back, so indenting the new
    -- one is of no use -- and it does harm: Vim remembers having indented it,
    -- and on <Esc> deletes that "indent", which after the revert is the white
    -- space at the cursor on the restored line. Every option that sets that
    -- off goes, a comment leader inserted by <CR> included. After `filetype`,
    -- whose ftplugins could set them again.
    vim.bo[bufnr].autoindent    = false
    vim.bo[bufnr].smartindent   = false
    vim.bo[bufnr].cindent       = false
    vim.bo[bufnr].indentexpr    = ""
    vim.bo[bufnr].formatoptions = vim.bo[bufnr].formatoptions:gsub("[ro]", "")

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        desc   = "greplace: apply edits to buffers in memory",
        -- `nested`, because the write loads the files it edits into buffers:
        -- without it their `BufReadPost`/`FileType` never fire (autocommands
        -- do not nest by default), so those buffers come up with no filetype
        -- and hence no syntax, treesitter or LSP -- and stay that way, being
        -- already loaded by the time the user opens one.
        nested = true,
        callback = function()
            -- Nothing to apply once the buffer no longer holds a list -- it
            -- was reloaded out from under the panel (see `BufReadCmd`), and
            -- its lines belong to no match.
            if not _state[bufnr] then
                vim.bo[bufnr].modified = false
                return
            end
            on_write(bufnr)
        end,
    })
    -- `:edit` reloads the buffer: Neovim empties it and leaves the filling to
    -- `BufReadCmd`. There is no file behind `greplace://greplace-matches` to
    -- fill it from -- the panel is only ever written into by a search -- so the
    -- reload leaves it empty, and everything drawn on the list it held goes
    -- with it.
    -- Left behind, the anchors would all collapse onto the one remaining row
    -- and draw every `file:line` in the panel stacked on it, and a write would
    -- take that row's text for all of their matches.
    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = bufnr,
        desc   = "greplace: a reload leaves an empty panel, not a stale one",
        callback = function()
            _state[bufnr] = nil
            vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
            vim.api.nvim_buf_clear_namespace(bufnr, _ns_hl, 0, -1)
            vim.api.nvim_buf_clear_namespace(bufnr, _ns_st, 0, -1)
            vim.bo[bufnr].modifiable = true
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == bufnr then
                    vim.wo[win].winbar = ""
                end
            end
            watch()
        end,
    })
    -- Unapplied edits must not turn into an "unsaved changes" prompt on the
    -- way out of Neovim: writing the panel rewrites source files, which is not
    -- a question to answer at that point -- and answering "yes" there would
    -- apply the edits to buffers that are about to be discarded. The panel is
    -- dropped instead, like the scratch buffer it is.
    group = vim.api.nvim_create_augroup("greplace.panel." .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("ExitPre", {
        group = group,
        desc  = "greplace: never prompt to save the panel on exit",
        callback = function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.bo[bufnr].modified = false
            end
        end,
    })
    if config.keys.open and config.keys.open ~= "" then
        vim.keymap.set("n", config.keys.open, function() jump(bufnr) end, {
            buffer = bufnr,
            desc   = "greplace: open the source of the line under the cursor",
        })
    end
    if config.keys.hover and config.keys.hover ~= "" then
        vim.keymap.set("n", config.keys.hover, function() hover(bufnr) end, {
            buffer = bufnr,
            desc   = "greplace: show the full details of the match under the cursor",
        })
    end
    -- Not among `config.keys`: `]c`/`[c` mean "the next change" wherever they
    -- are bound, and they are the panel's own, taking nothing a user might
    -- want back -- unlike `<CR>` and `K`.
    vim.keymap.set("n", "]c", function() goto_change(bufnr, 1) end, {
        buffer = bufnr,
        desc   = "greplace: move to the next edited line",
    })
    vim.keymap.set("n", "[c", function() goto_change(bufnr, -1) end, {
        buffer = bufnr,
        desc   = "greplace: move to the previous edited line",
    })

    -- `on_lines` rather than `TextChanged`: it catches every kind of change,
    -- including one made from a mapping or a script mid-command, and it fires
    -- as the change lands rather than on the way back to the main loop.
    -- Its callback runs in a context where the API is off limits, hence the
    -- `vim.schedule`; one pending pass is enough however many lines changed.
    -- The rows that pass has to look at, `{ first, last }` (inclusive), in the
    -- buffer's current numbering: every row a change since the last pass
    -- touched, and the row below, where the anchors of deleted lines land.
    ---@type integer[]?
    local pending  = nil
    local attached = false
    -- Watching the lines is not a one-off. `:edit` unloads the buffer before
    -- `BufReadCmd` fills it again, and an unload detaches every listener on
    -- it -- `on_detach`, not `on_reload`, a buffer read by `BufReadCmd` being
    -- one Neovim does not offer a reload. The buffer itself survives, and the
    -- next search reuses it rather than going back through `create_buf`, so
    -- the reload has to attach again or the panel comes back unwatched: no
    -- mirror, no guard, and no redraw behind an edit. Attaching twice would
    -- be no better than not at all -- every change spliced into the mirror
    -- and recorded twice over -- hence the flag rather than a second attach
    -- on trust.
    watch = function()
        if attached then return end
        attached = true
        pending  = nil
        vim.api.nvim_buf_attach(bufnr, false, {
            on_detach = function() attached = false end,
            on_lines = function(_, _, _, first, last_old, last_new)
                -- Nothing to keep in step with: the list was thrown away by
                -- a reload, and the lines left are no match's.
                local state = _state[bufnr]
                if not state then return end
                -- Keep the mirror in step, and note what the change replaced so
                -- that `guard_lines` can put it back. A buffer emptied outright is
                -- reported as holding no lines, though it keeps one empty line,
                -- which the next change then reports replacing.
                local mirror = state.lines
                if mirror then
                    local old   = vim.list_slice(mirror, first + 1, last_old)
                    local count = last_new - first
                    splice(mirror, first, last_old,
                        vim.api.nvim_buf_get_lines(bufnr, first, last_new, false))
                    if #mirror == 0 then mirror[1], count = "", 1 end
                    if not state.reverting then
                        table.insert(state.changes, { first = first, count = count, old = old })
                    end
                end

                if pending then
                    -- Rows below the change move with it; a row inside the lines
                    -- it replaced is now somewhere among the new ones.
                    local last = pending[2]
                    if last >= last_old then
                        last = last + last_new - last_old
                    elseif last > first then
                        last = last_new
                    end
                    pending[1] = math.min(pending[1], first)
                    pending[2] = math.max(last, last_new)
                    return
                end
                pending = { first, last_new }
                vim.schedule(function()
                    -- A reload between the change and this pass takes the
                    -- rows to look at with it (`watch`), and leaves no list
                    -- to look at them against either.
                    if not pending then return end
                    local lo, hi = pending[1], pending[2]
                    pending = nil
                    local st = _state[bufnr]
                    if not st or not vim.api.nvim_buf_is_valid(bufnr) then return end
                    -- An undo or redo moves to another undo state without
                    -- adding one; a new change always adds one.
                    local seq, seq_last = undo_seq(bufnr)
                    if st.layouts and seq_last == st.seq_last and seq ~= st.seq then
                        st.changes = {}
                        if is_broken(bufnr, lo, hi) then
                            restore_layout(bufnr, st, seq)
                        else
                            redraw(bufnr, lo, hi)
                        end
                    else
                        -- Before the redraw, which would record the broken
                        -- state's removed lines as the ones to keep hidden. A
                        -- revert is a change of its own, which gets a pass of
                        -- its own.
                        if guard_lines(bufnr, lo, hi) then return end
                        redraw(bufnr, lo, hi)
                    end
                    if st.layouts then
                        st.seq, st.seq_last = seq, seq_last
                        save_layout(st, seq)
                    end
                    if st.stats then set_winbar(bufnr) end
                end)
            end,
        })
    end
    watch()
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
    return math.min(width, math.max(config.path_width or width, 2))
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
    state.order   = {}
    state.index   = {}
    state.virt    = {}
    state.hidden  = {}
    state.changed = {}
    state.lines   = lines
    state.changes = {}
    state.seq, state.seq_last = undo_seq(bufnr)
    state.layouts = { [state.seq] = {} }
    state.stats   = { files = 0, lines = 0, changes = 0 }
    state.per_file = {}

    -- The indicator column is only drawn when some match needs it, so a search
    -- that touched no open buffer gives up no width to it. When drawn, every
    -- row reserves it, keeping the locations and the `│` aligned.
    local indicator = false
    for _, m in ipairs(matches) do
        if m.bufnr then indicator = true; break end
    end

    for row, m in ipairs(matches) do
        -- Cropped on the left: the tail -- file name and line number -- is what
        -- tells one match from another, while the leading directories are the
        -- part they tend to share. `K` shows the whole path.
        local location = strutil.crop_for_ui(
            string.format("%s:%d", m.relpath, m.lnum), width, true)
        local pad      = string.rep(" ",
            math.max(0, width - vim.fn.strdisplaywidth(location)))
        local virt     = {
            { location,          "GreplaceLocation" },
            { pad .. " ",        "GreplaceSeparator" },
            { _no_marker,        "GreplaceChanged" },
            { "│ ",              "GreplaceSeparator" },
        }
        if indicator then
            table.insert(virt, 1, {
                m.bufnr and _buffer_indicator
                    or string.rep(" ", vim.fn.strdisplaywidth(_buffer_indicator)),
                "GreplaceBufferIndicator",
            })
        end
        local ok, id   = pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, row - 1, 0, {
            virt_text     = virt,
            virt_text_pos = "inline",
            -- Text typed at the start of a line belongs after the location, so
            -- the anchor must not drift right with it.
            right_gravity = false,
        })
        -- An anchor that could not be placed would silently drop its match from
        -- the list the panel writes back, and every later row would still look
        -- fine -- so the whole render is abandoned instead, and the caller says
        -- so. Half a result set is worse than none: the user would edit it
        -- believing it was all of them.
        if not ok then
            error(string.format("%s:%d: could not anchor result: %s",
                m.relpath, m.lnum, tostring(id)), 0)
        end
        state.virt[id]    = virt
        state.hidden[id]  = false
        state.order[row]  = id
        state.index[id]   = row
        state.entries[id] = {
            path    = m.path,
            relpath = m.relpath,
            lnum    = m.lnum,
            text    = m.text,
        }
        tally(state, id, 1)
        -- Both ends are clamped, not just the end one: a match span can start
        -- past the line we kept (rg counts the line terminator it stripped,
        -- and a `$`-anchored pattern lands there), and an out-of-range start
        -- column is an error, not a no-op.
        local len = #m.text
        for _, sm in ipairs(m.subs) do
            local s = math.max(0, math.min(sm.s, len))
            local e = math.max(s, math.min(sm.e, len))
            if e > s then
                local hl_ok, hl_err = pcall(vim.api.nvim_buf_set_extmark,
                    bufnr, _ns_hl, row - 1, s, {
                        end_col  = e,
                        hl_group = "GreplaceMatch",
                    })
                if not hl_ok then
                    error(string.format("%s:%d: could not highlight match at %d-%d: %s",
                        m.relpath, m.lnum, s, e, tostring(hl_err)), 0)
                end
            end
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
    set_status(bufnr, { { msg, hl or "GreplaceStatus" } })
    set_winbar(bufnr, msg)
end

--- Open the panel before there are any results, showing the query and that the
--- search is running. `M.open` takes the same buffer over when it comes back.
---@param opts { query:string, root:string, flags:table?, height:integer, on_write:fun(bufnr:integer), on_delete:fun()? }
---@return integer bufnr
function M.open_loading(opts)
    local bufnr   = M.find_buf() or create_buf(opts.on_write, opts.on_delete)
    _state[bufnr] = {
        query   = opts.query,
        root    = opts.root,
        flags   = opts.flags,
        source  = "search",
        entries = {},
        order   = {},
        index   = {},
        virt    = {},
        hidden  = {},
        truncated = false,
        changed   = {},
        changes   = {},
    }
    show(bufnr, opts.height)
    set_winbar(bufnr, "searching ...")
    set_status(bufnr, {
        { "searching for ", "GreplaceStatus" },
        { opts.query,       "GreplaceMatch" },
        { " ...",           "GreplaceStatus" },
    })
    return bufnr
end

--- Open (or reuse) the panel for a result set.
---@param matches  greplace.Match[]
---@param opts     { query:string, root:string, flags:table?, height:integer, truncated:boolean?, source:string?, on_write:fun(bufnr:integer), on_delete:fun()? }
---@return integer bufnr
---@return string? err  the list could not be rendered; the panel shows why and
---                     holds nothing editable
function M.open(matches, opts)
    local bufnr = M.find_buf() or create_buf(opts.on_write, opts.on_delete)
    _state[bufnr] = {
        query     = opts.query,
        root      = opts.root,
        flags     = opts.flags,
        -- Where the list came from, so a re-run knows what to run again: a
        -- search ("search", the default) or the quickfix list ("quickfix").
        source    = opts.source or "search",
        entries   = {},
        order     = {},
        index     = {},
        virt      = {},
        hidden    = {},
        truncated = opts.truncated or false,
        changed   = {},
        changes   = {},
    }
    show(bufnr, opts.height)
    local ok, err = pcall(render, bufnr, matches)
    if not ok then
        -- Leave the panel holding the error rather than a list that is missing
        -- rows without saying which: `set_status` also makes it unmodifiable,
        -- so nothing can be written back from a render that did not finish.
        M.set_message(bufnr, "render failed: " .. tostring(err), "ErrorMsg")
        return bufnr, tostring(err)
    end
    return bufnr
end

--- Re-render the panel from entries that were just applied, so the shown lines
--- and line numbers match the buffers again.
---@param bufnr   integer
---@param entries greplace.Entry[]  in display order
---@return string? err  as `M.open`
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
    local ok, err = pcall(render, bufnr, matches)
    if not ok then
        M.set_message(bufnr, "render failed: " .. tostring(err), "ErrorMsg")
        return tostring(err)
    end
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
            -- Up to the next row an anchor sits on: the anchors on this one
            -- are the removed matches' ones, in no particular order.
            local stop = total
            for j = i + 1, #marks do
                if marks[j][2] > row then stop = marks[j][2]; break end
            end
            out[#out + 1] = {
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
        GreplaceLocation        = { link = "Directory" },
        GreplaceBufferIndicator = { link = "Special" },
        -- `NonText` rather than `Comment`: the plain `│` is scaffolding, and
        -- the dimmer it is, the more the `│` of an edited line stands out.
        GreplaceSeparator       = { link = "NonText" },
        -- The winbar's counts and the panel's status are words to read rather
        -- than scaffolding, so they keep `Comment` instead of following the
        -- separator down to `NonText`.
        GreplaceStatus          = { link = "Comment" },
        -- `Label` rather than `Search`: the panel is an ordinary buffer that
        -- is searched with `/` like any other, and painting the matches in
        -- `Search` would leave the query's own hits indistinguishable from
        -- them.
        GreplaceMatch           = { link = "Label" },
        GreplaceLimit           = { link = "WarningMsg" },
        GreplaceChanged         = { link = "NonText" },
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
