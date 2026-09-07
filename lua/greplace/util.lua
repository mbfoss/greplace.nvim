local M = {}

--- Absolute, symlink-resolved, normalized form of a path. Buffer names, the
--- search root and rg's output must all agree before they can be compared as
--- strings: on macOS a temp dir alone is reached through two spellings
--- (`/var/…` and `/private/var/…`).
---
--- `expand_env = false`: `vim.fs.normalize` otherwise substitutes `$NAME` from
--- the environment, so a directory really called `$HOME` resolves to a path
--- that does not exist and the panel cannot write back to.
---@param path string
---@return string
function M.resolve(path)
    local abs = vim.fn.fnamemodify(path, ":p")
    return vim.fs.normalize(vim.uv.fs_realpath(abs) or abs, { expand_env = false })
end

--- Every loaded, named buffer, keyed by the resolved path it holds.
---
--- Resolving a path costs a `realpath` syscall, and there is one buffer name
--- to resolve per buffer, so a `find_buf` is O(buffers) syscalls -- fine once,
--- ruinous per entry of a list that can hold `limit` of them. A caller with
--- more than a handful of paths to look up builds this once and indexes it
--- instead: the syscalls are then one per buffer rather than one per buffer
--- per lookup.
---
--- The first buffer holding a path wins, which is the one `find_buf` returns:
--- both walk `nvim_list_bufs()` in its order.
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
--- here: it matches its argument as a pattern, so a path can resolve to an
--- unrelated buffer.
---
--- `bufs` is a `M.buf_map()` to read instead of walking the buffer list, for
--- a caller looking up many paths at once.
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

--- The buffer for a file, loading it into one if it has none yet.
---
--- A buffer loaded here is not in `bufs`, which was built before it existed,
--- so it is recorded there for the callers that go on looking paths up.
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
