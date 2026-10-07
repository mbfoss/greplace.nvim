---@class greplace.util.fixedwin
local M = {}

-- A split pinned along one axis to a ratio of the editor lines/columns,
-- re-applied on layout changes.

---@class greplace.util.fixedwin.AxisSpec
---@field sides {topleft: string, botright: string}  nvim_open_win() `split` direction per placement
---@field fix   string                    window option that pins the axis
---@field frame "col"|"row"               ancestor frame kind along which the axis is resized
---@field total fun(): integer            total lines/columns available
---@field get   fun(win: integer): integer
---@field set   fun(win: integer, n: integer)

---@type table<string, greplace.util.fixedwin.AxisSpec>
local _AXES = {
    height = {
        sides = { topleft = "above", botright = "below" },
        fix   = "winfixheight",
        frame = "col",
        total = function() return vim.api.nvim_get_option_value("lines", {}) end,
        get   = vim.api.nvim_win_get_height,
        set   = vim.api.nvim_win_set_height,
    },
    width = {
        sides = { topleft = "left", botright = "right" },
        fix   = "winfixwidth",
        frame = "row",
        total = function() return vim.api.nvim_get_option_value("columns", {}) end,
        get   = vim.api.nvim_win_get_width,
        set   = vim.api.nvim_win_set_width,
    },
}

-- `vim.wo[win].opt = val` also sets the global default new windows inherit
---@param win integer
---@param opt string
---@param val any
local function win_setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

---@param win integer
---@param opt string
local function win_getopt(win, opt)
    return vim.api.nvim_get_option_value(opt, { win = win })
end

-- Frames from the layout root down to `target`, with the child index taken.
---@param node   table    a vim.fn.winlayout() node
---@param target integer  window id
---@param path?  {node: table, index: integer}[]
---@return {node: table, index: integer}[]|nil  nil if `target` is not in `node`
local function frame_path(node, target, path)
    path = path or {}
    if node[1] == "leaf" then return node[2] == target and path or nil end
    for i, child in ipairs(node[2]) do
        path[#path + 1] = { node = node, index = i }
        if frame_path(child, target, path) then return path end
        path[#path] = nil
    end
    return nil
end

-- Whether some window in `node` lacks `fix`, so it can absorb freed space.
---@param node table   a vim.fn.winlayout() node
---@param fix  string  'winfixheight' or 'winfixwidth'
---@return boolean
local function has_flexible_leaf(node, fix)
    if node[1] == "leaf" then return not win_getopt(node[2], fix) end
    for _, child in ipairs(node[2]) do
        if has_flexible_leaf(child, fix) then return true end
    end
    return false
end

---@class greplace.util.fixedwin.Opts
---@field axis       "height"|"width"
---@field ratio      number               fraction of total lines/columns (0..1)
---@field min?       integer              minimum size (lines/columns); default 1
---@field enter?     boolean              enter the new window; default false
---@field pos?       "topleft"|"botright" edge of the editor to split at; default "botright"
---@field on_delete? fun(ratio: number)   called when the window closes, with the last-known ratio

--- Create a split showing `buf`, pinned to `opts.ratio` along `opts.axis` and
--- re-applied on layout changes. Moved to the other side (e.g. <C-w>L), it is
--- pinned along the cross axis with the same ratio, which follows user resizes.
---@param buf integer  buffer to display; 0 for the current buffer
---@param opts greplace.util.fixedwin.Opts
---@return integer winid, integer group
function M.create_fixed_win(buf, opts)
    local axis, ratio, on_delete = opts.axis, opts.ratio, opts.on_delete
    local spec = assert(_AXES[axis], "fixedwin: unknown axis " .. tostring(axis))
    local cross = axis == "height" and _AXES.width or _AXES.height
    local min = opts.min or 1
    local split = assert(spec.sides[opts.pos or "botright"], "fixedwin: unknown pos " .. tostring(opts.pos))

    -- win = -1 splits at the editor edge, like :topleft/:botright
    local win = vim.api.nvim_open_win(buf, opts.enter or false, { split = split, win = -1 }) ---@type integer?
    assert(win)

    win_setlocal(win, spec.fix, true)

    -- last-known ratio, updated on user resizes
    local state = { ratio = ratio }

    -- the axis currently pinned (`spec`, `cross`, or nil when neither is safe)
    local active = spec ---@type greplace.util.fixedwin.AxisSpec?

    ---@param s greplace.util.fixedwin.AxisSpec
    ---@param r number
    ---@return integer
    local function size_for(s, r)
        return math.max(min, math.floor(s.total() * r))
    end

    -- ignore WinResized echoes of our own sizing and of layout transients
    local last_applied ---@type integer?
    local settling = 0

    ---@param s greplace.util.fixedwin.AxisSpec
    ---@param n integer
    local function apply_size(s, n)
        s.set(win, n)
        last_applied = s.get(win)
    end

    apply_size(spec, size_for(spec, ratio))

    -- the window's own tabpage layout (winlayout() defaults to the current tab)
    ---@return table
    local function layout_of_win()
        local tabnr = vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(win))
        return vim.fn.winlayout(tabnr)
    end

    -- layout events fire for every tabpage; only our own tab can move this window
    ---@param other integer  window id
    ---@return boolean
    local function same_tab(other)
        if not win or not vim.api.nvim_win_is_valid(win) then return false end
        if not vim.api.nvim_win_is_valid(other) then return false end
        return vim.api.nvim_win_get_tabpage(other) == vim.api.nvim_win_get_tabpage(win)
    end

    -- Pinning along `s` is safe when the nearest ancestor frame on that axis
    -- has another branch with a non-fixed window to absorb the freed space.
    ---@param s greplace.util.fixedwin.AxisSpec
    ---@param layout table  vim.fn.winlayout()
    ---@return boolean
    local function pinnable(s, layout)
        local path = frame_path(layout, win) or {}
        for i = #path, 1, -1 do
            local step = path[i]
            if step.node[1] == s.frame then
                for j, sibling in ipairs(step.node[2]) do
                    if j ~= step.index and has_flexible_leaf(sibling, s.fix) then
                        return true
                    end
                end
                return false
            end
        end
        return false
    end

    -- whether we set the cross fix option (one set by the caller is left alone)
    local cross_owned = false

    -- Pick the axis to pin (requested first, else cross) and set only its fix
    -- option, so an unmanaged axis does not freeze enclosing frames.
    local function sync_fix()
        if not win or not vim.api.nvim_win_is_valid(win) then active = nil return end
        local layout = layout_of_win()
        active = (pinnable(spec, layout) and spec)
            or (pinnable(cross, layout) and cross)
            or nil
        local on = active == spec
        if win_getopt(win, spec.fix) ~= on then win_setlocal(win, spec.fix, on) end
        if active == cross and not win_getopt(win, cross.fix) then
            win_setlocal(win, cross.fix, true)
            cross_owned = true
        elseif active ~= cross and cross_owned then
            win_setlocal(win, cross.fix, false)
            cross_owned = false
        end
    end

    -- re-pin to the tracked ratio along the active axis
    local function repin()
        sync_fix()
        if active then apply_size(active, size_for(active, state.ratio)) end
    end

    -- clear the fix option if the new window cannot be managed
    sync_fix()

    -- layout structure (no sizes), to detect <C-w>HJKL moves on WinResized
    local last_layout = vim.inspect(layout_of_win())

    -- Re-pin on the next tick, twice so fix options settle across fixed windows.
    -- `settling` counts pending absorptions to ignore their transient resizes.
    local function absorb_layout_change()
        settling = settling + 1
        vim.schedule(function()
            repin()
            vim.schedule(function()
                repin()
                if win and vim.api.nvim_win_is_valid(win) then
                    last_layout = vim.inspect(layout_of_win())
                end
                vim.schedule(function() settling = settling - 1 end)
            end)
        end)
    end

    local group = vim.api.nvim_create_augroup("NeoToolitFixedWin" .. win, { clear = true })

    -- re-apply the size when a new *split* appears so the window stays pinned
    vim.api.nvim_create_autocmd("WinNew", {
        group    = group,
        callback = function()
            -- the just-created window is transiently current during WinNew
            local new = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_config(new).relative == "" and same_tab(new) then
                absorb_layout_change()
            end
        end,
    })

    -- total lines/columns changed: re-pin to keep the ratio
    vim.api.nvim_create_autocmd("VimResized", {
        group    = group,
        callback = absorb_layout_change,
    })

    -- a changed layout means a window moved; otherwise track manual resizes
    vim.api.nvim_create_autocmd("WinResized", {
        group    = group,
        callback = function()
            if not same_tab(vim.api.nvim_get_current_win()) then return end
            local layout = vim.inspect(layout_of_win())
            if layout ~= last_layout then
                last_layout = layout
                absorb_layout_change()
                return
            end
            if settling > 0 or not active then return end
            local size = active.get(win)
            if size ~= last_applied then
                state.ratio = size / active.total()
                last_applied = size
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group    = group,
        callback = function(args)
            local closed = tonumber(args.match)
            if not closed then return end
            if closed == win then
                win = nil
                vim.api.nvim_del_augroup_by_id(group)
                if on_delete then on_delete(state.ratio) end
            elseif same_tab(closed) and vim.api.nvim_win_get_config(closed).relative == "" then
                absorb_layout_change()
            end
        end,
    })

    return win, group
end

return M
