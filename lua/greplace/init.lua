local M = {}

-- ---------------------------------------------------------------------------
-- greplace
--
-- `:Gsearch <query>` greps the working tree and collects every matching line
-- into a `greplace://greplace-matches` split. The lines are plain, editable
-- text (the `file:line` prefix is virtual), and writing the buffer pushes each
-- edited line back to its source, in buffers, never to disk.
--
--   Gsearch <query>           grep for <query>, literally
--   Gsearch <flags> -- <q>    the same search under flags (`--glob *.lua -- <q>`);
--                             after the bare `--`, `<q>` is raw
--   Gsearch                   with nothing at all: cancel the search in flight
--   '<,'>Gsearch [<flags>]    search for the visual selection (or the line
--                             in the range), literally, under any flags given
--
--   Greplace [open]           put the panel back on screen
--   Greplace close            take it off again, keeping the list in it
--   Greplace toggle           one or the other, whichever it is not
--   Greplace qf               fill the panel from the quickfix list, whatever
--                             filled that, instead of from a search
--   Greplace[!] refresh       run the list's search (or quickfix import)
--                             again; `!` discards unapplied edits
--   Greplace diff             preview, as a diff, what writing the panel would
--                             change
--   Greplace apply            apply the panel's edits, from any window; the
--                             panel's `:w` does the same
--
-- The split is deliberate: `:Gsearch` is the one that produces a list, and
-- `:Greplace` is what you do with the panel afterwards, so the panel's own
-- verbs never have to compete with a query for the same argument.
--
-- This module owns both command bodies, as `M.run_search` and `M.run`, plus
-- the API they are a thin skin over (`M.open`, `M.open_qf`, `M.show`,
-- `M.toggle`, `M.cancel`, `M.refresh`, `M.diff`, `M.apply`); the commands
-- themselves are registered in `plugin/greplace.lua`, and the work is done in
-- `greplace.rgflags` / `greplace.search` / `greplace.qflist` / `greplace.panel`
-- / `greplace.apply` / `greplace.preview`.
-- ---------------------------------------------------------------------------

local config = require("greplace.config").current
local panel  = require("greplace.panel")
local search = require("greplace.search")

--- The search in flight, if any. All searches render into one panel buffer, so
--- starting one (or wiping the panel) cancels the last rather than race it.
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

--- Apply the panel's edits to their source buffers and redraw from what landed;
--- this is `:Greplace apply` and the panel's `:w`. A panel with no list yet has
--- nothing to apply, so its status stands rather than redrawing as empty.
---@param bufnr integer
local function apply_edits(bufnr)
    if not panel.has_list(bufnr) then
        vim.bo[bufnr].modified = false
        _notify("no list to apply", vim.log.levels.WARN)
        return
    end

    local apply  = require("greplace.apply")
    local regions = panel.regions(bufnr)
    local result  = apply.run(regions)

    -- A preview shows the edits as they were before this; it is out of date
    -- now. Only looked up if one was ever opened.
    local preview = package.loaded["greplace.preview"]
    if preview then preview.close() end

    -- Redrawn in place rather than rebuilt, so that `u` still walks back over
    -- the write and writing again reverts it.
    panel.settle(bufnr, regions)

    local msg
    if result.replaced > 0 then
        msg = string.format("%d line(s) changed in %d buffer(s)", result.replaced, result.files)
    elseif result.skipped > 0 then
        msg = "no changes applied"
    else
        msg = "no changes to apply"
    end
    local level = vim.log.levels.INFO
    if result.skipped > 0 then
        msg   = msg .. string.format("; %d skipped (source changed)", result.skipped)
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
    local root  = search.resolve_root(opts.cwd)
    -- Copied because the search keeps these in a closure while it runs.
    local flags = opts.flags and vim.deepcopy(opts.flags)
    -- The panel goes up before the search, so results land in a settled window;
    -- until then it says it is searching.
    local args = {
        query    = query,
        flags    = flags,
        root     = root,
        ratio    = config.height_ratio,
        on_write  = apply_edits,
        -- Deleting the panel ends the search that was filling it.
        on_delete = abort,
    }
    -- Whatever was still running was searching for the previous query into
    -- this same buffer; drop it before the panel is retitled.
    abort()
    local bufnr = panel.open_loading(args)

    _cancel = search.run(query, {
            cwd   = root,
            flags = flags,
            limit = config.limit,
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
                local _, render_err = panel.open(matches, args)
                if render_err then
                    _notify(render_err, vim.log.levels.ERROR)
                end
            end)
        end)
end

--- Open the panel on the current quickfix list, each entry's line read from its
--- file and editable as a search's results are. Only file and line are used.
function M.open_qf()
    local root             = search.resolve_root(nil)
    local matches, dropped = require("greplace.qflist").matches(root)

    if #matches == 0 then
        _notify("no editable lines in the quickfix list", vim.log.levels.WARN)
        return
    end

    -- A search still filling this same panel would land on top of the list.
    abort()
    local _, render_err = panel.open(matches, {
        query    = "quickfix list",
        source   = "quickfix",
        root     = root,
        ratio    = config.height_ratio,
        on_write  = apply_edits,
        on_delete = abort,
    })
    if render_err then
        _notify(render_err, vim.log.levels.ERROR)
        return
    end

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
    panel.show(bufnr, config.height_ratio)
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

--- Stop the search in flight and leave the panel saying so. Nothing is re-run;
--- stopping is how a too-broad search makes room for a narrower one.
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

--- Rebuild the panel from what it was opened on (the query, or the current
--- quickfix list). A panel holding unapplied edits is left alone unless `force`
--- says to discard them.
---@param opts { force: boolean? }?
function M.refresh(opts)
    local bufnr = panel.find_buf()
    local origin = bufnr and panel.origin(bufnr)
    if not bufnr or not origin then
        _notify("no list yet: search with :Gsearch <query>", vim.log.levels.WARN)
        return
    end
    if vim.bo[bufnr].modified and not (opts and opts.force) then
        _notify("the list has unapplied edits: write them with :w, "
            .. "or discard them with :Greplace! refresh", vim.log.levels.WARN)
        return
    end
    if origin.source == "quickfix" then
        M.open_qf()
    else
        M.open(origin.query, { cwd = origin.root, flags = origin.flags })
    end
end

--- Show, as a diff, what writing the panel would change -- without changing
--- anything, so the edits can be checked before they reach any buffer.
---@return integer? bufnr  the preview's buffer; nil when there is nothing to show
function M.diff()
    local bufnr = panel.find_buf()
    if not bufnr or not panel.is_panel(bufnr) then
        _notify("no list yet: search with :Gsearch <query>", vim.log.levels.WARN)
        return
    end
    local preview = require("greplace.apply").preview(panel.regions(bufnr))
    return require("greplace.preview").open(preview)
end

--- Apply the panel's edits, as `:w` in the panel does, from any window: from
--- the `:Greplace diff` preview once it looks right, or with the panel closed.
function M.apply()
    local bufnr = panel.find_buf()
    if not bufnr or not panel.is_panel(bufnr) then
        _notify("no list yet: search with :Gsearch <query>", vim.log.levels.WARN)
        return
    end
    apply_edits(bufnr)
end

--- The query a ranged `:Gsearch` searches for: the last selection when the
--- range covers it, else its line trimmed. Always one line, since rg matches
--- line by line and text spanning a break could never match.
---@param opts vim.api.keyset.create_user_command.command_args
---@return string? query
---@return string? err
local function range_query(opts)
    if opts.line1 ~= opts.line2 then
        return nil, "the range spans several lines; a search is for text on one line"
    end
    local mode   = vim.fn.visualmode()
    local vstart = vim.fn.getpos("'<")
    local vend   = vim.fn.getpos("'>")
    local text
    if (mode == "v" or mode == "\22")
        and vstart[2] == opts.line1 and vend[2] == opts.line2 then
        text = table.concat(vim.fn.getregion(vstart, vend, { type = mode }), "\n")
    else
        text = vim.trim(vim.fn.getline(opts.line1))
    end
    if text == "" then
        return nil, "nothing to search for: the line is blank"
    end
    return text
end

--- Run one `:Gsearch` argument line, query or flags and query alike.
---@param raw string  the line as typed, after the command name
local function open_args(raw)
    local parsed, err = require("greplace.rgflags").parse(raw)
    if not parsed then
        _notify(assert(err), vim.log.levels.ERROR)
        return
    end
    -- `dir` is the flag language's spelling of the search root.
    M.open(parsed.query, {
        flags = next(parsed.flags) and parsed.flags or nil,
        cwd   = parsed.flags.dir and vim.fn.expand(parsed.flags.dir) or nil,
    })
end

--- `:Gsearch`'s implementation, exposed so `plugin/greplace.lua` can register
--- it without loading this module. A range makes the selection the query;
--- otherwise `rgflags` reads the arguments, and no words at all cancels.
---@param _cmd string
---@param fargs string[]  the argument line, as Neovim split it
---@param opts vim.api.keyset.create_user_command.command_args
function M.run_search(_cmd, fargs, opts)
    if opts.range and opts.range > 0 then
        local query, err = range_query(opts)
        if not query then
            _notify(assert(err), vim.log.levels.ERROR)
            return
        end
        local flags = vim.list_slice(fargs)
        if flags[#flags] == "--" then flags[#flags] = nil end
        if #flags == 0 then
            M.open(query)
            return
        end
        local rgflags = require("greplace.rgflags")
        if not rgflags.is_flag_token(flags[1]) or vim.tbl_contains(flags, "--") then
            _notify("with a range the selection is the query: give flags only",
                vim.log.levels.ERROR)
            return
        end
        local parsed, flag_err = rgflags.parse_flags(flags)
        if not parsed then
            _notify(assert(flag_err), vim.log.levels.ERROR)
            return
        end
        M.open(query, {
            flags = next(parsed) and parsed or nil,
            cwd   = parsed.dir and vim.fn.expand(parsed.dir) or nil,
        })
        return
    end

    if #fargs == 0 then
        M.cancel()
        return
    end

    open_args(opts.args or "")
end

--- The subcommands of `:Greplace`, in the order they are offered.
---@type string[]
M.SUBCOMMANDS = { "open", "close", "toggle", "qf", "refresh", "diff", "apply" }

--- `:Greplace`'s implementation: what to do with the panel, `open` by default.
--- The bang belongs to `refresh` alone and discards its unapplied edits.
---@param _cmd string
---@param fargs string[]  the argument line, as Neovim split it
---@param opts vim.api.keyset.create_user_command.command_args
function M.run(_cmd, fargs, opts)
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
    elseif sub == "refresh" then
        M.refresh({ force = opts.bang })
    elseif sub == "diff" then
        M.diff()
    elseif sub == "apply" then
        M.apply()
    else
        _notify(("unknown subcommand: %s (%s)")
            :format(sub, table.concat(M.SUBCOMMANDS, ", ")), vim.log.levels.ERROR)
    end
end

---@param opts greplace.Config?
function M.setup(opts)
    require("greplace.config").setup(opts)
    panel.setup_highlights()
end

return M
