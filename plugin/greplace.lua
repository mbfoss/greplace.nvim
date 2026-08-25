if vim.fn.has("nvim-0.11") ~= 1 then
    error("greplace.nvim requires Neovim >= 0.11")
end

-- `:Gsearch` is registered here at startup without requiring any Lua: the
-- callback pulls in what it needs on first use. `util/usercmd` is the command
-- plumbing -- it reports an error from the command body as a notification
-- rather than a stack trace -- and `greplace` is the plugin proper, the search,
-- the panel and the write-back. Neither is read until the command is first run.
-- Both modules are cached in a local on first use, so the callback pays for a
-- `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local greplace ---@type table?

vim.api.nvim_create_user_command("Gsearch", function(opts)
    usercmd = usercmd or require("greplace.util.usercmd")
    usercmd.handle(opts, function(cmd, _, cmd_opts)
        greplace = greplace or require("greplace")
        return greplace.run(cmd, cmd_opts)
    end)
end, {
    desc     = "Grep the working tree into an editable buffer (! for regex)",
    -- `nargs = "*"` rather than `"?"`: a query is one string that may well
    -- contain spaces, and it is read whole off `opts.args`.
    nargs    = "*",
    bang     = true,
    complete = function() return {} end,
})
