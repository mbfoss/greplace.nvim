local M = {}

-- ---------------------------------------------------------------------------
-- greplace
--
-- `:Gsearch <query>` greps the working tree and collects every matching line
-- into a `greplace://replace` split. The lines are plain, editable text (the
-- `file:line` prefix is virtual), and writing the buffer pushes each edited
-- line back to its source — in buffers, never to disk.
--
--   Gsearch <query>           grep for <query>, literally
--   Gsearch <flags> -- <q>    the same search with `greplace.rgflags`'s flags
--                             (`--filter *.lua --hidden -- <q>`): a narrowed
--                             file set, a regex, a case rule. A line starting
--                             with `--` is a flag line, so a query that starts
--                             with one is written after a bare `--`
--   Gsearch                   with nothing at all: cancel the search in flight
--
--   Greplace [open]           put the panel back on screen
--   Greplace close            take it off again, keeping the list in it
--   Greplace toggle           one or the other, whichever it is not
--   Greplace qf               fill the panel from the quickfix list, whatever
--                             filled that, instead of from a search
--
-- The split is deliberate: `:Gsearch` is the one that produces a list, and
-- `:Greplace` is what you do with the panel afterwards, so the panel's own
-- verbs never have to compete with a query for the same argument.
--
-- This module owns both command bodies, as `M.run_search` and `M.run`, plus
-- the API they are a thin skin over (`M.open`, `M.open_qf`, `M.show`,
-- `M.toggle`, `M.cancel`, `M.refresh`); the commands themselves are registered
-- in `plugin/greplace.lua`, and the work lives in `greplace.rgflags` /
-- `greplace.search` / `greplace.qflist` / `greplace.panel` / `greplace.apply`.
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
---@field flags table?    `:Gsearch` flags (see `greplace.rgflags`)

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
    -- `:Gsearch` (it is reused across them).
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

--- Open the panel on the current quickfix list: every entry's line, read from
--- the file it names, editable and written back exactly as a search's results
--- are. Whatever filled the list -- `:grep`, `:vimgrep`, an LSP, a test runner
--- -- is beside the point; only the file and line of each entry are used.
function M.open_qf()
    local root             = search.resolve_root(nil)
    local matches, dropped = require("greplace.qflist").matches(root)

    if #matches == 0 then
        _notify("no editable lines in the quickfix list", vim.log.levels.WARN)
        return
    end

    -- A search still filling this same panel would land on top of the list.
    abort()
    panel.open(matches, {
        query    = "quickfix list",
        source   = "quickfix",
        root     = root,
        height   = config.options.height,
        on_write = on_write,
    })

    if dropped > 0 then
        _notify(("%d quickfix entr%s skipped (no file, or line not readable)")
            :format(dropped, dropped == 1 and "y" or "ies"), vim.log.levels.WARN)
    end
end

--- Put the panel back on screen, with whatever list and unapplied edits it
--- was holding when it was last taken off. There is nothing to show until a
--- search or a quickfix list has filled it once.
---@return integer? bufnr  nil when there is no panel to show
function M.show()
    local bufnr = panel.find_buf()
    if not bufnr then
        _notify("no list yet: search with :Gsearch <query>", vim.log.levels.WARN)
        return
    end
    panel.show(bufnr, config.options.height)
    return bufnr
end

--- Take the panel off screen, keeping the buffer -- so the list and any edits
--- in it are still there next time it is shown. Silent when it was not on
--- screen to begin with: that is the state that was asked for either way.
function M.hide()
    local bufnr = panel.find_buf()
    if bufnr then panel.close(bufnr) end
end

--- Show the panel, or hide it when it is already on screen.
function M.toggle()
    local bufnr = panel.find_buf()
    if bufnr and panel.close(bufnr) then return end
    M.show()
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

--- Rebuild the panel from what it was opened on, discarding unapplied edits:
--- the query for a search, the quickfix list as it now stands for one filled
--- by `:Greplace qf`. No command runs this -- it is for a mapping that
--- wants the list brought up to date with the files underneath it.
function M.refresh()
    local bufnr = panel.find_buf()
    local state = bufnr and panel.state(bufnr)
    if not state then
        _notify("no active search", vim.log.levels.WARN)
        return
    end
    if state.source == "quickfix" then
        M.open_qf()
    else
        M.open(state.query, { cwd = state.root, flags = state.flags })
    end
end

--- `:Gsearch`'s implementation, as a `greplace.usercmd.run_fn` body. Exposed
--- so that `plugin/greplace.lua` can register the command without this module
--- being loaded: it hands `util/usercmd` a wrapper that requires us on the
--- first invocation.
---
--- A line that opens with `--` is a flag line, read by `greplace.rgflags`;
--- anything else is the query itself, taken literally. Either way the words
--- are Neovim's split of the line, joined back with the single space that
--- separated them, so `:h <f-args>` is the rule throughout: a space that
--- belongs to the query is written `\ `, `\\` is a backslash, and every other
--- backslash -- `\d`, `\s` -- reaches rg as written.
---
--- With no words at all -- not with a blank query, which `:Gsearch \ ` is a
--- legitimate way to write -- cancel the search in flight.
---@param _cmd string
---@param fargs string[]  the argument line, as Neovim split it
---@param _opts vim.api.keyset.create_user_command.command_args
function M.run_search(_cmd, fargs, _opts)
    if #fargs == 0 then
        M.cancel()
        return
    end

    if not vim.startswith(fargs[1], "--") then
        M.open(table.concat(fargs, " "))
        return
    end

    local parsed, err = require("greplace.rgflags").parse(fargs)
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

--- The subcommands of `:Greplace`, in the order they are offered.
---@type string[]
M.SUBCOMMANDS = { "open", "close", "toggle", "qf" }

--- `:Greplace`'s implementation: what to do with the panel, `open` by default.
--- It never searches, so it needs no query and takes none.
---@param _cmd string
---@param fargs string[]  the argument line, as Neovim split it
---@param _opts vim.api.keyset.create_user_command.command_args
function M.run(_cmd, fargs, _opts)
    local sub = fargs[1] or "open"
    if #fargs > 1 then
        _notify(("%s takes no argument"):format(sub), vim.log.levels.ERROR)
    elseif sub == "open" then
        M.show()
    elseif sub == "close" then
        M.hide()
    elseif sub == "toggle" then
        M.toggle()
    elseif sub == "qf" then
        M.open_qf()
    else
        _notify(("unknown subcommand: %s (%s)")
            :format(sub, table.concat(M.SUBCOMMANDS, ", ")), vim.log.levels.ERROR)
    end
end

---@param opts greplace.Config?
function M.setup(opts)
    config.setup(opts)
    panel.setup_highlights()
end

return M
