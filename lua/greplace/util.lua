local M = {}

--- Absolute, symlink-resolved, normalized path, so buffer names and rg output
--- compare as strings (`/var/…` and `/private/var/…` name the same dir).
--- `expand_env = false`: a directory really called `$HOME` must not expand.
---@param path string
---@return string
function M.resolve(path)
    local abs = vim.fn.fnamemodify(path, ":p")
    return vim.fs.normalize(vim.uv.fs_realpath(abs) or abs, { expand_env = false })
end

--- Every loaded, named buffer, keyed by resolved path. Built once for callers
--- looking up many paths, since each `find_buf` costs a `realpath` per buffer.
--- The first buffer holding a path wins, matching `find_buf`'s order.
---@return table<string, integer> by_path
function M.buf_map()
    local by_path = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path = M.resolve(name)
                if by_path[path] == nil then by_path[path] = bufnr end
            end
        end
    end
    return by_path
end

--- The loaded buffer holding this exact file, if any. `bufnr()` is avoided
--- because it matches its argument as a pattern. `bufs` is an optional
--- prebuilt `M.buf_map()` to index instead of walking the buffer list.
---@param path string  absolute, resolved
---@param bufs table<string, integer>?  a prebuilt `M.buf_map()`
---@return integer? bufnr
function M.find_buf(path, bufs)
    if bufs then return bufs[path] end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" and M.resolve(name) == path then
                return bufnr
            end
        end
    end
end

--- The buffer for a file, loading it if it has none yet. One loaded here is
--- recorded in `bufs` for callers that go on looking paths up.
---@param path string  absolute, resolved
---@param bufs table<string, integer>?  a prebuilt `M.buf_map()`
---@return integer? bufnr, string? err
function M.ensure_buf(path, bufs)
    local bufnr = M.find_buf(path, bufs)
    if bufnr then return bufnr end
    if vim.fn.filereadable(path) ~= 1 then
        return nil, "not readable: " .. path
    end
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].buflisted = true
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        return nil, "could not load: " .. path
    end
    if bufs then bufs[path] = bufnr end
    return bufnr
end

return M
