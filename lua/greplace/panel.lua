local M                = {}

-- The `greplace://greplace-matches` scratch buffer: its lifecycle, keymaps and
-- public interface. The marks that record the list, and what keeps them true
-- to the lines, are described at the top of `panel/marks.lua`.

local config             = require("greplace.config").current
local util               = require("greplace.util")
local ui                 = require("greplace.util.ui")
local marks              = require("greplace.panel.marks")
local winbar             = require("greplace.panel.winbar")
local draw               = require("greplace.panel.render")

local _buffer_name       = "greplace://greplace-matches"

--- The state of each panel buffer. Owned here: the other modules are handed
--- the state they work on, and never look one up.
---@type table<integer, greplace.PanelState>
local _state             = {}

--- Per panel buffer: drops the rows its line watch has queued for a pass. A
--- render replaces every line, which queues a pass over the whole list that
--- has nothing to find in what was just laid out.
---@type table<integer, fun()>
local _drop_pending      = {}

local _ns                = marks.ns
local _ns_hl             = draw.ns_hl
local clear_all          = draw.clear_all
local is_hidden          = marks.is_hidden
local redraw             = marks.redraw
local set_anchor         = marks.set_anchor
local standing_before    = marks.standing_before
local restore_marks      = marks.restore_marks
local guard_lines        = marks.guard_lines
local undo_seq           = marks.undo_seq
local set_winbar         = winbar.set_winbar
local set_status         = draw.set_status

-- The panel is the only module that writes a `greplace.PanelState`. `render`
-- hands back a list and a tracker, `marks.redraw` reports what changed on the
-- lines, and both are taken into the state below (`render_list`,
-- `redraw_marks`); the tracker holds what changes as the list is edited, and
-- only it moves it.

---@class greplace.Entry
---@field path    string   absolute file path
---@field relpath string
---@field lnum    integer  1-indexed line in the source file
---@field text    string   the source line as it was when the panel rendered

---State of the one panel buffer: the anchor extmark id of each match, and the
---query it was built from. Written by this module alone; the others read it.
---@class greplace.PanelState
---@field query   string
---@field source  string   where the list came from: "search" or "quickfix"
---@field root    string
---@field flags   table?   `:Gsearch` flags the search was run with, so
---                        that re-running it means the same search
---@field entries table<integer, greplace.Entry>  keyed by anchor extmark id;
---                        replaced by a render or a write, never edited
---@field order   integer[]  anchor extmark ids in listing order
---@field index   table<integer, integer>  each anchor's position in `order`
---@field tracker greplace.Tracker?  which matches lost their line or were
---                        edited, the winbar's counts and what each anchor
---                        draws; set once a result list is rendered
---@field truncated boolean  the search stopped at the match limit, so this is
---                          the first `limit` matches of more
---@field message string?  final status -- "no matches", or the error that
---                       ended the search -- kept so a redraw can restore it
---@field ticks   integer?  how many changes the line watch has seen, which is
---                        how a spec tells one watch from two
---@field seq      integer?  the undo state the last pass saw, and
---@field seq_last integer?  the newest one there was: an undo or a redo moves
---                        between states without adding one, and that is the
---                        one change whose text needs nothing done to it

---@class greplace.Region
---@field id    integer   the anchor extmark id of the match
---@field entry greplace.Entry  a copy: `apply.run` restates it, and the panel
---                        only takes that back through `M.settle`
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
    if not state.tracker or state.tracker.stats.changes == 0 then
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
    -- walked as far as the next edit. The tracker's `changed` is keyed by anchor, and
    -- an anchor's row is where its line begins, so the row it gives is the
    -- edited line itself. Deleting a line leaves its anchor on the row of the
    -- next one, so an edited row can be reached twice over; being in order,
    -- those repeats are neighbours, and comparing against the row in hand is
    -- enough to count it once.
    --
    -- The API hands back the whole range it is asked for, so it is asked for a
    -- `limit` of it at a time, doubling until the count is met or the range
    -- runs out.
    local from  = dir > 0 and { row + 1, 0 } or { row - 1, -1 }
    local to    = dir > 0 and -1 or 0
    local limit = 64
    local left, target
    while true do
        left, target = vim.v.count1, nil
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, _ns, from, to,
            { details = true, limit = limit })
        for _, mark in ipairs(marks) do
            -- A removed match keeps its changed flag but no row: its anchor is
            -- stranded on whichever line is next.
            if state.tracker:is_changed(mark[1]) and not is_hidden(mark) and mark[2] ~= target then
                target = mark[2]
                left   = left - 1
                -- The rest of the walk is what a count asked for; the edits
                -- beyond it are no business of this one.
                if left == 0 then break end
            end
        end
        if left == 0 or #marks < limit then break end
        limit = limit * 2
    end
    if not target then
        vim.api.nvim_echo({ { "greplace: no more edits" } }, false, {})
        return
    end
    -- A jump, so `''` and `<C-o>` come back to where the cursor was.
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

--- Read rows `lo`..`hi` against the list, and take what differs into the
--- tracker: a match that lost its line or got it back, a line that started or
--- stopped differing from its rendered text -- which is also drawn.
---@param bufnr integer
---@param state greplace.PanelState
---@param lo    integer  0-indexed
---@param hi    integer  0-indexed, inclusive
local function redraw_marks(bufnr, state, lo, hi)
    local tracker = state.tracker
    for _, move in ipairs(redraw(bufnr, state, lo, hi)) do
        if move.hidden ~= nil then
            tracker:set_hidden(move.id, move.hidden)
        end
        if move.changed ~= nil then
            tracker:set_changed(move.id, move.changed)
            tracker:set_drawn(move.id, draw.with_marker(tracker.drawn[move.id], move.changed))
            set_anchor(bufnr, state, move.id, move.row)
        end
    end
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
        _drop_pending[bufnr] = nil
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
        buffer   = bufnr,
        desc     = "greplace: apply edits to buffers in memory",
        -- `nested`, because the write loads the files it edits into buffers:
        -- without it their `BufReadPost`/`FileType` never fire (autocommands
        -- do not nest by default), so those buffers come up with no filetype
        -- and hence no syntax, treesitter or LSP -- and stay that way, being
        -- already loaded by the time the user opens one.
        nested   = true,
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
        buffer   = bufnr,
        desc     = "greplace: a reload refills the panel from the stored lines",
        callback = function()
            local state = _state[bufnr]
            if state and state.tracker then
                local entries = {}
                for _, id in ipairs(state.order) do
                    entries[#entries + 1] = state.entries[id]
                end
                vim.bo[bufnr].modifiable = true
                -- A failed refresh leaves the panel showing its error (and
                -- holding no list), which is what is kept.
                M.refresh(bufnr, entries)
                watch()
                return
            end
            _state[bufnr] = nil
            clear_all(bufnr)
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
        group    = group,
        desc     = "greplace: never prompt to save the panel on exit",
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
    watch          = function()
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
                    local repaired      = false
                    if st.tracker and seq_last == st.seq_last and seq ~= st.seq then
                        repairs = 0
                        restore_marks(bufnr, st, lo, hi)
                        -- A repair is a change of its own, which gets a pass of
                        -- its own -- and that pass finds nothing left to repair.
                        -- More than a handful in a row means one is making work
                        -- for the next, and the panel stops rather than rewriting
                        -- the buffer under the user's hands forever.
                    elseif repairs < 8 and guard_lines(bufnr, st, lo, hi) then
                        repairs  = repairs + 1
                        repaired = true
                    else
                        repairs = 0
                    end
                    -- Only a repair rewrites text, so only then can the undo
                    -- state have moved since it was read above.
                    if repaired then seq, seq_last = undo_seq(bufnr) end
                    st.seq, st.seq_last = seq, seq_last
                    redraw_marks(bufnr, st, lo, hi)
                    if st.tracker then set_winbar(bufnr, st) end
                end)
            end,
        })
    end
    _drop_pending[bufnr] = function() pending = nil end
    watch()
    return bufnr
end

--- Show the panel in a split, reusing the window it already occupies.
---@param bufnr  integer
---@param height integer
local function show(bufnr, height)
    local win = M.win(bufnr)
    if win then
        vim.api.nvim_set_current_win(win)
        return
    end
    vim.cmd(string.format("botright %dsplit", height))
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.wo[0][0].wrap       = false
    vim.wo[0][0].signcolumn = "no"
    vim.wo[0][0].spell      = config.spell
    -- The panel keeps its window: <CR> (and anything else that opens a file)
    -- must land in a regular window rather than covering the results.
    vim.wo[0][0].winfixbuf  = true
    -- A new window has no winbar of its own, and none is drawn until the next
    -- edit otherwise.
    set_winbar(bufnr, _state[bufnr])
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
M.show = show

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

-- The panel opens the moment a search is triggered, before there is anything
-- to show, so the results land in a window that is already there rather than
-- one that appears seconds later under the cursor. Until they do, the buffer
-- holds a single blank line carrying the status as virtual text: that the
-- search is running, and afterwards whatever came of it if it produced no list
-- to render.

--- The state of a panel that holds no list yet.
---@param opts { query:string, root:string, flags:table?, truncated:boolean?, source:string? }
---@return greplace.PanelState
local function new_state(opts)
    return {
        query     = opts.query,
        root      = opts.root,
        -- Copied: the caller keeps its own table, and the state must not
        -- change with it (nor it with the state, on a re-run).
        flags     = opts.flags and vim.deepcopy(opts.flags),
        -- Where the list came from, so a re-run knows what to run again: a
        -- search ("search", the default) or the quickfix list ("quickfix").
        source    = opts.source or "search",
        entries   = {},
        order     = {},
        index     = {},
        truncated = opts.truncated or false,
    }
end

--- Put a final message in place of the list, and remember it so that a redraw
--- of the winbar restores it.
---@param bufnr integer
---@param state greplace.PanelState
---@param msg   string
---@param hl    string?
local function show_message(bufnr, state, msg, hl)
    state.message = msg
    set_status(bufnr, { { msg, hl or "GreplaceStatus" } })
    set_winbar(bufnr, state, msg)
end

--- Render a result list into the panel. A render that fails leaves the panel
--- holding the error rather than a list that is missing rows without saying
--- which.
---@param bufnr   integer
---@param matches greplace.Match[]
---@return string? err
local function render_list(bufnr, matches)
    local state = assert(_state[bufnr])
    local ok, list, tracker = pcall(draw.render, bufnr, matches)
    -- The pass the write queued has nothing to find in what was just laid out.
    local drop = _drop_pending[bufnr]
    if drop then drop() end
    if not ok then
        -- Nothing of the list is kept: a reload refills the panel from
        -- `state.order`, and would otherwise bring a partial one back,
        -- editable. `show_message` also makes the buffer unmodifiable, so
        -- nothing is written back from it.
        state.entries, state.order, state.index, state.tracker = {}, {}, {}, nil
        show_message(bufnr, state, "render failed: " .. tostring(list), "ErrorMsg")
        return tostring(list)
    end
    state.entries, state.order, state.index = list.entries, list.order, list.index
    state.tracker = tracker
    -- A status from before is not this list's.
    state.message = nil
    state.ticks   = 0
    state.seq, state.seq_last = undo_seq(bufnr)
    set_winbar(bufnr, state)
end

--- Open the panel before there are any results, showing the query and that the
--- search is running. `M.open` takes the same buffer over when it comes back.
---@param opts { query:string, root:string, flags:table?, height:integer, on_write:fun(bufnr:integer), on_delete:fun()? }
---@return integer bufnr
function M.open_loading(opts)
    local bufnr   = M.find_buf() or create_buf(opts.on_write, opts.on_delete)
    _state[bufnr] = new_state(opts)
    show(bufnr, opts.height)
    set_winbar(bufnr, _state[bufnr], "searching ...")
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
    _state[bufnr] = new_state(opts)
    show(bufnr, opts.height)
    return bufnr, render_list(bufnr, matches)
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
    return render_list(bufnr, matches)
end

--- What the panel currently holds: see `greplace.Stats`.
---@param bufnr integer
---@return greplace.Stats?  nil when the buffer is not a rendered panel
function M.stats(bufnr)
    return winbar.stats(_state[bufnr])
end

--- Replace the "searching" status with a final message -- "no matches", or
--- the error that ended the search. The panel stays up: it was opened on the
--- user's keystroke, and yanking it away again is more startling than leaving
--- it saying what happened.
---@param bufnr integer
---@param msg   string
---@param hl    string?
function M.set_message(bufnr, msg, hl)
    local state = _state[bufnr]
    if state then show_message(bufnr, state, msg, hl) end
end

--- Redraw the markers and counts after a write, leaving the text and undo
--- history alone: `u` then walks back to the pre-write text, which differs from
--- the entries `apply.run` restated, so writing again reverts the source.
---@param bufnr   integer
---@param regions greplace.Region[]  as `M.regions` gave them, after `apply.run`
---                                  restated their entries
function M.settle(bufnr, regions)
    local state = _state[bufnr]
    if not state or not state.tracker then return end
    -- A table of its own rather than the entries edited in place: what
    -- `state.entries` was is not touched.
    local entries = {}
    for id, entry in pairs(state.entries) do entries[id] = entry end
    for _, region in ipairs(regions) do
        if entries[region.id] then entries[region.id] = region.entry end
    end
    state.entries = entries
    -- The highlighted query hits belong to the text as searched, not to what
    -- has been written over it since.
    vim.api.nvim_buf_clear_namespace(bufnr, _ns_hl, 0, -1)
    redraw_marks(bufnr, state, 0, math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1))
    vim.bo[bufnr].modified = false
    set_winbar(bufnr, state)
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

    local total       = vim.api.nvim_buf_line_count(bufnr)
    local marks       = vim.api.nvim_buf_get_extmarks(bufnr, _ns, 0, -1, { details = true })
    local out         = {}

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
            out[#out + 1] = {
                id    = id,
                entry = {
                    path    = entry.path,
                    relpath = entry.relpath,
                    lnum    = entry.lnum,
                    text    = entry.text,
                },
                lines = lines[id] or {},
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
        GreplaceLocation        = { link = "@namespace" },
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
