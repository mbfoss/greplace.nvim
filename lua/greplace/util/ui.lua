local M = {}

local function _is_regular_win(winid)
    if not vim.api.nvim_win_is_valid(winid) then return false end
    local cfg = vim.api.nvim_win_get_config(winid)
    if cfg.relative ~= "" then return false end      -- skip popups
    if vim.wo[winid].winfixbuf then return false end -- skip fixed windows
    return true
end

---@param winid integer
---@param line? integer 1-based line number (nil = just open)
---@param col?  integer 0-based column (nil = column 0)
local function _safe_set_cursor_pos(winid, line, col)
    if not (line and type(line) == 'number' and line > 0) then return end
    if not vim.api.nvim_win_is_valid(winid) then return end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local maxline = vim.api.nvim_buf_line_count(bufnr)
    line = math.min(line, maxline)
    local line_length = #vim.api.nvim_buf_get_lines(bufnr, line - 1, line, true)[1]
    if col and type(col) == 'number' and col >= 0 then
        col = math.min(col, line_length)
    else
        col = 0
    end
    vim.api.nvim_win_set_cursor(winid, { line, col })
end

---@return number winid
local function _get_regular_window()
    local cur_win = vim.api.nvim_get_current_win()
    if _is_regular_win(cur_win) then
        return cur_win
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if winid ~= cur_win and _is_regular_win(winid) then
            return winid
        end
    end

    vim.cmd('vsplit')
    local newwin = vim.api.nvim_get_current_win()
    -- A split inherits window-local options from its parent, so splitting off a
    -- winfixbuf panel yields a winfixbuf window too; clear it so a file can load.
    vim.wo[newwin].winfixbuf = false
    return newwin
end


--- @param buffer integer Buffer to display, or 0 for current buffer
--- @param enter boolean Enter the window (make it the current window)
--- @param config vim.api.keyset.win_config Map defining the window configuration
--- @param on_close function
--- @return integer winid, integer augroup
function M.create_window(buffer, enter, config, on_close)
    local win = vim.api.nvim_open_win(buffer, enter, config)
    local augroup = vim.api.nvim_create_augroup("neotoolkit_window_#" .. win, { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        callback = function(args)
            local closedwin = tonumber(args.match)
            if closedwin == win then
                vim.api.nvim_del_augroup_by_id(augroup)
                on_close()
            end
        end
    })
    return win, augroup
end

---@param listed boolean
---@param buffer_options vim.bo?
---@param on_delete function?
function M.create_scratch_buffer(listed, buffer_options, on_delete)
    local buf = vim.api.nvim_create_buf(listed, true)
    local bo = { ---@type vim.bo
        buftype = "nofile",
        swapfile = false,
        modeline = false,
    }
    if not listed then
        bo.bufhidden = 'wipe'
    end
    if buffer_options then
        for k, v in pairs(buffer_options) do
            bo[k] = v
        end
    end
    for k, v in pairs(bo) do
        vim.bo[buf][k] = v
    end
    if on_delete then
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = buf,
            once = true,
            callback = function(ev)
                on_delete()
            end,
        })
    end
    return buf
end

---@param filepath string
---@param line? integer 1-based line number (nil = just open)
---@param col?  integer 0-based column (nil = column 0)
---@param activate boolean? activates the file window
---@return number winid or -1
---@return number bufnr or -1
function M.smart_open_file(filepath, line, col, activate)
    if line and line < 1 then line = nil end
    if col and col < 0 then col = nil end
    if not filepath or filepath == "" then return -1, -1 end
    local full_path = vim.fn.fnamemodify(filepath, ':p')

    -- Don't conjure an empty buffer for a path with neither a live buffer nor a
    -- file on disk. (bufadd() would happily create a phantom entry for a
    -- nonexistent file, so we still need this exact-match precheck.) The buffer
    -- list scan only runs for paths missing from disk, which is the rare case.
    if vim.fn.filereadable(full_path) == 0 then
        local pattern = '^' .. vim.fn.escape(full_path, '\\[]*?~$.') .. '$'
        if vim.fn.bufnr(pattern) == -1 then
            return -1, -1
        end
    end

    -- Reuse a window already showing this file.
    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if _is_regular_win(winid) then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            if vim.api.nvim_buf_get_name(bufnr) == full_path then
                if activate ~= false then
                    vim.api.nvim_set_current_win(winid)
                end
                _safe_set_cursor_pos(winid, line, col)
                return winid, bufnr
            end
        end
    end

    local winid = _get_regular_window()
    if activate ~= false then
        vim.api.nvim_set_current_win(winid)
    end

    -- Exact-path lookup/create, no glob or fuzzy fallback. bufadd() only makes
    -- the (unloaded) entry; `:buffer` below does the reading.
    local bufnr = vim.fn.bufadd(full_path)

    -- `:buffer <nr>` rather than nvim_win_set_buf(): it takes the buffer by
    -- number (no name matching), but unlike the API call it sets the alternate
    -- file and the jump mark, so <C-^> and <C-o> still work after a jump. Run it
    -- in the resolved regular window, not the current one, which may be a
    -- winfixbuf panel when activate == false.
    --
    -- pcall is required here: the load can abort for reasons the caller cannot
    -- check for up front -- an existing swap file the user answers "quit" to, an
    -- unreadable file, E37 on a modified buffer under 'nohidden' -- and an
    -- uncaught Vim error unwinds into the picker callback as a stack traceback.
    local ok, err = pcall(vim.fn.win_execute, winid, "buffer " .. bufnr)
    if not ok or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr then
        -- Aborted: leave the window on whatever it was showing, and leave the
        -- buffer unlisted so a failed open does not litter `:ls`.
        if not ok and err and err ~= "" then
            vim.notify("neotoolkit: " .. tostring(err), vim.log.levels.WARN)
        end
        return -1, -1
    end
    vim.bo[bufnr].buflisted = true

    _safe_set_cursor_pos(winid, line, col)
    return winid, bufnr
end

---@param bufnr integer
---@param line? integer 1-based line number (nil = just open)
---@param col?  integer 0-based column (nil = column 0)
---@return number winid
function M.smart_open_buffer(bufnr, line, col)
    local winid = _get_regular_window()
    vim.api.nvim_set_current_win(winid)
    vim.fn.win_execute(winid, "buffer " .. bufnr)
    _safe_set_cursor_pos(winid, line, col)
    return winid
end

---@param msg string
---@param default_yes boolean
---@param callback fun(confirmed: boolean|nil)
function M.confirm_action(msg, default_yes, callback)
    local choices = "&Yes\n&No"
    local default = default_yes and 1 or 2

    local ok, choice = pcall(vim.fn.confirm, msg, choices, default)
    if not ok then
        callback(nil)
        return
    end
    if choice == 1 then
        callback(true)
    elseif choice == 2 then
        callback(false)
    else
        callback(nil)
    end
end

---Pull content down into any blank space at the bottom of a window so the viewport
---stays full instead of showing a few lines over a field of `~`. Scrolls the view
---only (never the cursor), and only when there are earlier lines to pull down.
---@param winid integer
function M.fill_viewport(winid)
    if not vim.api.nvim_win_is_valid(winid) then return end
    local h    = vim.api.nvim_win_get_height(winid)
    local info = vim.fn.getwininfo(winid)[1]
    if not info then return end

    local visible = info.botline - info.topline + 1
    if visible >= h or info.topline <= 1 then return end

    vim.api.nvim_win_call(winid, function()
        local view   = vim.fn.winsaveview()
        view.topline = math.max(1, view.topline - (h - visible))
        vim.fn.winrestview(view)
    end)
end

---Convert a color to a 24-bit integer.
---@param color integer|string
---@return integer
function M.normalize_color(color)
    if type(color) == "number" then
        return color
    end
    if type(color) == "string" then
        color = color:gsub("^#", "")
        local n = tonumber(color, 16)
        if n then
            return n
        end
    end
    error("invalid color: " .. tostring(color))
end

---Linearly blend two 24-bit integer colors.
---@param c1 integer|string  -- base color
---@param c2 integer|string  -- blend-toward color
---@param alpha number  -- 0 = all c1, 1 = all c2
---@return integer
function M.blend_colors(c1, c2, alpha)
    c1, c2 = M.normalize_color(c1), M.normalize_color(c2)
    local r1 = bit.rshift(c1, 16)
    local g1 = bit.band(bit.rshift(c1, 8), 0xFF)
    local b1 = bit.band(c1, 0xFF)
    local r2 = bit.rshift(c2, 16)
    local g2 = bit.band(bit.rshift(c2, 8), 0xFF)
    local b2 = bit.band(c2, 0xFF)
    local r = math.floor(r1 * (1 - alpha) + r2 * alpha)
    local g = math.floor(g1 * (1 - alpha) + g2 * alpha)
    local b = math.floor(b1 * (1 - alpha) + b2 * alpha)
    return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
end

---Return `basename` if no buffer has that name, otherwise `basename#1`, `basename#2`, …
---@param basename string
---@return string
function M.unique_buf_name(basename)
    local name = basename
    local n    = 0
    while vim.fn.bufnr(name) ~= -1 do
        n    = n + 1
        name = basename .. "~" .. n
    end
    return name
end

return M
