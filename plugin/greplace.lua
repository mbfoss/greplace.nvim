if vim.fn.has("nvim-0.11") ~= 1 then
    error("greplace.nvim requires Neovim >= 0.11")
end

-- The two commands are registered here at startup without requiring any Lua:
-- the callbacks pull in what they need on first use. `util/usercmd` is the
-- command plumbing -- it reports an error from a command body as a
-- notification rather than a stack trace -- and `greplace` is the plugin
-- proper, the search, the panel and the write-back. Neither is read until a
-- command is first run. Both modules are cached in a local on first use, so a
-- callback pays for a `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local greplace ---@type table?

-- `:Gsearch` is the one that searches: a query taken literally, or -- when the
-- line opens with `--` -- a flag line, `--glob *.lua --hidden -- query`.
vim.api.nvim_create_user_command("Gsearch", function(opts)
    usercmd = usercmd or require("greplace.util.usercmd")
    usercmd.handle(opts, function(cmd, args, cmd_opts)
        greplace = greplace or require("greplace")
        return greplace.run_search(cmd, args, cmd_opts)
    end)
end, {
    desc     = "Grep the working tree into an editable buffer (--flags -- query)",
    -- `nargs = "*"` rather than `"?"`: a query is one string that may well
    -- contain spaces, and it is rejoined from the words Vim split off.
    nargs    = "*",
    -- Only a flag line completes, and only its flag section: a query is not a
    -- list of anything, and past a bare `--` neither is the rest of the line.
    complete = function(arglead, cmdline, cursor)
        return require("greplace.rgflags").complete(arglead, cmdline, cursor)
    end,
})

-- `:Greplace` is what to do with the panel the search filled: put it back on
-- screen, take it off again, or fill it from the quickfix list instead --
-- `:grep`, `:vimgrep`, an LSP's references, anything that fills that list.
vim.api.nvim_create_user_command("Greplace", function(opts)
    usercmd = usercmd or require("greplace.util.usercmd")
    usercmd.handle(opts, function(cmd, args, cmd_opts)
        greplace = greplace or require("greplace")
        return greplace.run(cmd, args, cmd_opts)
    end)
end, {
    desc     = "The greplace panel: open, toggle, or fill from the quickfix list",
    -- `nargs = "*"` rather than `"?"`: a second word is reported by the body
    -- as the error it is, rather than by Neovim as a bare "Too many arguments".
    nargs    = "*",
    complete = function(arglead, cmdline, cursor)
        usercmd = usercmd or require("greplace.util.usercmd")
        return usercmd.complete(arglead, cmdline:sub(1, cursor), function(_, rest)
            -- One subcommand and no arguments: nothing to offer behind it.
            if #rest > 0 then return {} end
            greplace = greplace or require("greplace")
            return greplace.SUBCOMMANDS
        end)
    end,
})
