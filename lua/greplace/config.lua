local M = {}

-- ---------------------------------------------------------------------------
-- greplace's user configuration.
--
-- Kept in its own module so that the modules which read it (`greplace.init`,
-- and anything else that grows a knob later) depend on the settings rather
-- than on each other, and so that `setup()` can be called before or after the
-- first search without either order mattering: `current` is refilled in place,
-- so a module may capture it once at its top
-- (`local config = require("greplace.config").current`).
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
---@field spell boolean  enable spell checking in the panel window
---@field keys   greplace.Keys

---@type greplace.Config
local _defaults = {
    height = 15,
    limit  = 10000,
    winbar = true,
    path_width = 60,
    spell  = false,
    keys   = {
        open  = "<CR>",
        hover = "K",
    },
}

--- The live settings, at the defaults until `setup()` applies the user's.
--- Always this same table: `setup()` refills it in place, so a captured
--- reference -- this table or any table under it -- never goes stale.
---@type greplace.Config
M.current = vim.deepcopy(_defaults)

--- The settings as they shipped. A fresh deep copy every call, so the caller
--- may keep or mutate it.
---@return greplace.Config
function M.defaults()
    return vim.deepcopy(_defaults)
end

--- Overwrite `dst` from `src` key by key: a key `src` lacks is dropped, and a
--- table on both sides recurses instead of being swapped in. Nothing reachable
--- from `current` is ever replaced, and nothing stale is left behind.
local function _refill(dst, src)
    for k in pairs(dst) do
        if src[k] == nil then dst[k] = nil end
    end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            _refill(dst[k], v)
        else
            dst[k] = v
        end
    end
end

--- Merge `opts` over the defaults. Optional: every default stands on its own,
--- so a user who never calls `setup()` gets the same plugin. Merging over a
--- fresh copy of the defaults rather than over `current` means no key of an
--- earlier call can survive into a later one.
---@param opts greplace.Config?
function M.setup(opts)
    -- Deep, so that a user who names one key does not drop the rest of
    -- `keys` along with it.
    _refill(M.current, vim.tbl_deep_extend("force", vim.deepcopy(_defaults), opts or {}))
end

return M
