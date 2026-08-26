local M = {}

-- ---------------------------------------------------------------------------
-- greplace
--
-- `:Greplace <query>` greps the working tree and collects every matching line
-- into a `greplace://replace` split. The lines are plain, editable text (the
-- `file:line` prefix is virtual), and writing the buffer pushes each edited
-- line back to its source — in buffers, never to disk.
--
--   Greplace <query>          grep for <query>, literally
--   Greplace                  with no query: cancel the search in flight
--   GreplaceEx <flags> -- <q> the same search with `greplace.rgflags`'s flags
--                             (`--filter *.lua --hidden -- <q>`): a narrowed
--                             file set, a regex, a case rule
--
-- This module owns both command bodies, as `M.run` and `M.run_ex`, plus the
-- API they are a thin skin over (`M.open`, `M.cancel`, `M.refresh`); the commands
-- themselves are registered in `plugin/greplace.lua`, and the work lives in
-- `greplace.rgflags` / `greplace.search` /
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
---@field cwd   string?   search root (default: current directory)
---@field flags table?    `:GreplaceEx` flags (see `greplace.rgflags`)

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
        flags    = opts.flags,
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
    -- `:Greplace` (it is reused across them).
    vim.api.nvim_create_autocmd("BufWipeout", {
        group    = vim.api.nvim_create_augroup("greplace.search", { clear = true }),
        buffer   = bufnr,
        desc     = "greplace: cancel the search filling the panel",
        callback = abort,
    })

    _cancel = search.run(query, {
            cwd   = root,
            flags = opts.flags,
            limit = config.options.limit,
        },
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

--- Stop the search in flight, leaving the panel showing that it was stopped
--- rather than the query it will never finish. Nothing is re-run: a search
--- that is taking too long is stopped so that a narrower one can be typed.
function M.cancel()
    if not _cancel then
        _notify("no search running", vim.log.levels.WARN)
        return
    end
    abort()

    local bufnr = panel.find_buf()
    if bufnr and panel.is_panel(bufnr) then
        panel.set_message(bufnr, "search cancelled", "GreplaceLimit")
    end
    _notify("search cancelled")
end

--- Re-run the query the panel was opened with, discarding unapplied edits.
--- Not what a bare `:Greplace` does -- that cancels; this is for a mapping
--- that wants the list brought up to date with the files underneath it.
function M.refresh()
    local bufnr = panel.find_buf()
    local state = bufnr and panel.state(bufnr)
    if not state then
        _notify("no active search", vim.log.levels.WARN)
        return
    end
    M.open(state.query, { cwd = state.root, flags = state.flags })
end

--- `:Greplace`'s implementation, as a `greplace.usercmd.run_fn` body. Exposed
--- so that `plugin/greplace.lua` can register the command without this module
--- being loaded: it hands `util/usercmd` a wrapper that requires us on the
--- first invocation.
---
--- The query is one string, so the words Neovim split off the command line are
--- joined back into one with the single space that separated them. That makes
--- `:h <f-args>` the rule for the query too: a space that belongs to the query
--- is written `\ `, `\\` is a backslash, and every other backslash -- `\d`,
--- `\s` -- reaches rg as written. With no words at all -- not with a blank
--- query, which `:Greplace \ ` is a legitimate way to write -- cancel the
--- search in flight.
---@param _cmd string
---@param fargs string[]  the argument line, as Neovim split it
---@param _opts vim.api.keyset.create_user_command.command_args
function M.run(_cmd, fargs, _opts)
    if #fargs == 0 then
        M.cancel()
    else
        M.open(table.concat(fargs, " "))
    end
end

--- `:GreplaceEx`'s implementation: the flags of `greplace.rgflags`, then a bare
--- `--`, then the query. Same search and same panel as `:Greplace`; only the
--- file set and the match rules are opened up. Unlike `:Greplace`, which takes
--- its query as the untouched command line, this one reads the whole line from
--- Neovim's split, so a space anywhere in it -- in a flag value or in the
--- query -- is written `\ ` (`:h <f-args>`).
---@param _cmd string
---@param fargs string[]  the argument line, as Neovim split it
---@param _opts vim.api.keyset.create_user_command.command_args
function M.run_ex(_cmd, fargs, _opts)
    if #fargs == 0 then
        M.cancel()
        return
    end

    local rgflags = require("greplace.rgflags")
    local parsed, err = rgflags.parse(fargs)
    if not parsed then
        _notify(assert(err), vim.log.levels.ERROR)
        return
    end
    -- `dir` is the flag language's spelling of the search root.
    M.open(parsed.query, {
        flags = parsed.flags,
        cwd   = parsed.flags.dir and vim.fn.expand(parsed.flags.dir) or nil,
    })
end

---@param opts greplace.Config?
function M.setup(opts)
    config.setup(opts)
    panel.setup_highlights()
end

return M
