local M = {}

-- ---------------------------------------------------------------------------
-- greplace
--
-- `:Gsearch <query>` greps the working tree and collects every matching line
-- into a `greplace://replace` split. The lines are plain, editable text (the
-- `file:line` prefix is virtual), and writing the buffer pushes each edited
-- line back to its source — in buffers, never to disk.
--
--   Gsearch[!] <query>   grep for <query> (`!` treats it as a regex)
--   Gsearch              with no query: re-run the last one, discarding
--                        unapplied edits
--
-- This module owns the command body, as `M.run`, plus the API it is a thin
-- skin over (`M.open`, `M.refresh`); the command itself is registered in
-- `plugin/greplace.lua`, and the work lives in `greplace.search` /
-- `greplace.panel` / `greplace.apply`.
-- ---------------------------------------------------------------------------

local config = require("greplace.config")
local panel  = require("greplace.panel")
local search = require("greplace.search")

--- The search currently in flight, if any. Only one runs at a time: they all
--- render into the same panel buffer, so a second search starting means the
--- first one's results are already obsolete. Starting one cancels it, and so
--- does wiping the panel out from under it -- both leave no callback to land
--- late over the newer state.
---@type fun()?
local _cancel = nil

--- Cancel the in-flight search, if there is one.
local function abort()
    if _cancel then
        local cancel = _cancel
        _cancel = nil
        cancel()
    end
end

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("greplace: " .. msg, level or vim.log.levels.INFO)
end

---@param bufnr integer
local function on_write(bufnr)
    local apply  = require("greplace.apply")
    local result = apply.run(panel.regions(bufnr))

    panel.refresh(bufnr, result.entries)

    local msg   = string.format("%d line(s) in %d buffer(s), unsaved",
        result.replaced, result.files)
    local level = vim.log.levels.INFO
    if result.removed > 0 then
        msg = msg .. string.format("; %d left alone (removed from the list)", result.removed)
    end
    if result.skipped > 0 then
        msg   = msg .. string.format("; %d skipped (source line moved)", result.skipped)
        level = vim.log.levels.WARN
    end
    _notify(msg, level)
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
    -- The panel goes up before the search does, so the results appear in a
    -- window that is already open and settled rather than one that springs up
    -- under the cursor whenever rg happens to finish. Until then it says it
    -- is searching.
    local args = {
        query    = query,
        regex    = opts.regex,
        root     = root,
        height   = config.options.height,
        on_write = on_write,
    }
    -- Whatever was still running was searching for the previous query into
    -- this same buffer; drop it before the panel is retitled.
    abort()
    local bufnr = panel.open_loading(args)

    -- Wiping the panel ends the search that was filling it. The augroup is
    -- cleared per search, so the buffer never accumulates one autocommand per
    -- `:Gsearch` (it is reused across them).
    vim.api.nvim_create_autocmd("BufWipeout", {
        group    = vim.api.nvim_create_augroup("greplace.search", { clear = true }),
        buffer   = bufnr,
        desc     = "greplace: cancel the search filling the panel",
        callback = abort,
    })

    _cancel = search.run(query, { cwd = root, regex = opts.regex, limit = config.options.limit },
        function(matches, err, truncated)
            _cancel = nil
            vim.schedule(function()
                -- The panel can have been closed while the search ran.
                local live = vim.api.nvim_buf_is_valid(bufnr) and panel.is_panel(bufnr)
                if err then
                    if live then panel.set_message(bufnr, err, "ErrorMsg") end
                    _notify(err, vim.log.levels.ERROR)
                    return
                end
                if not matches or #matches == 0 then
                    if live then panel.set_message(bufnr, "no matches for " .. query) end
                    _notify("no matches for " .. query, vim.log.levels.WARN)
                    return
                end
                if not live then return end
                args.truncated = truncated
                panel.open(matches, args)
            end)
        end)
end

--- Re-run the query the panel was opened with, discarding unapplied edits.
function M.refresh()
    local bufnr = panel.find_buf()
    local state = bufnr and panel.state(bufnr)
    if not state then
        _notify("no active search", vim.log.levels.WARN)
        return
    end
    M.open(state.query, { regex = state.regex, cwd = state.root })
end

--- `:Gsearch`'s implementation, as a `greplace.usercmd.run_fn` body. Exposed
--- so that `plugin/greplace.lua` can register the command without this module
--- being loaded: it hands `util/usercmd` a wrapper that requires us on the
--- first invocation.
---
--- The query is the command line verbatim rather than a parsed argument list:
--- a grep query is one string, and its spaces, quotes and backslashes all
--- belong to it. With no query at all, re-run the last one.
---@param _cmd string
---@param opts vim.api.keyset.create_user_command.command_args
function M.run(_cmd, opts)
    local query = vim.trim(opts.args)
    if query == "" then
        M.refresh()
    else
        M.open(query, { regex = opts.bang })
    end
end

---@param opts greplace.Config?
function M.setup(opts)
    config.setup(opts)
    panel.setup_highlights()
end

return M
