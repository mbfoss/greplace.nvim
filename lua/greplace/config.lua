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

---@class greplace.Config
---@field height_ratio number  share of the editor's lines the result split takes (0..1)
---@field limit  integer  maximum matches collected per search
---@field winbar boolean  show the query and the panel's counts in a winbar
---@field path_width integer  greatest display width of the `file:line` column; cropped left
---@field spell boolean  enable spell checking in the panel window

---@type greplace.Config
local _defaults = {
    height_ratio = 0.4,
    limit  = 10000,
    winbar = true,
    path_width = 60,
    spell  = false,
}

--- The live settings, refilled in place so captured references never go stale.
---@type greplace.Config
M.current = vim.deepcopy(_defaults)

--- The settings as they shipped, as a fresh deep copy the caller may mutate.
---@return greplace.Config
function M.defaults()
    return vim.deepcopy(_defaults)
end

--- Overwrite `dst` from `src` key by key, recursing into tables so nothing
--- reachable from `current` is ever replaced and nothing stale survives.
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

--- Merge `opts` over a fresh copy of the defaults; `setup()` is optional and
--- no key from an earlier call survives into a later one.
---@param opts greplace.Config?
function M.setup(opts)
    -- Deep, so naming one key does not drop the rest of `keys`.
    _refill(M.current, vim.tbl_deep_extend("force", vim.deepcopy(_defaults), opts or {}))
end

return M
