local M = {}

--- Absolute, symlink-resolved, normalized form of a path. Buffer names, the
--- search root and rg's output must all agree before they can be compared as
--- strings — on macOS a temp dir alone is reached through two spellings
--- (`/var/…` and `/private/var/…`).
---@param path string
---@return string
function M.resolve(path)
    local abs = vim.fn.fnamemodify(path, ":p")
    return vim.fs.normalize(vim.uv.fs_realpath(abs) or abs)
end

--- The loaded buffer holding this exact file, if any. `bufnr()` is avoided
--- here: it matches its argument as a pattern, so a path can resolve to an
--- unrelated buffer.
---@param path string  absolute, resolved
---@return integer? bufnr
function M.find_buf(path)
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
---@param path string  absolute, resolved
---@return integer? bufnr, string? err
function M.ensure_buf(path)
    local bufnr = M.find_buf(path)
    if bufnr then return bufnr end
    if vim.fn.filereadable(path) ~= 1 then
        return nil, "not readable: " .. path
    end
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        return nil, "could not load: " .. path
    end
    return bufnr
end

return M
