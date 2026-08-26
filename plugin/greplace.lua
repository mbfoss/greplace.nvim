if vim.fn.has("nvim-0.11") ~= 1 then
    error("greplace.nvim requires Neovim >= 0.11")
end

-- `:Greplace` is registered here at startup without requiring any Lua: the
-- callback pulls in what it needs on first use. `util/usercmd` is the command
-- plumbing -- it reports an error from the command body as a notification
-- rather than a stack trace -- and `greplace` is the plugin proper, the search,
-- the panel and the write-back. Neither is read until the command is first run.
-- Both modules are cached in a local on first use, so the callback pays for a
-- `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local greplace ---@type table?

vim.api.nvim_create_user_command("Greplace", function(opts)
    usercmd = usercmd or require("greplace.util.usercmd")
    usercmd.handle(opts, function(cmd, args, cmd_opts)
        greplace = greplace or require("greplace")
        return greplace.run(cmd, args, cmd_opts)
    end)
end, {
    desc     = "Grep the working tree into an editable buffer",
    -- `nargs = "*"` rather than `"?"`: a query is one string that may well
    -- contain spaces, and it is rejoined from the words Vim split off.
    nargs    = "*",
    complete = function() return {} end,
})

-- `:GreplaceEx` is the same search with the file set and the match rules
-- opened up: `--filter *.lua --hidden -- query`. Flags first, then a bare
-- `--`, then the query. The whole line is split by Vim's own rules, the same
-- ones `:Greplace` reads its query by; the separator is what keeps a query's
-- own leading dashes, quotes and further `--`s out of the flag parser.
vim.api.nvim_create_user_command("GreplaceEx", function(opts)
    usercmd = usercmd or require("greplace.util.usercmd")
    usercmd.handle(opts, function(cmd, args, cmd_opts)
        greplace = greplace or require("greplace")
        return greplace.run_ex(cmd, args, cmd_opts)
    end)
end, {
    desc     = "Grep with ripgrep flags into an editable buffer (--flags -- query)",
    nargs    = "*",
    -- Only the flag section completes; past the bare `--` the words are a query.
    complete = function(arglead, cmdline, cursor)
        return require("greplace.rgflags").complete(arglead, cmdline, cursor)
    end,
})
