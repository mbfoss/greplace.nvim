local M = {}

-- ---------------------------------------------------------------------------
-- greplace
--
-- `:Gsearch <query>` greps the working tree and collects every matching
-- line into a `greplace://replace` split. The lines are plain, editable text
-- (the `file:line` prefix is virtual), and writing the buffer pushes each edited
-- line back to its source — in buffers, never to disk.
-- ---------------------------------------------------------------------------

local panel  = require("greplace.panel")
local search = require("greplace.search")

---@class greplace.Config
---@field height integer?  height of the result split (default 15)
---@field limit  integer?  maximum matches collected per search (default 2000)

---@type greplace.Config
M.config = {
    height = 15,
    limit  = 2000,
}

---@param bufnr integer
local function on_write(bufnr)
    local apply  = require("greplace.apply")
    local result = apply.run(panel.regions(bufnr))

    panel.refresh(bufnr, result.entries)

    local msg   = string.format("greplace: %d line(s) in %d buffer(s), unsaved",
        result.replaced, result.files)
    local level = vim.log.levels.INFO
    if result.skipped > 0 then
        msg   = msg .. string.format("; %d skipped (source line moved)", result.skipped)
        level = vim.log.levels.WARN
    end
    vim.notify(msg, level)
end

---@class greplace.OpenOpts
---@field regex boolean?  treat the query as a regex instead of a literal
---@field cwd   string?   search root (default: current directory)

--- Run a search and open the panel on its results.
---@param query string
---@param opts  greplace.OpenOpts?
function M.open(query, opts)
    opts = opts or {}
    local root = search.resolve_root(opts.cwd)

    search.run(query, { cwd = root, regex = opts.regex, limit = M.config.limit },
        function(matches, err)
            vim.schedule(function()
                if err then
                    vim.notify("greplace: " .. err, vim.log.levels.ERROR)
                    return
                end
                if not matches or #matches == 0 then
                    vim.notify("greplace: no matches for " .. query, vim.log.levels.WARN)
                    return
                end
                panel.open(matches, {
                    query    = query,
                    regex    = opts.regex,
                    root     = root,
                    height   = M.config.height,
                    on_write = on_write,
                })
            end)
        end)
end

--- Re-run the query the panel was opened with, discarding unapplied edits.
function M.refresh()
    local bufnr = panel.find_buf()
    local state = bufnr and panel.state(bufnr)
    if not state then
        vim.notify("greplace: no active search", vim.log.levels.WARN)
        return
    end
    M.open(state.query, { regex = state.regex, cwd = state.root })
end

---@param opts greplace.Config?
function M.setup(opts)
    M.config = vim.tbl_extend("force", M.config, opts or {})
    panel.setup_highlights()
end

return M
