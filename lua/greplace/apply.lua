local M = {}

local util = require("greplace.util")

-- ---------------------------------------------------------------------------
-- Applying the edited panel back onto the files it came from.
--
-- Edits land in buffers only (a file with no buffer yet is loaded into one)
-- and nothing is written to disk, so the result is reviewable (and undoable)
-- before the user decides to `:wa`.
--
-- A match deleted from the panel is a match the user has taken out of the
-- replacement: its source line is left alone, and it simply stops being listed.
-- Nothing here ever removes a line from a file.
-- ---------------------------------------------------------------------------

---@class greplace.ApplyResult
---@field replaced integer  source lines rewritten
---@field files    integer  buffers touched
---@field skipped  integer  regions dropped because the source line had moved
---@field removed  integer  matches deleted from the panel, so left untouched
---@field entries  greplace.Entry[]  post-edit entries, in panel order

---@param bufnr integer
---@param lnum  integer 1-indexed
---@return string?
local function line_at(bufnr, lnum)
    return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
end

--- Whether a region asks for its source line to be rewritten: it is still
--- listed, and no longer holds exactly the line it was rendered with.
---@param region greplace.Region
---@return boolean
local function is_edit(region)
    local lines = region.lines
    return #lines > 0 and (#lines ~= 1 or lines[1] ~= region.entry.text)
end

--- Apply one file's regions, bottom-up so line numbers stay valid mid-pass,
--- then restate each entry against the text now in the buffer.
---@param path    string
---@param regions greplace.Region[]  ascending by source line
---@param result  greplace.ApplyResult
---@param keep    table<greplace.Region, boolean>  regions that survived
---@param bufs    table<string, integer>  a `util.buf_map()`, which
---                `ensure_buf` adds to as it loads files into buffers
local function apply_file(path, regions, result, keep, bufs)
    -- A file none of whose lines were edited has nothing to write, so it is
    -- not loaded just to find that out: a search over a large tree would
    -- otherwise leave a buffer behind for every file it listed. Its matches
    -- stay listed as rendered, bar those deleted from the panel.
    if not vim.iter(regions):any(is_edit) then
        for _, region in ipairs(regions) do
            if #region.lines == 0 then
                result.removed = result.removed + 1
            else
                keep[region] = true
            end
        end
        return
    end

    -- `pcall`: a load can fail for reasons no check up front catches (a swap
    -- file, `E37` under `'nohidden'`), and raising would abandon the apply
    -- part-way. The file is skipped as an unreadable one is, and the rest go on.
    local ok, bufnr, err = pcall(util.ensure_buf, path, bufs)
    if not ok then
        err, bufnr = tostring(bufnr), nil
    end
    if not bufnr then
        result.skipped = result.skipped + #regions
        vim.notify("greplace: " .. (err or path), vim.log.levels.WARN)
        return
    end

    -- How many lines each region actually added to (or took from) the file, so
    -- that only the edits that really happened shift the ones below them.
    ---@type table<greplace.Region, integer>
    local shift   = {}
    local touched = false

    for i = #regions, 1, -1 do
        local region = regions[i]
        local entry  = region.entry
        local lines  = region.lines

        if #lines == 0 then
            -- The match was deleted from the panel, which takes it out of the
            -- replacement: the source line is left exactly as it is, and the
            -- match drops off the list rather than coming back on the redraw.
            result.removed = result.removed + 1
        elseif not is_edit(region) then
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
            keep[region]    = true
            shift[region]   = #lines - 1
        end
    end

    if touched then result.files = result.files + 1 end

    -- Line numbers below an edit shifted by however many lines it added or
    -- removed; walk top-down accumulating that offset.
    local offset = 0
    for _, region in ipairs(regions) do
        local entry = region.entry
        entry.lnum  = entry.lnum + offset
        if keep[region] then
            entry.text = line_at(bufnr, entry.lnum) or entry.text
        end
        offset = offset + (shift[region] or 0)
    end
end

--- Group regions by the file they belong to, each group ascending by source
--- line, and the files in the order the panel first lists them.
---@param regions greplace.Region[]
---@return table<string, greplace.Region[]> by_file
---@return string[] order
local function group(regions)
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
    for _, path in ipairs(order) do
        table.sort(by_file[path], function(a, b) return a.entry.lnum < b.entry.lnum end)
    end
    return by_file, order
end

--- Apply every region of an edited panel.
---@param regions greplace.Region[]  in panel order
---@return greplace.ApplyResult
function M.run(regions)
    ---@type greplace.ApplyResult
    local result = { replaced = 0, files = 0, skipped = 0, removed = 0, entries = {} }

    local by_file, order = group(regions)
    local keep = {}
    -- One walk of the buffer list for the whole apply: `ensure_buf` would
    -- otherwise resolve every buffer's name again for each file touched.
    local bufs = util.buf_map()
    for _, path in ipairs(order) do
        apply_file(path, by_file[path], result, keep, bufs)
    end

    for _, region in ipairs(regions) do
        if keep[region] then
            result.entries[#result.entries + 1] = region.entry
        end
    end
    return result
end

---@class greplace.PreviewFile
---@field path    string
---@field relpath string
---@field before  string[]  the file's text now: its buffer's, or the disk's
---@field after   string[]  the same text with the file's edits applied

---@class greplace.Preview
---@field files   greplace.PreviewFile[]  files a write would change, in panel order
---@field skipped { entry:greplace.Entry, reason:string }[]  edits a write would
---                          leave out, and why

--- The text of a file as a write would find it: its buffer's when it has one,
--- otherwise the file on disk, read without loading it into a buffer -- a
--- preview must leave no buffers behind. A trailing CR is dropped as a buffer
--- with `fileformat=dos` drops it, and as the search dropped it from the text
--- the panel shows.
---@param path string
---@param bufs table<string, integer>  a `util.buf_map()`
---@return string[]? lines
local function current_lines(path, bufs)
    local bufnr = bufs[path]
    if bufnr then return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end
    if vim.fn.filereadable(path) ~= 1 then return nil end
    return vim.tbl_map(function(l) return (l:gsub("\r$", "")) end, vim.fn.readfile(path))
end

--- What `M.run` would do with these regions, done to copies: nothing is loaded
--- and no buffer is changed. The same rules decide it -- an unedited or deleted
--- match changes nothing, and one whose source line moved is skipped.
---@param regions greplace.Region[]  in panel order
---@return greplace.Preview
function M.preview(regions)
    ---@type greplace.Preview
    local out = { files = {}, skipped = {} }

    local by_file, order = group(regions)
    local bufs = util.buf_map()
    for _, path in ipairs(order) do
        local file_regions = by_file[path]
        if vim.iter(file_regions):any(is_edit) then
            local before = current_lines(path, bufs)
            if not before then
                for _, region in ipairs(file_regions) do
                    if is_edit(region) then
                        table.insert(out.skipped, { entry = region.entry, reason = "not readable" })
                    end
                end
            else
                -- Built in one forward pass, copying the untouched stretch
                -- before each edit across and then the edit itself. Splicing
                -- each edit into a copy of the whole file instead rebuilds
                -- everything below it once per edit, so a file with many of
                -- them costs a pass over the file for each one.
                --
                -- `group` sorted the regions by source line, so `at` -- the
                -- next line of `before` still to copy -- only ever moves
                -- forwards, and the skips come out in line order already.
                local after   = {}
                local skips   = {}
                local changed = false
                local at      = 1
                for _, region in ipairs(file_regions) do
                    local entry = region.entry
                    if is_edit(region) then
                        if before[entry.lnum] ~= entry.text then
                            skips[#skips + 1] = { entry = entry, reason = "source changed" }
                        elseif entry.lnum >= at then
                            for j = at, entry.lnum - 1 do after[#after + 1] = before[j] end
                            vim.list_extend(after, region.lines)
                            at      = entry.lnum + 1
                            changed = true
                        end
                        -- An edit on a line an earlier one already rewrote
                        -- (`entry.lnum < at`) is left out rather than applied
                        -- over the top of it: two matches on one source line
                        -- is not a list the panel can write back coherently,
                        -- and `M.run` would not manage it either.
                    end
                end
                for j = at, #before do after[#after + 1] = before[j] end
                vim.list_extend(out.skipped, skips)
                if changed then
                    table.insert(out.files, {
                        path    = path,
                        relpath = file_regions[1].entry.relpath,
                        before  = before,
                        after   = after,
                    })
                end
            end
        end
    end
    return out
end

return M
