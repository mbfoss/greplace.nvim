local M = {}

-- ---------------------------------------------------------------------------
-- The `greplace://greplace-matches` scratch buffer.
--
-- Every line holds one matched line verbatim, so it can be edited as ordinary
-- text. The `file:line` location is not part of the line: it is inline virtual
-- text on an extmark anchored at the start of the line. That anchor is the
-- record of the list -- which match a row belongs to, and whether a match
-- still has a row at all -- and `M.regions()` reads it back at write time. It
-- draws, so it keeps the plain gravity that leaves it in front of a line
-- whatever is typed there.
--
-- A second extmark, drawing nothing, spans each match's text from its first
-- byte to its last. Its gravity points inward -- the start stays with the text
-- to its right, the end with the text to its left -- so it stays glued to the
-- text it was set around rather than growing with what is typed at either end.
-- That is what makes a change that broke the panel's one line per match
-- readable off the marks alone, and repairable without anything being
-- remembered on the side (`repair`):
--
--   * a match's text ending on a later row than it starts -- its line was
--     broken in two, or a line was put in front of it: join the rows back up;
--   * two matches' text starting on one row -- their lines were joined: split
--     the row where the second one starts, dropping whatever the join itself
--     left at the seam (`J` inserts a space);
--   * a row no match's text reaches -- a line was added: delete it.
--
-- A repair is joined to the change that made it necessary (`undojoin`), so
-- every undo state holds one line per match and undo and redo need no help of
-- their own.
--
-- The anchor follows, put back on the row and column its match's text says it
-- belongs on. The bounds are put back likewise once an edit has landed
-- (`redraw`), so neither mark drifts from the line for longer than a keystroke.
--
-- Undo and redo are the one change no line is touched for: every state the
-- undo tree holds is one the panel put in shape when it was made, so its text
-- is right by definition -- while its marks may not be, a replayed change
-- being whole lines replaced, which drags the marks inside them to one row.
-- There the marks are laid out from the listing instead (`restore_marks`),
-- which is what the two integers of undo state in `PanelState` are for.
--
-- The anchor spans its whole line (`invalidate`), so deleting the line hides
-- the anchor rather than leaving it stacked on the next one's row, and the
-- mark alone says whether the match still has a line. Undo and redo restore an
-- anchor's position and its validity along with the text (`undo_restore`), so
-- a match removed in one undo state is removed again whenever that state is
-- returned to, with no record of the states kept on the side.
--
-- A line the user has edited is marked in front of its `│`.
-- ---------------------------------------------------------------------------

local config   = require("greplace.config").current
local util     = require("greplace.util")
local ui       = require("greplace.util.ui")
local strutil  = require("greplace.util.strutil")

local _buffer_name    = "greplace://greplace-matches"
local _ns      = vim.api.nvim_create_namespace("greplace.anchor")
-- The bounds of each match's text, keyed by its anchor's id.
local _ns_bounds = vim.api.nvim_create_namespace("greplace.bounds")
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
---@field hidden  table<integer, boolean>  which anchors are invalid -- their
---                        line was removed -- as of the last `redraw`, so that
---                        the counts can follow a match dropping out of the
---                        list and coming back
---@field truncated boolean  the search stopped at the match limit, so this is
---                          the first `limit` matches of more
---@field message string?  final status -- "no matches", or the error that
---                       ended the search -- kept so a redraw can restore it
---@field changed table<integer, boolean>  anchors whose line no longer holds
---                       the text it was rendered with, and so draw the marker
---@field ticks   integer?  how many changes the line watch has seen, which is
---                        how a spec tells one watch from two
---@field seq      integer?  the undo state the last pass saw, and
---@field seq_last integer?  the newest one there was: an undo or a redo moves
---                        between states without adding one, and that is the
---                        one change whose text needs nothing done to it
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
        -- The whole name, not its tail: a URL-like name is stored as written
        -- rather than expanded against the cwd, so the panel's is exactly
        -- this -- and a file whose path merely ends in it is not the panel.
        if vim.api.nvim_buf_get_name(bufnr) == _buffer_name
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

--- Set (or move) an anchor, spanning the text of row `row`.
---
--- The span is what makes the mark the one record of the list: deleting the
--- line deletes the span in full, which invalidates the mark -- it stops
--- drawing its location and reads back as a match with no line -- and undo
--- puts both the span and its validity back (`undo_restore`), so an undo or
--- redo needs nothing remembered on the side to land on the right list.
---
--- The whole line, up to the start of the next: an edit that rewrites a line's
--- text (`cc`, `C`, `:s`) leaves the newline, and so the span, in place.

---@param bufnr integer
---@param state greplace.PanelState
---@param id    integer?  anchor extmark id, or nil for a new anchor
---@param row   integer   0-indexed
---@param virt  table[]?  the chunks to draw, for an anchor that has no id yet
---@return integer id
local function set_anchor(bufnr, state, id, row, virt)
    return vim.api.nvim_buf_set_extmark(bufnr, _ns, row, 0, {
        id            = id,
        virt_text     = virt or state.virt[id],
        virt_text_pos = "inline",
        -- Plain gravity: the location is drawn in front of the line, and
        -- text typed at the start of one belongs after it rather than before.
        -- The anchor is not what says where a match's text is -- its bounds
        -- are -- so it gives up nothing by staying put; `repair` moves it to
        -- the row they end up on.
        right_gravity     = false,
        end_row           = row + 1,
        end_col           = 0,
        end_right_gravity = true,
        invalidate        = true,
        undo_restore      = true,
        strict            = false,
    })
end

--- Span a match's text -- the whole of row `row`, `len` bytes of it -- with
--- the hidden mark that says where its line begins and ends. Under the
--- anchor's own id, marks being numbered per namespace.
---
--- Both ends point inward: the start has right gravity, so text put in front
--- of it is outside the span rather than carried along, and the end has left
--- gravity, so text appended past it is outside it too. The span therefore
--- stays on the text it was set around, and the line's own shape is what moves
--- it: a newline typed *in* the line carries its end down to the next row,
--- while one typed at either edge leaves it where it is. That is a line broken
--- in two and a line added, told apart.
---
--- It draws nothing and never invalidates: whether a match still has a line is
--- the anchor's to say.
---@param bufnr integer
---@param id    integer  the anchor's extmark id
---@param row   integer  0-indexed
---@param len   integer  the length of the line
local function set_bounds(bufnr, id, row, len)
    vim.api.nvim_buf_set_extmark(bufnr, _ns_bounds, row, 0, {
        id                = id,
        end_row           = row,
        end_col           = len,
        right_gravity     = true,
        end_right_gravity = false,
        undo_restore      = true,
        strict            = false,
    })
end

--- Where a match's text begins and ends.
---@param bufnr integer
---@param id    integer  the anchor's extmark id
---@return integer srow, integer scol, integer erow, integer ecol
local function get_bounds(bufnr, id)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns_bounds, id,
        { details = true })
    local row, col = mark[1] or 0, mark[2] or 0
    local details  = mark[3] or {}
    return row, col, details.end_row or row, details.end_col or col
end

--- Whether an anchor still has a line: an invalid mark is one whose line was
--- deleted, and its match drops out of the replacement until an undo brings
--- the line back. It never touches the file.
---@param mark table  one `nvim_buf_get_extmarks` entry, asked with `details`
---@return boolean
local function is_hidden(mark)
    return mark[4].invalid == true
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

--- Show or clear an anchor's changed marker.
---@param bufnr   integer
---@param state   greplace.PanelState
---@param id      integer  anchor extmark id
---@param row     integer
---@param changed boolean
local function set_marker(bufnr, state, id, row, changed)
    local virt = state.virt[id]
    -- The marker is the chunk just before the `│`, the last one.
    virt[#virt - 1][1] = changed and _changed_marker or _no_marker
    set_anchor(bufnr, state, id, row)
end

--- Bring the anchors on rows `lo`..`hi` up to date with their lines, along
--- with the winbar's counts. A change to those rows cannot give a line to, or
--- take one from, an anchor on any other row -- row `hi` included, being where
--- the anchors of lines deleted just above it end up.
---
--- Hiding a removed match's location needs nothing done here: its anchor's
--- span went with the line, and an invalid mark draws nothing. What is left is
--- the bookkeeping the marks cannot do -- the winbar's counts following a
--- match out of the list and back in -- and the changed marker, which shows
--- while a line no longer holds the text it was rendered with.
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
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { lo, 0 }, { hi, -1 },
        { details = true })
    local lines = vim.api.nvim_buf_get_lines(bufnr, lo, math.min(hi + 1, total), false)
    for _, mark in ipairs(marks) do
        local id, row = mark[1], mark[2]
        local hide    = is_hidden(mark)
        if state.entries[id] then
            if state.hidden[id] ~= hide then
                state.hidden[id] = hide
                tally(state, id, hide and -1 or 1)
            end
            if not hide and row < total then
                local text    = lines[row - lo + 1]
                local changed = text ~= state.entries[id].text
                if changed ~= (state.changed[id] == true) then
                    state.changed[id] = changed or nil
                    state.stats.changes = state.stats.changes + (changed and 1 or -1)
                    set_marker(bufnr, state, id, row, changed)
                end
                -- And the bounds back around the line, which the edit may
                -- have grown or shrunk at either end without moving them.
                local srow, scol, erow, ecol = get_bounds(bufnr, id)
                if srow ~= row or scol ~= 0 or erow ~= row or ecol ~= #text then
                    set_bounds(bufnr, id, row, #text)
                end
            end
        end
    end
end

--- The anchor of the match a position belongs to: the nearest standing one at
--- or before row `row`, column `col`. Walked backwards from there rather than
--- over the whole list, so a panel holding thousands of matches is only walked
--- as far as the nearest one -- past the invalid anchors of removed matches,
--- which are stranded wherever their line was deleted and own no row.
---@param bufnr integer
---@param row   integer  0-indexed
---@param col   integer  -1 for the end of the row
---@return table? mark  as `nvim_buf_get_extmarks` with `details`
local function standing_before(bufnr, row, col)
    local limit = 8
    while true do
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { row, col }, 0,
            { limit = limit, details = true })
        for _, mark in ipairs(marks) do
            if not is_hidden(mark) then return mark end
        end
        -- Every one of them was a removed match's: there may be more behind.
        if #marks < limit then return end
        limit = limit * 2
    end
end

--- The length of row `row`, or 0 when there is no such row.
---@param bufnr integer
---@param row   integer  0-indexed
---@return integer
local function line_len(bufnr, row)
    return #(vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or "")
end

--- Break row `row` in two at column `col`.
---
--- `set_text` on an empty range, so nothing is deleted and no span can be
--- covered -- and the marks land where they belong on their own: the anchor
--- sitting at `col` has right gravity and moves to the start of the new row,
--- and everything after `col` moves down with it.
---@param bufnr integer
---@param row   integer  0-indexed
---@param col   integer
local function split_row(bufnr, row, col)
    vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { "", "" })
end

--- Join row `row` onto the one above it, by deleting the newline between them.
---
--- Never with `nvim_buf_set_lines`, which would replace whole lines and so
--- cover an anchor's span in full -- invalidating it, which reads as the
--- match's line having been deleted, and the undo tree records that.
---@param bufnr integer
---@param state greplace.PanelState
---@param row   integer   0-indexed, > 0
---@param id    integer?  anchor standing on row `row - 1`, if any
local function join_row(bufnr, state, row, id)
    local above = line_len(bufnr, row - 1)
    if above == 0 and id then
        -- The line above is empty, so its anchor's span is the one newline
        -- about to go and deleting it would invalidate the mark. The anchor
        -- moves down to the row being joined up first -- the same line once
        -- the empty one is gone -- and the delete then falls outside it.
        set_anchor(bufnr, state, id, row)
        vim.api.nvim_buf_set_text(bufnr, row - 1, 0, row, 0, {})
    else
        vim.api.nvim_buf_set_text(bufnr, row - 1, above, row, 0, {})
    end
end

--- Take row `row` out. It belongs to no match, so nothing is lost but the
--- line the change added.
---
--- A row has to take a newline with it or a blank line is left behind, and the
--- one after it is the one to take: an anchor's span reaches from its own
--- column 0 to the start of the next row, so taking the newline before a row
--- could cover the span of the match above it in full.
---@param bufnr integer
---@param row   integer  0-indexed
local function delete_row(bufnr, row)
    local total = vim.api.nvim_buf_line_count(bufnr)
    if row + 1 < total then
        vim.api.nvim_buf_set_text(bufnr, row, 0, row + 1, 0, {})
    elseif row > 0 then
        -- The last row, with no newline after it to take.
        vim.api.nvim_buf_set_text(bufnr, row - 1, line_len(bufnr, row - 1),
            row, line_len(bufnr, row), {})
    else
        -- The only row. Neovim keeps one empty line whatever is asked for.
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
    end
end

--- The first standing anchor at or after row `row`, if any. As
--- `standing_before`, walked outwards rather than over the whole list.
---@param bufnr integer
---@param row   integer  0-indexed
---@return table? mark
local function standing_after(bufnr, row)
    if row >= vim.api.nvim_buf_line_count(bufnr) then return end
    local limit = 8
    while true do
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, { row, 0 }, -1,
            { limit = limit, details = true })
        for _, mark in ipairs(marks) do
            if not is_hidden(mark) then return mark end
        end
        if #marks < limit then return end
        limit = limit * 2
    end
end

--- Whether the panel has been emptied outright (`ggdG`). Neovim keeps one
--- blank line whatever is deleted, so an emptied panel is not an empty
--- buffer: it is one line no match has, every one of them having been
--- removed. It is the one state where a row belongs to no match and nothing
--- is wrong, so nothing may be handed that row.
---@param bufnr integer
---@param state greplace.PanelState
---@param standing table<integer, boolean>  which anchors still have a line
---@return boolean
local function is_emptied(bufnr, state, standing)
    if vim.api.nvim_buf_line_count(bufnr) ~= 1
        or vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= "" then
        return false
    end
    for _, id in ipairs(state.order) do
        if standing[id] then return false end
    end
    return true
end

--- Put the marks back onto the lines after an undo or a redo, which is the one
--- change that needs no line touched: every state the undo tree holds is one
--- the panel put in shape when it was made, so the text is right by
--- definition and only the marks can be wrong.
---
--- And they can be badly wrong. A change is replayed as whole lines replaced,
--- which drags every mark inside those lines to the start of them and marks
--- the anchors among them invalid -- and where several states are replayed
--- before this runs, as `3u` or a held-down `u` does, that piles the marks of
--- a whole region onto one row. Repairing the *text* from marks in that state
--- would be repairing what is right from what is wrong, so the marks are laid
--- out from the listing instead: the matches that still have a line take the
--- rows in the order the search listed them.
---
--- Which ones still have a line is the one thing the marks are still asked,
--- and where a replay has taken that from them too the rows say it: more rows
--- left than matches to put on them means the ones in between kept their
--- lines, whatever their anchors now read.
---
--- Only from the match above the replayed rows, and only until the rows and
--- the matches left come out even on a match already in its place: an anchor
--- further up was not touched, and everything below an even count is settled.
---@param bufnr integer
---@param state greplace.PanelState
---@param lo    integer  0-indexed first row the replay touched
---@param hi    integer  0-indexed last row, inclusive
local function restore_marks(bufnr, state, lo, hi)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local order = state.order

    local standing = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1,
        { details = true })) do
        standing[mark[1]] = not is_hidden(mark)
    end
    if is_emptied(bufnr, state, standing) then return end

    -- How many matches at or after each position still have a line, so that
    -- the rows left over at any point of the walk can be counted.
    local left = {}
    left[#order + 1] = 0
    for i = #order, 1, -1 do
        left[i] = left[i + 1] + (standing[order[i]] and 1 or 0)
    end

    local above = lo > 0 and standing_before(bufnr, lo - 1, -1) or nil
    local from  = above and (state.index[above[1]] + 1) or 1
    local row   = above and (above[2] + 1) or 0

    for i = from, #order do
        if row >= total then break end
        local id      = order[i]
        -- More rows left than matches to put on them: this one is a match
        -- whose anchor the replay took along with its line's text, and one of
        -- those rows is its own.
        local revived = not standing[id] and (total - row) > left[i]
        if standing[id] or revived then
            local at = vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns, id, {})
            -- Past the replayed rows and already where it belongs, with the
            -- rows and the matches even from here down: so is every match
            -- below it.
            if row > hi and not revived and at[1] == row and at[2] == 0
                and (total - row) == left[i] then
                break
            end
            if at[1] ~= row or at[2] ~= 0 or revived then
                set_anchor(bufnr, state, id, row)
            end
            set_bounds(bufnr, id, row, line_len(bufnr, row))
            row = row + 1
        end
    end
end

--- The matches the window holds, in row order: each one's anchor, and where
--- its text begins and ends.
--- In listing order, which is the order their rows have to come out in and
--- the only order that holds when two of them sit on one row -- as they do
--- once lines have been joined, where the row they share says nothing about
--- which of them comes first.
---@param bufnr integer
---@param state greplace.PanelState
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@return table? before  the anchor of the match the window starts at, if the
---                       change began inside one
---@return integer below  the row the first match past the window starts on,
---                       or the row count where there is none
---@return table[] anchors  `{ id, row, col, srow, scol, erow, ecol }`: where
---                       the anchor sits, and where its match's text does
local function gather(bufnr, state, lo, hi)
    -- The window starts at the match whose line the change began in -- which
    -- may start above `lo`, the change having broken its line -- and the first
    -- match below the window bounds the rows the last one in it may hold.
    local before  = standing_before(bufnr, lo, -1)
    local after   = standing_after(bufnr, hi + 1)
    local anchors = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns,
        { before and before[2] or 0, 0 }, { hi, -1 }, { details = true })) do
        if not is_hidden(mark) then
            local srow, scol, erow, ecol = get_bounds(bufnr, mark[1])
            anchors[#anchors + 1] = {
                id = mark[1], row = mark[2], col = mark[3],
                srow = srow, scol = scol, erow = erow, ecol = ecol,
            }
        end
    end
    table.sort(anchors, function(x, y)
        return (state.index[x.id] or 0) < (state.index[y.id] or 0)
    end)
    return before, after and after[2] or vim.api.nvim_buf_line_count(bufnr), anchors
end

--- Put every anchor back on the row its match's text starts on, and at the
--- head of it. An anchor is carried along by a line put in front of its own,
--- and left behind by the line it is on being split -- neither of which moves
--- the text it belongs to -- so it is the bounds that say where it goes.
---@param bufnr   integer
---@param state   greplace.PanelState
---@param anchors table[]  as `gather`
local function realign(bufnr, state, anchors)
    for _, a in ipairs(anchors) do
        local srow = select(1, get_bounds(bufnr, a.id))
        if a.row ~= srow or a.col ~= 0 then
            set_anchor(bufnr, state, a.id, srow)
        end
    end
end

--- Put back the panel's one line per match over rows `lo`..`hi`, reading what
--- went wrong off the marks that bound each match's text.
---
--- A match is one source line, and the panel is edited line for line: there is
--- nowhere for an added line to go, and a joined line would be two matches'
--- text with the second one's `file:line` drawn in the middle of it. Each row
--- of the window is put back where it belongs:
---
---   * two matches starting on one row: their lines were joined, so the row is
---     split where the second one starts. `J` puts a space at the seam, which
---     lies between the end of the first match's text and the start of the
---     second's and belongs to neither line, so it goes with the join;
---   * a row a match's text reaches down to: its line was broken in two (or a
---     line was put in front of it, which leaves the same shape), so the rows
---     are joined back up;
---   * any other row no match starts on: a line that was added, so it is
---     deleted.
---
--- Nothing is remembered between changes: the marks say all of this by
--- themselves, whichever edit left it and however many edits ago. Rows are
--- taken from the bottom up, so the rows still to be looked at keep their
--- numbers as the ones below them move.
---
--- A match whose line was deleted has no standing anchor and no row, and is no
--- business of this: removing a line from the panel is how a match is left out
--- of the replacement.
---@param bufnr integer
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@param about fun()?  called once the marks say there is something to put
---                     back, before anything is: this runs behind every
---                     change, and what the caller has to do to make an edit
---                     of its own is not for the changes that need none
---@return boolean repaired
---@return boolean? edited  and whether any line had to be rewritten for it
local function repair(bufnr, lo, hi, about)
    local state = _state[bufnr]
    if not state or not state.stats then return false end
    local total = vim.api.nvim_buf_line_count(bufnr)
    lo = math.max(0, math.min(lo, total - 1))
    hi = math.max(lo, math.min(hi, total - 1))

    local before, below, anchors = gather(bufnr, state, lo, hi)
    -- No match here at all: either the panel was emptied outright (Neovim
    -- keeps one blank line whatever is deleted, and handing it to a match
    -- would bring one back), or the change was made where no match is left.
    if #anchors == 0 then return false end

    -- Whether anything is wrong at all is settled by the anchors alone: the
    -- window holds one line per match exactly when its rows and its standing
    -- anchors come out even, one anchor to a row. Every change that breaks
    -- that adds or takes a row, so every one of them shows up here -- and an
    -- anchor left on the wrong row by such a change is on a row of its own
    -- until the bounds are read, which happens only once this says there is
    -- something to put back. The bounds are the looser of the two records --
    -- `redraw` moves them back onto their lines after the fact, which the undo
    -- tree knows nothing about, so an undo or a redo can leave one lying
    -- across a row that is perfectly fine -- and acting on that alone would
    -- join or delete a line that nothing was wrong with.
    local broken = (not before and anchors[1].row > 0)
        or anchors[#anchors].row + 1 ~= below
    for i = 1, #anchors - 1 do
        if anchors[i + 1].row ~= anchors[i].row + 1 then broken = true end
    end
    if vim.env.GREP_DEBUG then
        _G.dbg = _G.dbg or {}
        table.insert(_G.dbg, ("repair lo=%d hi=%d below=%d before=%s broken=%s %s %s"):format(
            lo, hi, below, tostring(before and before[2]), tostring(broken),
            vim.inspect(anchors, {newline=" ", indent=""}),
            vim.inspect(vim.api.nvim_buf_get_lines(bufnr,0,-1,false), {newline=" ", indent=""})))
    end
    if not broken then return false end
    if about then about() end

    -- From here the bounds are the record, so the anchors are brought onto
    -- them first: the window is read again around anchors that stand where
    -- their matches' text does.
    realign(bufnr, state, anchors)
    before, below, anchors = gather(bufnr, state, lo, hi)
    if #anchors == 0 then return false end

    local fixed, edited = false, false
    for i = #anchors, 1, -1 do
        local a, next_a = anchors[i], anchors[i + 1]
        if next_a and next_a.row == a.row then
            local at = next_a.scol
            if a.erow == a.row and a.ecol >= a.scol and a.ecol < at then
                vim.api.nvim_buf_set_text(bufnr, a.row, a.ecol, a.row, at, {})
                at = a.ecol
            end
            split_row(bufnr, a.row, at)
            -- `J` also strips the indent of the line it pulls up, which is
            -- part of that line's text and not of the seam: put it back, as
            -- long as the line has not been given an indent of its own.
            local entry = state.entries[next_a.id]
            local indent = entry and entry.text:match("^%s+")
            local moved = vim.api.nvim_buf_get_lines(bufnr, a.row + 1, a.row + 2, false)[1]
            if indent and moved and not moved:match("^%s") then
                vim.api.nvim_buf_set_text(bufnr, a.row + 1, 0, a.row + 1, 0, { indent })
            end
            fixed, edited = true, true
        else
            for row = (next_a and next_a.row or below) - 1, a.row + 1, -1 do
                if row <= a.erow then
                    join_row(bufnr, state, row, row - 1 == a.row and a.id or nil)
                else
                    delete_row(bufnr, row)
                end
                fixed, edited = true, true
            end
        end
    end
    -- Rows above the first match of all, where there is no match's text to
    -- reach down to them: a line put in ahead of the list.
    if not before then
        for row = anchors[1].row - 1, 0, -1 do
            delete_row(bufnr, row)
            fixed, edited = true, true
        end
    end
    -- A split leaves the anchor of the match it moved down behind on the row
    -- above, the location being drawn in front of whatever is typed at the
    -- head of a line rather than carried along by it.
    realign(bufnr, state, anchors)
    return fixed, edited
end

--- Where the buffer stands in its undo history.
---@param bufnr integer
---@return integer seq_cur
---@return integer seq_last
local function undo_seq(bufnr)
    local tree = vim.fn.undotree(bufnr)
    return tree.seq_cur, tree.seq_last
end

--- Repair rows `lo`..`hi` (see `repair`), keeping the cursor on the same
--- character of the same match's line, and say so when a line had to be
--- rewritten to do it.
---
--- The repair is joined to the undo block of the change that made it
--- necessary, so that `u` never walks back into a state where the panel does
--- not hold one line per match -- and so that undo and redo, which replay both
--- together, always land on a state that needs no repair of its own.
---@param bufnr integer
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@return boolean repaired
local function guard_lines(bufnr, lo, hi)
    local cur, at, offset = nil, nil, 0
    local fixed, edited = repair(bufnr, lo, hi, function()
        -- Where the cursor goes: as far into its match's line as it is now,
        -- the match being the last one still standing that starts at or
        -- before it.
        cur    = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)
        offset = cur and cur[2] or 0
        if cur then
            local mark = standing_before(bufnr, cur[1] - 1, cur[2])
            if mark then
                at, offset = mark[1], cur[2] - mark[3]
                for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, mark[2], cur[1] - 1, false)) do
                    offset = offset + #line
                end
            end
        end
        -- Only now: `undojoin` joins the *next* change to the block before it,
        -- so calling it where nothing is put back would join the user's next
        -- edit to their last one.
        pcall(vim.cmd.undojoin)
    end)
    if not fixed then return false end

    if cur and edited then
        local row  = at and vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns, at, {})[1] or 0
        local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, math.min(offset, #text) })
    end
    if edited then
        vim.api.nvim_echo({ { "greplace: the panel holds one line per match; the lines were put back",
            "WarningMsg" } }, false, {})
    end
    return true
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
    local mark = standing_before(bufnr, row, -1)
    if not mark then return end
    return state.entries[mark[1]], mark[2]
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
    -- The filetype is set below, once the buffer is named: `FileType`
    -- handlers should find it as it will stay.
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
    -- A line broken in the panel is always joined back up, so indenting the
    -- new one is of no use -- and it does harm: Vim remembers having indented
    -- it, and on <Esc> deletes that "indent", which after the join is the
    -- white space at the cursor on the line that was put back. Every option that sets that
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
    -- fill it from, so a panel holding a list is refilled from the lines the
    -- search stored, which is also how `:e` throws away unapplied edits.
    -- Anything else -- a panel with no list to refill from -- is left empty
    -- with everything drawn on it gone, since anchors left behind would all
    -- collapse onto the one remaining row and a write would take that row's
    -- text for all of their matches.
    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = bufnr,
        desc   = "greplace: a reload refills the panel from the stored lines",
        callback = function()
            local state = _state[bufnr]
            if state and state.stats then
                local entries = {}
                for _, id in ipairs(state.order) do
                    entries[#entries + 1] = state.entries[id]
                end
                vim.bo[bufnr].modifiable = true
                if not M.refresh(bufnr, entries) then
                    watch()
                    return
                end
            end
            _state[bufnr] = nil
            vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
            vim.api.nvim_buf_clear_namespace(bufnr, _ns_bounds, 0, -1)
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
    -- How many passes in a row have had something to put back.
    local repairs  = 0
    -- Watching the lines is not a one-off. `:edit` unloads the buffer before
    -- `BufReadCmd` fills it again, and an unload detaches every listener on
    -- it -- `on_detach`, not `on_reload`, a buffer read by `BufReadCmd` being
    -- one Neovim does not offer a reload. The buffer itself survives, and the
    -- next search reuses it rather than going back through `create_buf`, so
    -- the reload has to attach again or the panel comes back unwatched: no
    -- guard and no redraw behind an edit. Attaching twice would be no better
    -- than not at all -- every change acted on twice over -- hence the flag
    -- rather than a second attach on trust.
    watch = function()
        if attached then return end
        attached = true
        pending  = nil
        vim.api.nvim_buf_attach(bufnr, false, {
            on_detach = function() attached = false end,
            on_lines = function(_, _, _, first, last_old, last_new)
                -- Nothing to look at: the list was thrown away by a reload,
                -- and the lines left are no match's.
                local state = _state[bufnr]
                if not state then return end
                state.ticks = (state.ticks or 0) + 1

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
                    -- An undo or a redo moves to another undo state without
                    -- adding one; a new change always adds one. Every state
                    -- the undo tree holds was put in shape when it was made,
                    -- so a replay needs no line touched -- only the marks put
                    -- back onto the lines they were dragged off.
                    local seq, seq_last = undo_seq(bufnr)
                    if st.stats and seq_last == st.seq_last and seq ~= st.seq then
                        restore_marks(bufnr, st, lo, hi)
                    -- A repair is a change of its own, which gets a pass of
                    -- its own -- and that pass finds nothing left to repair.
                    -- More than a handful in a row means one is making work
                    -- for the next, and the panel stops rather than rewriting
                    -- the buffer under the user's hands forever.
                    elseif repairs < 8 and guard_lines(bufnr, lo, hi) then
                        repairs = repairs + 1
                    else
                        repairs = 0
                    end
                    st.seq, st.seq_last = undo_seq(bufnr)
                    redraw(bufnr, lo, hi)
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
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_bounds, 0, -1)
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
    state.ticks   = 0
    state.seq, state.seq_last = undo_seq(bufnr)
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
        local ok, id   = pcall(set_anchor, bufnr, state, nil, row - 1, virt)
        -- An anchor that could not be placed would silently drop its match from
        -- the list the panel writes back, and every later row would still look
        -- fine -- so the whole render is abandoned instead, and the caller says
        -- so. Half a result set is worse than none: the user would edit it
        -- believing it was all of them.
        if not ok then
            error(string.format("%s:%d: could not anchor result: %s",
                m.relpath, m.lnum, tostring(id)), 0)
        end
        set_bounds(bufnr, id, row - 1, #m.text)
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
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_bounds, 0, -1)
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
    -- One pass over the buffer list for the whole redraw. Asking `find_buf`
    -- per entry walks every buffer, resolving each of their names, for every
    -- one of `limit` entries -- seconds of `realpath` on a full panel, on a
    -- path that runs after every write.
    local bufs = util.buf_map()
    for i, e in ipairs(entries) do
        matches[i] = {
            path    = e.path,
            relpath = e.relpath,
            lnum    = e.lnum,
            text    = e.text,
            subs    = {},
            bufnr   = bufs[e.path],
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
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1, { details = true })
    local out   = {}

    -- One pass over the standing anchors, which come back sorted by row: each
    -- one's region runs to the row the next of them sits on, and the last to
    -- the end of the buffer. A removed match's anchor is invalid, takes no
    -- row and gives up no lines.
    local lines, prev = {}, nil
    for _, mark in ipairs(marks) do
        if not is_hidden(mark) then
            if prev then
                lines[prev[1]] = vim.api.nvim_buf_get_lines(bufnr, prev[2], mark[2], false)
            end
            prev = { mark[1], mark[2] }
        end
    end
    if prev then
        lines[prev[1]] = vim.api.nvim_buf_get_lines(bufnr, prev[2], total, false)
    end

    -- In listing order, which is the order the standing anchors sit in: the
    -- removed matches, whose anchors are stranded wherever their line was
    -- deleted, have no place of their own to be listed in.
    for _, id in ipairs(state.order) do
        local entry = state.entries[id]
        if entry then
            out[#out + 1] = { entry = entry, lines = lines[id] or {} }
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
