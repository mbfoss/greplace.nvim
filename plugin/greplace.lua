if vim.fn.has("nvim-0.11") ~= 1 then
    error("greplace.nvim requires Neovim >= 0.11")
end

require("greplace.panel").setup_highlights()

vim.api.nvim_create_user_command("Gsearch", function(cmd_opts)
    -- `args` rather than `fargs`: the whole tail is one query, spaces and
    -- backslashes included.
    local query = vim.trim(cmd_opts.args)
    if query == "" then
        require("greplace").refresh()
        return
    end
    require("greplace").open(query, { regex = cmd_opts.bang })
end, {
    nargs = "*",
    bang  = true,
    desc  = "Grep the working tree into an editable buffer (! for regex)",
})
