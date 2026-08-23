if vim.fn.has("nvim-0.11") ~= 1 then
    error("greplace.nvim requires Neovim >= 0.11")
end

-- `:Greplace` is registered here at startup without requiring any Lua: both
-- callbacks pull in what they need on first use. `util/usercmd` is the command
-- plumbing -- it splits the arguments and drives completion, and knows nothing
-- about what the subcommands do -- and `greplace` is the plugin proper, the
-- search, the panel and the write-back. Neither is read until the command is
-- first run or completed.
-- Both modules are cached in a local on first use, so the callbacks pay for a
-- `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local greplace ---@type table?

---@return table
local function _usercmd()
    usercmd = usercmd or require("greplace.util.usercmd")
    return usercmd
end

---@return table
local function _greplace()
    greplace = greplace or require("greplace")
    return greplace
end

vim.api.nvim_create_user_command("Greplace", function(opts)
    _usercmd().handle(opts, function(cmd, args, cmd_opts)
        return _greplace().run(cmd, args, cmd_opts)
    end)
end, {
    nargs = "*",
    bang  = true,
    desc  = "Grep the working tree into an editable buffer (! for regex)",
    complete = function(arg_lead, cmd_line, _)
        return _usercmd().complete(arg_lead, cmd_line,
            function(cmd, rest, lead)
                return _greplace().complete(cmd, rest, lead)
            end)
    end,
})
