-- greplace://greplace-matches scratch buffer: one editable line per match.
-- Each match has two marks: an anchor (draws the `file:line` virtual text,
-- spans the whole line, invalidated when the line is deleted) and a hidden
-- bounds mark glued to its text via inward gravity. `repair` reads the two
-- against each other to fix joined/split/added lines with nothing remembered
-- on the side. Undo/redo restore marks from the match listing (`restore_marks`)
-- since undo states hold correct text but can scramble marks. `_redraw` reports
-- changed-line state for `greplace.panel` to draw; no panel state lives here.

local M = {}

M.ns        = vim.api.nvim_create_namespace("greplace.anchor")
-- The bounds of each match's text, keyed by its anchor's id.
M.ns_bounds = vim.api.nvim_create_namespace("greplace.bounds")

--- Set (or move) an anchor, spanning the whole of row `row`.
--- Deleting the line invalidates the span (and mark), reading back as a match
--- with no line; undo restores both, so undo/redo need nothing else recorded.
---@param bufnr integer
---@param id    integer?  anchor extmark id, or nil for a new anchor
---@param row   integer   0-indexed
---@param virt  table[]   the chunks to draw
---@return integer id
function M.set_anchor(bufnr, id, row, virt)
    return vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
        id                = id,
        virt_text         = virt,
        virt_text_pos     = "inline",
        -- Plain gravity: drawn in front of the line, text typed at the start
        -- belongs after it. Bounds, not the anchor, say where the text is;
        -- `repair` moves the anchor to match.
        right_gravity     = false,
        end_row           = row + 1,
        end_col           = 0,
        end_right_gravity = true,
        invalidate        = true,
        undo_restore      = true,
        strict            = false,
    })
end

--- Span a match's text (row `row`, `len` bytes) with the hidden bounds mark,
--- under the anchor's own id. Inward gravity keeps it glued to the text as
--- typing grows or shrinks the line; it never invalidates or draws.
---@param bufnr integer
---@param id    integer  the anchor's extmark id
---@param row   integer  0-indexed
---@param len   integer  the length of the line
function M.set_bounds(bufnr, id, row, len)
    vim.api.nvim_buf_set_extmark(bufnr, M.ns_bounds, row, 0, {
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
    local mark     = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_bounds, id,
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
function M.is_hidden(mark)
    return mark[4].invalid == true
end

--- Read the anchors on rows `lo`..`hi` against their lines, and report what
--- differs from the tracker (hidden/changed) as moves for the caller to apply;
--- also re-sets bounds where the line's edit grew or shrunk them.
---@param bufnr   integer
---@param entries table<integer, greplace.Entry>
---@param tracker greplace.Tracker
---@param lo      integer  0-indexed
---@param hi      integer  0-indexed, inclusive
---@return { id:integer, row:integer?, hidden:boolean?, changed:boolean? }[] moves
---        `hidden`: anchor `id` lost its line, or got it back; `changed`: the
---        line of anchor `id`, now on row `row`, differs from its rendered text
---        or is back to it
function M._redraw(bufnr, entries, tracker, lo, hi)
    local moves = {}

    local total = vim.api.nvim_buf_line_count(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { lo, 0 }, { hi, -1 },
        { details = true })
    local lines = vim.api.nvim_buf_get_lines(bufnr, lo, math.min(hi + 1, total), false)
    for _, mark in ipairs(marks) do
        local id, row = mark[1], mark[2]
        local hide    = M.is_hidden(mark)
        if entries[id] then
            if tracker:is_hidden(id) ~= hide then
                moves[#moves + 1] = { id = id, hidden = hide }
            end
            if not hide and row < total then
                local text    = lines[row - lo + 1]
                local changed = text ~= entries[id].text
                if changed ~= tracker:is_changed(id) then
                    moves[#moves + 1] = { id = id, row = row, changed = changed }
                end
                local srow, scol, erow, ecol = get_bounds(bufnr, id)
                if srow ~= row or scol ~= 0 or erow ~= row or ecol ~= #text then
                    M.set_bounds(bufnr, id, row, #text)
                end
            end
        end
    end
    return moves
end

--- The first standing anchor met walking from `from` to `to`. Walked outwards
--- a few marks at a time, so a panel with thousands of matches is only walked
--- as far as the nearest one, past the stranded anchors of removed matches.
---@param bufnr integer
---@param from  integer[]|integer
---@param to    integer[]|integer
---@return table? mark  as `nvim_buf_get_extmarks` with `details`
local function standing(bufnr, from, to)
    local limit = 8
    while true do
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, from, to,
            { limit = limit, details = true })
        for _, mark in ipairs(marks) do
            if not M.is_hidden(mark) then return mark end
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
function M.standing_before(bufnr, row, col)
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

--- Break row `row` in two at column `col`, via `set_text` on an empty range
--- so nothing is deleted and no span is covered; marks at `col` land on the
--- new row correctly by their own gravity.
---@param bufnr integer
---@param row   integer  0-indexed
---@param col   integer
local function split_row(bufnr, row, col)
    vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { "", "" })
end

--- Join row `row` onto the one above it, by deleting the newline between them.
--- Never with `nvim_buf_set_lines`, which would cover an anchor's span in
--- full and invalidate it, reading as the match's line having been deleted.
---@param bufnr integer
---@param drawn table<integer, table[]>  each anchor's chunks
---@param row   integer   0-indexed, > 0
---@param id    integer?  anchor standing on row `row - 1`, if any
local function join_row(bufnr, drawn, row, id)
    local above = line_len(bufnr, row - 1)
    if above == 0 and id then
        -- The line above is empty, so deleting its newline would invalidate
        -- the anchor's span. Move the anchor down first, past the delete.
        M.set_anchor(bufnr, id, row, drawn[id])
        vim.api.nvim_buf_set_text(bufnr, row - 1, 0, row, 0, {})
    else
        vim.api.nvim_buf_set_text(bufnr, row - 1, above, row, 0, {})
    end
end

--- Take row `row` out; it belongs to no match. Takes the newline after it,
--- not before, since a span reaches from its own column 0 to the next row's
--- start and taking the newline before could cover the match above in full.
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
--- blank line whatever is deleted, so this is the one case where a row
--- belongs to no match and nothing is wrong.
---@param bufnr integer
---@param order integer[]  anchor ids in listing order
---@param standing table<integer, boolean>  which anchors still have a line
---@return boolean
local function is_emptied(bufnr, order, standing)
    if vim.api.nvim_buf_line_count(bufnr) ~= 1
        or vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= "" then
        return false
    end
    for _, id in ipairs(order) do
        if standing[id] then return false end
    end
    return true
end

--- Put marks back onto lines after an undo/redo, since a replay drags marks
--- inside replayed lines to their start. Anchors are laid out fresh from the
--- listing order, walked from above the replay until counts settle.
---@param bufnr integer
---@param list  greplace.List
---@param drawn table<integer, table[]>  each anchor's chunks
---@param lo    integer  0-indexed first row the replay touched
---@param hi    integer  0-indexed last row, inclusive
function M.restore_marks(bufnr, list, drawn, lo, hi)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local order = list.order

    local standing_ids = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1,
        { details = true })) do
        standing_ids[mark[1]] = not M.is_hidden(mark)
    end
    if is_emptied(bufnr, order, standing_ids) then return end

    -- How many matches at or after each position still have a line, so that
    -- the rows left over at any point of the walk can be counted.
    local left = {}
    left[#order + 1] = 0
    for i = #order, 1, -1 do
        left[i] = left[i + 1] + (standing_ids[order[i]] and 1 or 0)
    end

    local above = lo > 0 and M.standing_before(bufnr, lo - 1, -1) or nil
    local from  = above and (list.index[above[1]] + 1) or 1
    local row   = above and (above[2] + 1) or 0

    for i = from, #order do
        if row >= total then break end
        local id      = order[i]
        -- More rows left than matches to put on them: this one is a match
        -- whose anchor the replay took along with its line's text, and one of
        -- those rows is its own.
        local revived = not standing_ids[id] and (total - row) > left[i]
        if standing_ids[id] or revived then
            local at = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, id, {})
            -- Past the replayed rows and already where it belongs, with the
            -- rows and the matches even from here down: so is every match
            -- below it.
            if row > hi and not revived and at[1] == row and at[2] == 0
                and (total - row) == left[i] then
                break
            end
            if at[1] ~= row or at[2] ~= 0 or revived then
                M.set_anchor(bufnr, id, row, drawn[id])
            end
            M.set_bounds(bufnr, id, row, line_len(bufnr, row))
            row = row + 1
        end
    end
end

--- The matches the window holds, in listing order (the only order that holds
--- when two share a row, as they do once lines have been joined): each one's
--- anchor, and where its text begins and ends.
---@param bufnr integer
---@param index table<integer, integer>  each anchor's position in the listing
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@return table? before  the anchor of the match the window starts at, if the
---                       change began inside one
---@return integer below  the row the first match past the window starts on,
---                       or the row count where there is none
---@return table[] anchors  `{ id, row, col, srow, scol, erow, ecol }`: where
---                       the anchor sits, and where its match's text does
local function gather(bufnr, index, lo, hi)
    -- The window starts at the match whose line the change began in (which
    -- may start above `lo`); the first match below bounds the last row.
    local before  = M.standing_before(bufnr, lo, -1)
    local after   = standing_after(bufnr, hi + 1)
    local anchors = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, M.ns,
        { before and before[2] or 0, 0 }, { hi, -1 }, { details = true })) do
        if not M.is_hidden(mark) then
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
        return (index[x.id] or 0) < (index[y.id] or 0)
    end)
    return before, after and after[2] or vim.api.nvim_buf_line_count(bufnr), anchors
end

--- Put every anchor back at the head of the row its match's text starts on:
--- a line put in front, or a split, can carry it off without moving the
--- text, so the bounds (not the anchor's current row) say where it goes.
---@param bufnr   integer
---@param drawn   table<integer, table[]>  each anchor's chunks
---@param anchors table[]  as `gather`
local function realign(bufnr, drawn, anchors)
    for _, a in ipairs(anchors) do
        local srow = select(1, get_bounds(bufnr, a.id))
        if a.row ~= srow or a.col ~= 0 then
            M.set_anchor(bufnr, a.id, srow, drawn[a.id])
        end
    end
end

--- Put back the panel's one line per match over rows `lo`..`hi`, reading it
--- off the marks: split rows two matches share, join rows a match's text
--- reaches down to, delete any other row as an added line.
---@param bufnr integer
---@param list  greplace.List
---@param drawn table<integer, table[]>  each anchor's chunks
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@param about fun()?  called once the marks say there is something to put
---                     back, before anything is: this runs behind every
---                     change, and what the caller has to do to make an edit
---                     of its own is not for the changes that need none
---@return boolean repaired
---@return boolean? edited  and whether any line had to be rewritten for it
local function repair(bufnr, list, drawn, lo, hi, about)
    local total = vim.api.nvim_buf_line_count(bufnr)
    lo = math.max(0, math.min(lo, total - 1))
    hi = math.max(lo, math.min(hi, total - 1))

    local before, below, anchors = gather(bufnr, list.index, lo, hi)
    -- No match here: either the panel was emptied outright, or the change
    -- was made where no match is left.
    if #anchors == 0 then return false end

    -- Settled by the anchors alone: rows and standing anchors should come
    -- out one-to-one. Bounds are only trusted once this says something needs
    -- fixing, since `_redraw` can leave one lying across a fine row.
    local broken = (not before and anchors[1].row > 0)
        or anchors[#anchors].row + 1 ~= below
    for i = 1, #anchors - 1 do
        if anchors[i + 1].row ~= anchors[i].row + 1 then broken = true end
    end
    if not broken then return false end
    if about then about() end

    -- Bring anchors onto the bounds first, then re-read the window around
    -- anchors that stand where their matches' text does.
    realign(bufnr, drawn, anchors)
    before, below, anchors = gather(bufnr, list.index, lo, hi)
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
            local entry = list.entries[next_a.id]
            local indent = entry and entry.text:match("^%s+")
            local moved = vim.api.nvim_buf_get_lines(bufnr, a.row + 1, a.row + 2, false)[1]
            if indent and moved and not moved:match("^%s") then
                vim.api.nvim_buf_set_text(bufnr, a.row + 1, 0, a.row + 1, 0, { indent })
            end
            fixed, edited = true, true
        else
            for row = (next_a and next_a.row or below) - 1, a.row + 1, -1 do
                if row <= a.erow then
                    join_row(bufnr, drawn, row, row - 1 == a.row and a.id or nil)
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
    realign(bufnr, drawn, anchors)
    return fixed, edited
end

--- Where the buffer stands in its undo history.
---@param bufnr integer
---@return integer seq_cur
---@return integer seq_last
function M.undo_seq(bufnr)
    local tree = vim.fn.undotree(bufnr)
    return tree.seq_cur, tree.seq_last
end

--- Repair rows `lo`..`hi` (see `repair`), keeping the cursor on the same
--- character of the same match's line. Joined to the undo block of the
--- change that made it necessary, so undo/redo replay both together.
---@param bufnr integer
---@param list  greplace.List
---@param drawn table<integer, table[]>  each anchor's chunks
---@param lo    integer  0-indexed first row the change touched
---@param hi    integer  0-indexed last row, inclusive
---@return boolean repaired
function M.guard_lines(bufnr, list, drawn, lo, hi)
    local cur, at, offset = nil, nil, 0
    local fixed, edited = repair(bufnr, list, drawn, lo, hi, function()
        -- Where the cursor goes: as far into its match's line as it is now,
        -- the match being the last one still standing that starts at or
        -- before it.
        cur    = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)
        offset = cur and cur[2] or 0
        if cur then
            local mark = M.standing_before(bufnr, cur[1] - 1, cur[2])
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
        local row  = at and vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, at, {})[1] or 0
        local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, math.min(offset, #text) })
    end
    if edited then
        vim.api.nvim_echo({ { "greplace: the panel holds one line per match; the lines were put back",
            "WarningMsg" } }, false, {})
    end
    return true
end

return M
