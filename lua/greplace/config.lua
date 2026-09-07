local M = {}

-- ---------------------------------------------------------------------------
-- greplace's user configuration.
--
-- Kept in its own module so that the modules which read it (`greplace.init`,
-- and anything else that grows a knob later) depend on the settings rather
-- than on each other, and so that `setup()` can be called before or after the
-- first search without either order mattering: the table is mutated in place
-- and read at use time.
-- ---------------------------------------------------------------------------

---@class greplace.Keys
---@field open  string  panel mapping that opens the source of the line under
---                     the cursor (empty or `false` to leave `<CR>` alone)
---@field hover string  panel mapping that shows the full details of the match
---                     under the cursor in a floating window (empty or
---                     `false` to leave `K` alone)

---@class greplace.Config
---@field height integer  height of the result split
---@field limit  integer  maximum matches collected per search
---@field winbar boolean  show the query and the panel's counts in a winbar
---@field path_width integer  greatest display width the `file:line` column may
---                           take in the panel; a longer location is cropped on
---                           the left, so the file name and line number -- the
---                           telling end of it -- stay visible. The full path is
---                           always available through the `hover` mapping.
---@field keys   greplace.Keys

---@type greplace.Config
local _defaults = {
    height = 15,
    limit  = 10000,
    winbar = true,
    path_width = 60,
    keys   = {
        open  = "<CR>",
        hover = "K",
    },
}

---@type greplace.Config
M.options = vim.deepcopy(_defaults)

--- Merge `opts` over the current settings. Optional: every default stands on
--- its own, so a user who never calls `setup()` gets the same plugin.
---@param opts greplace.Config?
function M.setup(opts)
    -- Deep, so that a user who names one key does not drop the rest of
    -- `keys` along with it.
    M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
