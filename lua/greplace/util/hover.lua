local M = {}

--- LSP-style hover built on `open_floating_preview`:
--- opens at the cursor without focus, closes when the cursor moves, and the
--- same key again jumps into it, where `q` or `<Esc>` closes it.

local _FOCUS_ID = "greplace.uil.hover"
local _BORDER   = "rounded"

--- Whether `open_floating_preview` has room for a border. It sizes the hover
--- to the current window alone, so in a short one the border leaves it no
--- lines and `nvim_open_win` fails; without a border it gets at least one.
---@return boolean
local function _has_room()
    local above = vim.fn.winline() - 1
    local below = vim.fn.winheight(0) - above
    return math.max(above, below) > 2
end

--- Resize `win` against the whole screen, with its border and title, where
--- `open_floating_preview` capped it to its window. Lines are re-measured only
--- if it hit `cap`; a bordered, uncapped, complete preview is left alone.
---@param win        integer
---@param lines      string[]
---@param max_width  integer
---@param max_height integer
---@param title      string?
---@param cap        integer
---@param bordered   boolean
local function _fit(win, lines, max_width, max_height, title, cap, bordered)
    local config = vim.api.nvim_win_get_config(win)
    local capped = config.width >= cap
    if bordered and not capped and config.height >= math.min(#lines, max_height) then
        return
    end

    local width = config.width
    if capped then
        for _, line in ipairs(lines) do
            width = math.max(width, vim.fn.strdisplaywidth(line))
        end
    end
    if title then width = math.max(width, vim.fn.strdisplaywidth(title)) end

    width = math.max(1, math.min(width, max_width))

    -- Screen cell of the cursor, 1-based; accounts for winbar, folds and wraps.
    local pos = vim.fn.screenpos(0, vim.fn.line("."), vim.fn.col("."))
    local above = pos.row - 1 - 2                                  -- 2 for the border
    local below = vim.o.lines - vim.o.cmdheight - pos.row - 2
    local up = above > below
    -- Open leftwards if the bordered hover would run off the right edge.
    local left = pos.col + width + 1 > vim.o.columns

    vim.api.nvim_win_set_config(win, {
        relative  = "cursor",
        anchor    = (up and "S" or "N") .. (left and "E" or "W"),
        row       = up and 0 or 1,
        col       = left and 1 or 0,
        width     = width,
        height    = math.max(1, math.min(#lines, max_height, up and above or below)),
        border    = _BORDER,
        title     = title,
        title_pos = title and "center" or nil,
    })
end

---@class greplace.uil.HoverOpts
---@field title    string?  shown centred in the border
---@field syntax   string?  syntax for the preview buffer, e.g. "git"
---@field focus_id string?  hovers sharing an id replace/focus each other
---                         (default: one id for all of greplace.uil)

--- Show `text` in a hover at the cursor. A second call from the same buffer
--- while the hover is up focuses it instead of opening another one.
---@param text string
---@param opts greplace.uil.HoverOpts?
---@return integer? buf
---@return integer? win  nil if there was nothing to show
function M.show(text, opts)
    opts = opts or {}
    local lines = vim.split(text, "\n", { trimempty = false })
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
        lines[#lines] = nil
    end
    if #lines == 0 then return nil end

    local max_width  = math.floor(vim.o.columns * 0.8)
    local max_height = math.floor(vim.o.lines * 0.8)

    -- No room for a border: open without it (and the title); `_fit` restores both.
    local room = _has_room()
    -- The width `open_floating_preview` holds the hover to.
    local cap = math.min(vim.api.nvim_win_get_width(0) - (room and 2 or 0), max_width)
    local buf, win = vim.lsp.util.open_floating_preview(lines, opts.syntax or "", {
        border     = room and _BORDER or "none",
        title      = room and opts.title or nil,
        focus_id   = opts.focus_id or _FOCUS_ID,
        wrap       = false,
        max_width  = max_width,
        max_height = max_height,
    })

    if opts.syntax == "markdown" then
        vim.wo[win].conceallevel = 3
        vim.wo[win].concealcursor = "nv"
    end

    -- A repeat call focuses the open hover, already sized.
    -- Measure the buffer: the preview trims leading blanks and rewrites markdown.
    if win ~= vim.api.nvim_get_current_win() then
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        _fit(win, lines, max_width, max_height, opts.title, cap, room)
    end

    -- A new window inherits its opener's options: opened from a scrollbound
    -- window, the hover would scroll and move along with it.
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false

    -- `q` comes with the preview; `<Esc>` is the other key a hover is expected
    -- to answer to. Both only matter once the hover has been focused.
    vim.keymap.set("n", "<Esc>", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, nowait = true, silent = true, desc = "Close hover" })

    return buf, win
end

return M
