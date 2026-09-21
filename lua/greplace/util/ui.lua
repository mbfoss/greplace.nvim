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


--- A scratch buffer; `buffer_options` override the defaults. `filetype` is set
--- last, after `on_delete` is hooked up, so `FileType` handlers see the final
--- options and a deletion from one still reaches `on_delete`.
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
    local filetype = bo.filetype
    bo.filetype = nil
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
    if filetype then
        vim.bo[buf].filetype = filetype
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
    local full_path = vim.fn.resolve(filepath)

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
            vim.notify("greplace: " .. tostring(err), vim.log.levels.WARN)
        end
        return -1, -1
    end
    vim.bo[bufnr].buflisted = true

    vim.api.nvim_win_set_buf(winid, bufnr)
    _safe_set_cursor_pos(winid, line, col)
    return winid, bufnr
end

return M
