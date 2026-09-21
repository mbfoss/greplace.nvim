-- Drawing the panel: a result list as buffer lines with an anchor and a bounds
-- mark per match, or a status in place of one.

local config        = require("greplace.config").current
local strutil       = require("greplace.util.strutil")
local marks         = require("greplace.panel.marks")
local winbar        = require("greplace.panel.winbar")

local set_anchor    = marks.set_anchor
local set_bounds    = marks.set_bounds
local tally         = marks.tally
local undo_seq      = marks.undo_seq
local set_winbar    = winbar.set_winbar

local _ns          = marks.ns
local _ns_bounds   = marks.ns_bounds
local _ns_hl       = vim.api.nvim_create_namespace("greplace.match")
local _ns_st       = vim.api.nvim_create_namespace("greplace.status")

local M = {}

--- Take everything the panel drew off a buffer: anchors, bounds, match
--- highlights and the status text.
---@param bufnr integer
local function clear_all(bufnr)
    for _, ns in ipairs({ _ns, _ns_bounds, _ns_hl, _ns_st }) do
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

--- Write the match list into the panel buffer and (re)anchor one extmark per
--- match. Entries are keyed by the returned extmark ids.
---@param bufnr   integer
---@param state   greplace.PanelState
---@param matches greplace.Match[]
local function render(bufnr, state, matches)
    local lines = {}
    for i, m in ipairs(matches) do lines[i] = m.text end

    vim.bo[bufnr].modifiable = true
    clear_all(bufnr)
    set_lines_no_undo(bufnr, lines)

    local width              = location_width(matches)
    state.entries             = {}
    state.order               = {}
    state.index               = {}
    state.virt                = {}
    state.hidden              = {}
    state.changed             = {}
    state.ticks               = 0
    -- A status from before is not this list's.
    state.message             = nil
    state.seq, state.seq_last = undo_seq(bufnr)
    state.stats               = { files = 0, lines = 0, changes = 0 }
    state.per_file            = {}

    -- The indicator column is only drawn when some match needs it, so a search
    -- that touched no open buffer gives up no width to it. When drawn, every
    -- row reserves it, keeping the locations and the `│` aligned.
    local indicator           = false
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
        local ok, id = pcall(set_anchor, bufnr, state, nil, row - 1, virt)
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
    set_winbar(bufnr, state)
end

--- Put a one-line status in the panel: the buffer holds a single blank,
--- unmodifiable line, and the message rides on it as virtual text so it can
--- never be mistaken for a result line to edit.
---@param bufnr integer
---@param chunks table[]  virtual text chunks, as `nvim_buf_set_extmark`
local function set_status(bufnr, chunks)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.bo[bufnr].modifiable = true
    clear_all(bufnr)
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
---@param state greplace.PanelState
---@param msg   string
---@param hl    string?
function M.set_message(bufnr, state, msg, hl)
    state.message = msg
    set_status(bufnr, { { msg, hl or "GreplaceStatus" } })
    set_winbar(bufnr, state, msg)
end

--- A render that did not finish leaves the panel holding the error rather than
--- a list that is missing rows without saying which. What it had recorded of
--- the list goes too: a reload refills the panel from `state.order`, and would
--- otherwise bring the partial list back, editable. `set_message` also makes
--- the buffer unmodifiable, so nothing is written back from it.
---@param bufnr integer
---@param state greplace.PanelState
---@param err   any
local function render_failed(bufnr, state, err)
    state.entries, state.order, state.index = {}, {}, {}
    state.virt, state.hidden, state.changed = {}, {}, {}
    state.stats, state.per_file = nil, nil
    M.set_message(bufnr, state, "render failed: " .. tostring(err), "ErrorMsg")
end

M.ns_hl = _ns_hl
M.set_marker = set_marker
M.clear_all = clear_all
M.render = render
M.set_status = set_status
M.render_failed = render_failed

return M
