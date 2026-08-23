local M = {}

local util = require("greplace.util")

-- ---------------------------------------------------------------------------
-- Applying the edited panel back onto the files it came from.
--
-- Edits land in buffers only — a file with no buffer yet is loaded into one —
-- and nothing is written to disk, so the result is reviewable (and undoable)
-- before the user decides to `:wa`.
-- ---------------------------------------------------------------------------

---@class greplace.ApplyResult
---@field replaced integer  source lines rewritten
---@field files    integer  buffers touched
---@field skipped  integer  regions dropped because the source line had moved
---@field entries  greplace.Entry[]  post-edit entries, in panel order

---@param bufnr integer
---@param lnum  integer 1-indexed
---@return string?
local function line_at(bufnr, lnum)
    return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
end

--- Apply one file's regions, bottom-up so line numbers stay valid mid-pass,
--- then restate each entry against the text now in the buffer.
---@param path    string
---@param regions greplace.Region[]  ascending by source line
---@param result  greplace.ApplyResult
---@param keep    table<greplace.Region, boolean>  regions that survived
local function apply_file(path, regions, result, keep)
    local bufnr, err = util.ensure_buf(path)
    if not bufnr then
        result.skipped = result.skipped + #regions
        vim.notify("greplace: " .. (err or path), vim.log.levels.WARN)
        return
    end

    local touched = false
    for i = #regions, 1, -1 do
        local region = regions[i]
        local entry  = region.entry
        local lines  = region.lines
        local changed = #lines ~= 1 or lines[1] ~= entry.text

        if not changed then
            keep[region] = true
        elseif line_at(bufnr, entry.lnum) ~= entry.text then
            -- The file moved under the panel (an edit elsewhere, a reload).
            -- Rewriting that line would corrupt it, so leave it alone.
            result.skipped = result.skipped + 1
            keep[region]   = true
        else
            vim.api.nvim_buf_set_lines(bufnr, entry.lnum - 1, entry.lnum, false, lines)
            result.replaced = result.replaced + 1
            touched         = true
            keep[region]    = #lines > 0
        end
    end

    if touched then result.files = result.files + 1 end

    -- Line numbers below an edit shifted by however many lines it added or
    -- removed; walk top-down accumulating that offset.
    local offset = 0
    for _, region in ipairs(regions) do
        local entry = region.entry
        local lines = region.lines
        entry.lnum  = entry.lnum + offset
        if keep[region] then
            entry.text = line_at(bufnr, entry.lnum) or entry.text
        end
        offset = offset + #lines - 1
    end
end

--- Apply every region of an edited panel.
---@param regions greplace.Region[]  in panel order
---@return greplace.ApplyResult
function M.run(regions)
    ---@type greplace.ApplyResult
    local result = { replaced = 0, files = 0, skipped = 0, entries = {} }

    ---@type table<string, greplace.Region[]>
    local by_file, order = {}, {}
    for _, region in ipairs(regions) do
        local path = region.entry.path
        if not by_file[path] then
            by_file[path] = {}
            order[#order + 1] = path
        end
        table.insert(by_file[path], region)
    end

    local keep = {}
    for _, path in ipairs(order) do
        local file_regions = by_file[path]
        table.sort(file_regions, function(a, b) return a.entry.lnum < b.entry.lnum end)
        apply_file(path, file_regions, result, keep)
    end

    for _, region in ipairs(regions) do
        if keep[region] then
            result.entries[#result.entries + 1] = region.entry
        end
    end
    return result
end

return M
