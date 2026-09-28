-- Drawing the panel: a result list as buffer lines with an anchor and a bounds
-- mark per match, or a status in place of one.

local config        = require("greplace.config").current
local strutil       = require("greplace.util.strutil")
local marks         = require("greplace.panel.marks")
local tracker       = require("greplace.panel.tracker")

local set_anchor    = marks.set_anchor
local set_bounds    = marks.set_bounds

local _ns          = marks.ns
local _ns_bounds   = marks.ns_bounds

local M = {}

M.ns_hl      = vim.api.nvim_create_namespace("greplace.match")
local _ns_st = vim.api.nvim_create_namespace("greplace.status")

--- One occurrence of the query in a match's line, as the search found it: the
--- columns it covers and, once drawn, the extmark painting it.
---@class greplace.Hit
---@field s  integer  0-indexed first byte
---@field e  integer  0-indexed end, exclusive
---@field id integer?  the `GreplaceMatch` extmark, while one is drawn

--- Take everything the panel drew off a buffer: anchors, bounds, match
--- highlights and the status text.
---@param bufnr integer
function M.clear_all(bufnr)
    for _, ns in ipairs({ _ns, _ns_bounds, M.ns_hl, _ns_st }) do
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
end

-- Drawn in front of the location of a match that was found in a loaded buffer
-- -- and so shows the buffer's text, which may not be what is on disk. Fixed
-- when the list is rendered: it says where the line came from, not whether
-- the file is open now. A glyph rather than only a highlight, which a
-- colorscheme can leave looking like the plain one.
local _buffer_indicator = "≡ "
local _no_indicator     = string.rep(" ", vim.fn.strdisplaywidth(_buffer_indicator))

-- Drawn in front of the `│` of a match whose line has been edited, so that the
-- lines a write would rewrite stand out from the column alone. Every row
-- reserves its width, so the `│` stays aligned whichever rows carry it.
local _changed_marker   = "•"
local _no_marker        = string.rep(" ", vim.fn.strdisplaywidth(_changed_marker))

--- The chunks of an anchor with its changed marker shown or cleared, as a list
--- of their own: the ones given are left as they were.
---@param chunks  table[]
---@param changed boolean
---@return table[]
function M.with_marker(chunks, changed)
    local out = {}
    for i, chunk in ipairs(chunks) do out[i] = chunk end
    -- The marker is the chunk just before the `│`, the last one.
    out[#out - 1] = { changed and _changed_marker or _no_marker, "GreplaceChanged" }
    return out
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
        width = math.max(width, vim.api.nvim_strwidth(m.relpath .. ":" .. m.lnum))
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

--- Paint the hits of one row and record the extmark each was given, for a
--- later pass to read the text under it back.
---@param bufnr integer
---@param row   integer  0-indexed
---@param hits  greplace.Hit[]
function M.draw_hits(bufnr, row, hits)
    for _, h in ipairs(hits) do
        -- The recorded id, when there is one: the redraw lands on the mark
        -- already drawing the hit rather than leaving it behind on the row.
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_hl, row, h.s, {
            id       = h.id,
            end_col  = h.e,
            hl_group = "GreplaceMatch",
        })
        if not ok then
            error(string.format("could not highlight match at %d-%d: %s",
                h.s, h.e, tostring(id)), 0)
        end
        h.id = id
    end
end

--- Take one hit's extmark off the buffer, leaving the id on the hit for a
--- redraw to put back where the search found it.
---@param bufnr integer
---@param id    integer?
local function drop_hit(bufnr, id)
    if id then pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_hl, id) end
end

--- Where a hit's mark stands: the row and columns it covers, nil when it is
--- not drawn.
---@param bufnr integer
---@param h     greplace.Hit
---@return integer? row, integer? s, integer? e
local function hit_at(bufnr, h)
    local at      = h.id and vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns_hl, h.id,
        { details = true }) or {}
    return at[1], at[2], at[3] and at[3].end_col
end

--- Whether a hit's mark is drawn where the search found it.
---@param bufnr integer
---@param row   integer
---@param h     greplace.Hit
---@return boolean
local function hit_drawn(bufnr, row, h)
    local r, s, e = hit_at(bufnr, h)
    return r == row and s == h.s and e == h.e
end

--- Keep the `GreplaceMatch` highlights of rows `lo`..`hi` true to the lines
--- under them. A hit belongs to the text as searched: a line that is that text
--- has its hits again -- which is what an undo puts back -- while on an edited
--- line a hit stands only where the bytes under it are still the ones that
--- were matched.
---@param bufnr   integer
---@param entries table<integer, greplace.Entry>  keyed by anchor extmark id
---@param lo      integer  0-indexed
---@param hi      integer  0-indexed, inclusive
function M.recheck_hits(bufnr, entries, lo, hi)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, _ns,
        { lo, 0 }, { hi, -1 }, { details = true })) do
        ---@type greplace.Entry?
        local entry = entries[mark[1]]
        if entry and entry.hits and #entry.hits > 0 then
            local hits = assert(entry.hits)
            if marks.is_hidden(mark) then
                -- The line is gone, so its hits are not drawn. Their marks
                -- survive collapsed onto the row that took the line's place,
                -- ready for the undo to draw again; one the text shoved onto
                -- something else is taken off.
                for _, h in ipairs(hits) do
                    local r, s, e = hit_at(bufnr, h)
                    if r and e and e > s then drop_hit(bufnr, h.id) end
                end
            else
                local row  = mark[2]
                local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
                if text == entry.text then
                    -- Only what is not already right: this runs behind every
                    -- change, and moving a mark that stands where it should is
                    -- churn for nothing.
                    local missing = {}
                    for _, h in ipairs(hits) do
                        if not hit_drawn(bufnr, row, h) then missing[#missing + 1] = h end
                    end
                    if #missing > 0 then M.draw_hits(bufnr, row, missing) end
                else
                    for _, h in ipairs(hits) do
                        local r, s, e = hit_at(bufnr, h)
                        -- Kept only while the bytes under the mark are still
                        -- the bytes that were matched.
                        if r ~= row or not s or not e or e <= s
                            or text:sub(s + 1, e) ~= entry.text:sub(h.s + 1, h.e) then
                            drop_hit(bufnr, h.id)
                        end
                    end
                end
            end
        end
    end
end

--- Write the match list into the panel buffer and (re)anchor one extmark per
--- match. Nothing is recorded anywhere but in what is returned, which the
--- caller takes as the panel's list: a render that fails leaves no half of one
--- behind.
---@param bufnr   integer
---@param matches greplace.Match[]
---@return greplace.List list
---@return greplace.Tracker tracker
function M.render(bufnr, matches)
    local lines = {}
    for i, m in ipairs(matches) do lines[i] = m.text end

    vim.bo[bufnr].modifiable = true
    M.clear_all(bufnr)
    set_lines_no_undo(bufnr, lines)

    local width   = location_width(matches)
    local entries, order, index, drawn = {}, {}, {}, {}

    -- The indicator column is only drawn when some match needs it, so a search
    -- that touched no open buffer gives up no width to it. When drawn, every
    -- row reserves it, keeping the locations and the `│` aligned.
    local indicator = false
    for _, m in ipairs(matches) do
        if m.bufnr then
            indicator = true; break
        end
    end

    for row, m in ipairs(matches) do
        -- Cropped on the left: the tail -- file name and line number -- is what
        -- tells one match from another, while the leading directories are the
        -- part they tend to share. `K` shows the whole path.
        local location = strutil.crop_for_ui(
            string.format("%s:%d", m.relpath, m.lnum), width, true)
        local pad      = string.rep(" ",
            math.max(0, width - vim.api.nvim_strwidth(location)))
        local virt     = {
            { location, "GreplaceLocation" },
            { pad .. " ", "GreplaceSeparator" },
            { _no_marker, "GreplaceChanged" },
            { "│ ", "GreplaceSeparator" },
        }
        if indicator then
            table.insert(virt, 1, {
                m.bufnr and _buffer_indicator or _no_indicator,
                "GreplaceBufferIndicator",
            })
        end
        local ok, id = pcall(set_anchor, bufnr, nil, row - 1, virt)
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
        drawn[id]   = virt
        order[row]  = id
        -- Both ends are clamped, not just the end one: a match span can start
        -- past the line we kept (rg counts the line terminator it stripped,
        -- and a `$`-anchored pattern lands there), and an out-of-range start
        -- column is an error, not a no-op.
        local len  = #m.text
        local hits = {}
        for _, sm in ipairs(m.subs) do
            local s = math.max(0, math.min(sm.s, len))
            local e = math.max(s, math.min(sm.e, len))
            if e > s then hits[#hits + 1] = { s = s, e = e } end
        end
        local hl_ok, hl_err = pcall(M.draw_hits, bufnr, row - 1, hits)
        if not hl_ok then
            error(string.format("%s:%d: %s", m.relpath, m.lnum, tostring(hl_err)), 0)
        end

        index[id]   = row
        entries[id] = {
            path    = m.path,
            relpath = m.relpath,
            lnum    = m.lnum,
            text    = m.text,
            hits    = hits,
        }
    end

    vim.bo[bufnr].modified = false
    return { entries = entries, order = order, index = index }, tracker.new(entries, drawn)
end

--- Put a one-line status in the panel: the buffer holds a single blank,
--- unmodifiable line, and the message rides on it as virtual text so it can
--- never be mistaken for a result line to edit.
---@param bufnr integer
---@param chunks table[]  virtual text chunks, as `nvim_buf_set_extmark`
function M.set_status(bufnr, chunks)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.bo[bufnr].modifiable = true
    M.clear_all(bufnr)
    set_lines_no_undo(bufnr, { "" })
    vim.api.nvim_buf_set_extmark(bufnr, _ns_st, 0, 0, {
        virt_text     = chunks,
        virt_text_pos = "inline",
    })
    vim.bo[bufnr].modified   = false
    vim.bo[bufnr].modifiable = false
end

return M
