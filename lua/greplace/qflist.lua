local M = {}

local util   = require("greplace.util")
local search = require("greplace.search")

-- ---------------------------------------------------------------------------
-- The quickfix list as a match list.
--
-- `:Greplace qf` fills the panel from whatever put entries in the
-- quickfix list -- `:grep`, `:vimgrep`, an LSP's references, a test runner --
-- so the same editing and write-back works on a list greplace did not produce.
--
-- The entry's own `text` is not used. The panel's contract is that a shown
-- line is the source line byte for byte, and a quickfix `text` is whatever the
-- producer chose to put there: `:grep` keeps the line, `:vimgrep` trims its
-- leading whitespace, an LSP writes a message instead. So each line is read
-- back from the file itself -- from the buffer when one is loaded, since that
-- is the text a replacement would land on -- and an entry whose line cannot be
-- read is dropped rather than guessed at.
-- ---------------------------------------------------------------------------

---@class greplace.qflist.Source
---@field lines string[]
---@field bufnr integer?  set when the text came from a loaded buffer

--- The file's current lines, read once per path: from its loaded buffer if it
--- has one, from disk otherwise.
---@param path  string  absolute, resolved
---@param cache table<string, greplace.qflist.Source|false>
---@return greplace.qflist.Source?
local function source_of(path, cache)
    local hit = cache[path]
    if hit ~= nil then return hit or nil end

    local found ---@type greplace.qflist.Source?
    local bufnr = util.find_buf(path)
    if bufnr then
        found = { lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr = bufnr }
    elseif vim.fn.filereadable(path) == 1 then
        found = { lines = vim.fn.readfile(path) }
    end

    cache[path] = found or false
    return found
end

--- The matched span of one entry, when it has one to give. `col` alone says
--- where a match starts but not where it ends, and a highlight has to know
--- both, so an entry without an `end_col` past its `col` is listed with no
--- highlight rather than an invented one.
---@param item table   a `getqflist()` entry
---@param text string  the source line
---@return greplace.Submatch[]
local function submatches(item, text)
    local col, endcol = item.col or 0, item.end_col or 0
    if col < 1 or endcol <= col then return {} end
    -- Both are 1-indexed byte columns, the end one exclusive.
    local s = math.min(col - 1, #text)
    local e = math.min(endcol - 1, #text)
    if e <= s then return {} end
    return { { s = s, e = e } }
end

--- Read the quickfix list into matches, in the order the list holds them.
---
--- Two entries on one line become one match: the panel edits lines, so listing
--- that line twice would offer the same edit twice and apply it twice. Their
--- highlights are merged onto the single entry.
---@param root string  absolute, resolved
---@param items table[]?  `getqflist()` entries (default: the quickfix list)
---@return greplace.Match[] matches
---@return integer dropped  entries with no file, no line, or no readable line
function M.matches(root, items)
    items = items or vim.fn.getqflist()

    local matches = {} ---@type greplace.Match[]
    local by_line = {} ---@type table<string, greplace.Match>
    local cache   = {}
    local dropped = 0

    for _, item in ipairs(items) do
        local bufnr = item.bufnr or 0
        local name  = bufnr > 0 and vim.api.nvim_buf_get_name(bufnr) or ""
        local lnum  = item.lnum or 0
        local path  = name ~= "" and util.resolve(name) or nil
        local src   = path and lnum >= 1 and source_of(path, cache) or nil
        local text  = src and src.lines[lnum]

        if not text then
            dropped = dropped + 1
        else
            local key = path .. "\0" .. lnum
            local hit = by_line[key]
            if hit then
                vim.list_extend(hit.subs, submatches(item, text))
            else
                local m = {
                    path    = path,
                    relpath = search.relative_path(path, root),
                    lnum    = lnum,
                    text    = text,
                    subs    = submatches(item, text),
                    bufnr   = src.bufnr,
                }
                by_line[key]        = m
                matches[#matches + 1] = m
            end
        end
    end

    return matches, dropped
end

return M
