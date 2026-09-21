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
-- Showing that a line has been edited is not this module's business: `redraw`
-- says when a line starts or stops differing from its rendered text, and
-- `greplace.panel.render` draws the marker.
-- ---------------------------------------------------------------------------

local _ns              = vim.api.nvim_create_namespace("greplace.anchor")
-- The bounds of each match's text, keyed by its anchor's id.
local _ns_bounds       = vim.api.nvim_create_namespace("greplace.bounds")

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
        id                = id,
        virt_text         = virt or state.virt[id],
        virt_text_pos     = "inline",
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
    local mark     = vim.api.nvim_buf_get_extmark_by_id(bufnr, _ns_bounds, id,
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

--- Bring the anchors on rows `lo`..`hi` up to date with their lines, along
--- with the winbar's counts. A change to those rows cannot give a line to, or
--- take one from, an anchor on any other row -- row `hi` included, being where
--- the anchors of lines deleted just above it end up.
---
--- Hiding a removed match's location needs nothing done here: its anchor's
--- span went with the line, and an invalid mark draws nothing. What is left is
--- the bookkeeping the marks cannot do -- the winbar's counts following a
--- match out of the list and back in -- and telling the caller when a line
--- starts or stops holding the text it was rendered with, so that it can show
--- it (`on_changed`).
---
--- An extmark is only re-set when what it draws changes: this runs on every
--- edit, and re-setting even a handful of anchors per keystroke is not free.
---@param bufnr integer
---@param state greplace.PanelState
---@param lo    integer  0-indexed
---@param hi    integer  0-indexed, inclusive
---@param on_changed fun(bufnr:integer, state:greplace.PanelState, id:integer, row:integer, changed:boolean)
---                  called when the line of anchor `id`, now on row `row`,
---                  differs from its rendered text (`changed`) or is back to it
local function redraw(bufnr, state, lo, hi, on_changed)
    if not state.stats then return end

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
                    on_changed(bufnr, state, id, row, changed)
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

--- The first standing anchor met walking from `from` to `to`, in either
--- direction. Walked outwards a few marks at a time rather than over the whole
--- list, so a panel holding thousands of matches is only walked as far as the
--- nearest one -- past the invalid anchors of removed matches, which are
--- stranded wherever their line was deleted and own no row.
---@param bufnr integer
---@param from  integer[]|integer
---@param to    integer[]|integer
---@return table? mark  as `nvim_buf_get_extmarks` with `details`
local function standing(bufnr, from, to)
    local limit = 8
    while true do
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, from, to,
            { limit = limit, details = true })
        for _, mark in ipairs(marks) do
            if not is_hidden(mark) then return mark end
        end
        -- Every one of them was a removed match's: there may be more further on.
        if #marks < limit then return end
        limit = limit * 2
    end
end

--- The anchor of the match a position belongs to: the nearest standing one at
--- or before row `row`, column `col`.
---@param bufnr integer
---@param row   integer  0-indexed
---@param col   integer  -1 for the end of the row
---@return table? mark
local function standing_before(bufnr, row, col)
    return standing(bufnr, { row, col }, 0)
end

--- The first standing anchor at or after row `row`, if any.
---@param bufnr integer
---@param row   integer  0-indexed
---@return table? mark
local function standing_after(bufnr, row)
    if row >= vim.api.nvim_buf_line_count(bufnr) then return end
    return standing(bufnr, { row, 0 }, -1)
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
                id = mark[1],
                row = mark[2],
                col = mark[3],
                srow = srow,
                scol = scol,
                erow = erow,
                ecol = ecol,
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
---@param state greplace.PanelState
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@param about fun()?  called once the marks say there is something to put
---                     back, before anything is: this runs behind every
---                     change, and what the caller has to do to make an edit
---                     of its own is not for the changes that need none
---@return boolean repaired
---@return boolean? edited  and whether any line had to be rewritten for it
local function repair(bufnr, state, lo, hi, about)
    if not state.stats then return false end
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
---@param state greplace.PanelState
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@return boolean repaired
local function guard_lines(bufnr, state, lo, hi)
    local cur, at, offset = nil, nil, 0
    local fixed, edited = repair(bufnr, state, lo, hi, function()
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

return {
    ns              = _ns,
    ns_bounds       = _ns_bounds,
    set_anchor      = set_anchor,
    set_bounds      = set_bounds,
    is_hidden       = is_hidden,
    tally           = tally,
    redraw          = redraw,
    standing_before = standing_before,
    restore_marks   = restore_marks,
    guard_lines     = guard_lines,
    undo_seq        = undo_seq,
}
