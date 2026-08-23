local M = {}

-- ---------------------------------------------------------------------------
-- greplace
--
-- `:Greplace search <query>` greps the working tree and collects every
-- matching line into a `greplace://replace` split. The lines are plain,
-- editable text (the `file:line` prefix is virtual), and writing the buffer
-- pushes each edited line back to its source — in buffers, never to disk.
--
--   Greplace search[!] <query>   grep for <query> (`!` treats it as a regex)
--   Greplace refresh             re-run the last query, discarding unapplied
--                                edits
--
-- This module owns argument parsing and completion, as `M.run` and
-- `M.complete`, plus the API the command is a thin skin over (`M.open`,
-- `M.refresh`); the command itself is registered in `plugin/greplace.lua`, and
-- the work lives in `greplace.search` / `greplace.panel` / `greplace.apply`.
-- ---------------------------------------------------------------------------

local config = require("greplace.config")
local panel  = require("greplace.panel")
local search = require("greplace.search")

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

    search.run(query, { cwd = root, regex = opts.regex, limit = config.options.limit },
        function(matches, err)
            vim.schedule(function()
                if err then
                    _notify(err, vim.log.levels.ERROR)
                    return
                end
                if not matches or #matches == 0 then
                    _notify("no matches for " .. query, vim.log.levels.WARN)
                    return
                end
                panel.open(matches, {
                    query    = query,
                    regex    = opts.regex,
                    root     = root,
                    height   = config.options.height,
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
        _notify("no active search", vim.log.levels.WARN)
        return
    end
    M.open(state.query, { regex = state.regex, cwd = state.root })
end

--- Everything after the subcommand, taken from the raw command line rather
--- than from the split arguments: a grep query is one string, and its spaces,
--- quotes and backslashes all belong to it.
---@param raw string  `opts.args`, the command line after `:Greplace`
---@return string
local function _tail(raw)
    return vim.trim(raw:gsub("^%s*%S+", "", 1))
end

--- `:Greplace`'s implementation, as a `greplace.usercmd.run_fn`. Exposed so
--- that `plugin/greplace.lua` can register the command without this module
--- being loaded: it hands `util/usercmd` a wrapper that requires us on the
--- first invocation.
---@type greplace.usercmd.run_fn
function M.run(_, args, opts)
    local sub = args[1]
    if sub == "search" then
        local query = _tail(opts.args)
        if query == "" then
            _notify("Greplace search takes a query", vim.log.levels.ERROR)
            return
        end
        M.open(query, { regex = opts.bang })
    elseif sub == "refresh" then
        if args[2] then
            _notify("Greplace refresh takes no arguments", vim.log.levels.ERROR)
            return
        end
        M.refresh()
    elseif sub == nil then
        vim.api.nvim_echo({ { "Argument required", "Error" } }, false, {})
    else
        _notify("unknown subcommand: " .. sub, vim.log.levels.ERROR)
    end
end

--- `:Greplace`'s completion, as a `greplace.usercmd.subcommand_fn`. Exposed
--- for the same reason as `M.run`.
---@type greplace.usercmd.subcommand_fn
function M.complete(_, rest, _)
    if #rest == 0 then return { "search", "refresh" } end
    -- Neither subcommand takes anything completable: `search`'s tail is a
    -- free-text query, and `refresh` takes nothing at all.
    return {}
end

---@param opts greplace.Config?
function M.setup(opts)
    config.setup(opts)
    panel.setup_highlights()
end

return M
