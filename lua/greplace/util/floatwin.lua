local uiutil = require "keystone.util.ui"
---@class keystone.util.floatwin
---@field _complete_cache? string[]
---@field _complete_buf? integer
local M = {}

---@class keystone.util.floatwin.FloatwinOpts
---@field title? string
---@field is_markdown boolean?

---@param text string
---@param opts keystone.util.floatwin.FloatwinOpts?
function M.open(text, opts)
    opts = opts or {}
    local lines = vim.split(text, "\n", { trimempty = false })
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines
    local max_w = math.floor(ui_width * 0.8)
    local max_h = math.floor(ui_height * 0.8)
    local content_w = 30
    for _, line in ipairs(lines) do
        content_w = math.max(content_w, vim.fn.strwidth(line))
    end

    local win_width = math.min(content_w + 2, max_w)
    local win_height = math.min(#lines, max_h)

    ---@type vim.api.keyset.win_config
    local win_opts = {
        width = win_width,
        height = win_height,
        style = "minimal",
        border = "rounded",
        title_pos = "center",
    }
    if opts and opts.title then
        win_opts.title = " " .. tostring(opts.title) .. " "
    end

    win_opts.relative = "editor"
    win_opts.row = math.floor((ui_height - win_height) / 2)
    win_opts.col = math.floor((ui_width - win_width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local win, win_augroup
    win, win_augroup = uiutil.create_window(buf, true, win_opts, function()
        win, win_augroup = nil, nil
    end)
    local function close()
        if win then
            vim.api.nvim_win_close(win, true)
        end
    end
    vim.api.nvim_create_autocmd("WinLeave", {
        group = win_augroup,
        once = true,
        callback = close,
    })

    vim.wo[win].wrap = false
    vim.wo[win].winfixbuf = true
    vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"

    if opts.is_markdown then
        vim.bo[buf].filetype = "markdown"
        local ok, _ = pcall(vim.treesitter.start, buf, "markdown")
        if not ok then
            vim.bo[buf].syntax = "on"
        end
        vim.wo[win].conceallevel = 3
        vim.wo[win].concealcursor = "nv"
    end

    local key_opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "q", close, key_opts)
    vim.keymap.set("n", "<Esc>", close, key_opts)
end

return M
