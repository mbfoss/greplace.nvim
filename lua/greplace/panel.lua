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

local util     = require("greplace.util")

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

---@param on_write fun(bufnr:integer)
---@return integer bufnr
local function create_buf(on_write)
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

    for row, m in ipairs(matches) do
        local location = string.format("%s:%d", m.relpath, m.lnum)
        local pad      = string.rep(" ", width - vim.fn.strdisplaywidth(location))
        local id       = vim.api.nvim_buf_set_extmark(bufnr, _ns, row - 1, 0, {
            virt_text     = {
                { location, m.bufnr and "GreplaceBufferLocation" or "GreplaceLocation" },
                { pad .. " │ ",                                   "GreplaceSeparator" },
            },
            virt_text_pos = "inline",
            -- Text typed at the start of a line belongs after the location, so
            -- the anchor must not drift right with it.
            right_gravity = false,
        })
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

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1, {})
    local total = vim.api.nvim_buf_line_count(bufnr)
    local out   = {}

    for i, mark in ipairs(marks) do
        local id, row = mark[1], mark[2]
        local entry   = state.entries[id]
        if entry then
            local next_mark = marks[i + 1]
            local stop      = next_mark and next_mark[2] or total
            out[#out + 1]   = {
                entry = entry,
                lines = stop > row and vim.api.nvim_buf_get_lines(bufnr, row, stop, false) or {},
            }
        end
    end
    return out
end

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

return M
