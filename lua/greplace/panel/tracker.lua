-- What a rendered list keeps track of as it is edited: which matches still
-- have a line, which lines differ from what was rendered, the counts the
-- winbar shows, and what each anchor draws.
--
-- The only place these change. Whoever finds out that a line was removed or
-- edited -- `marks.redraw` reads it off the buffer and only reports it --
-- tells the panel, which tells the tracker; the counts cannot drift from the
-- flags they are counted from, because nothing else can move either.

local M = {}

---@class greplace.Stats
---@field files   integer  distinct files still listed
---@field lines   integer  matches still listed (a removed one does not count)
---@field changes integer  listed matches whose text no longer matches the source
---@field changed_files integer  listed files with at least one such match

---@class greplace.Tracker
---@field stats greplace.Stats  read only outside this module
---@field drawn table<integer, table[]>  each anchor's virtual text chunks; a
---                        chunk list is replaced (`set_drawn`), never edited
---@field private hidden  table<integer, true>  anchors whose line was removed
---@field private changed table<integer, true>  anchors whose line no longer
---                        holds the text it was rendered with
---@field private paths   table<integer, string>  the file of each anchor
---@field private per_file table<string, integer>  how many of each file's
---                        matches still have a line, for `stats.files`
---@field private per_file_changes table<string, integer>  how many of each
---                        file's counted changes there are, for
---                        `stats.changed_files`
local Tracker = {}
Tracker.__index = Tracker

--- A tracker for a list just rendered: every match has its line, none is
--- edited.
---@param entries table<integer, greplace.Entry>  keyed by anchor id
---@param drawn   table<integer, table[]>  the chunks each anchor draws; owned
---                                        by the tracker from here on
---@return greplace.Tracker
function M.new(entries, drawn)
    local stats = { files = 0, lines = 0, changes = 0, changed_files = 0 }
    local paths, per_file = {}, {}
    for id, entry in pairs(entries) do
        paths[id]  = entry.path
        stats.lines = stats.lines + 1
        local n = (per_file[entry.path] or 0) + 1
        per_file[entry.path] = n
        if n == 1 then stats.files = stats.files + 1 end
    end
    return setmetatable({
        stats    = stats,
        drawn    = drawn,
        hidden   = {},
        changed  = {},
        paths    = paths,
        per_file = per_file,
        per_file_changes = {},
    }, Tracker)
end

---@param id integer
---@return boolean
function Tracker:is_hidden(id)
    return self.hidden[id] == true
end

---@param id integer
---@return boolean
function Tracker:is_changed(id)
    return self.changed[id] == true
end

--- A counted change entered (`n` = 1) or left (`n` = -1) the count of the
--- file of anchor `id`.
---@param self greplace.Tracker
---@param id   integer
---@param n    integer
local function count_change(self, id, n)
    local stats = self.stats
    stats.changes = stats.changes + n
    local path = self.paths[id]
    local left = (self.per_file_changes[path] or 0) + n
    self.per_file_changes[path] = left
    -- A file counts as changed while any of its counted matches is.
    if left == (n > 0 and 1 or 0) then
        stats.changed_files = stats.changed_files + n
    end
end

--- A match's line was removed (`hide`), or came back.
---@param id   integer
---@param hide boolean
function Tracker:set_hidden(id, hide)
    if self:is_hidden(id) == hide then return end
    self.hidden[id] = hide or nil
    local n     = hide and -1 or 1
    local stats = self.stats
    stats.lines = stats.lines + n
    if self.changed[id] then count_change(self, id, n) end
    local path = self.paths[id]
    local left = (self.per_file[path] or 0) + n
    self.per_file[path] = left
    -- A file counts while any of its matches does.
    if left == (n > 0 and 1 or 0) then
        stats.files = stats.files + n
    end
end

--- A match's line started or stopped differing from its rendered text. A
--- removed match keeps its flag but is not counted.
---@param id      integer
---@param changed boolean
function Tracker:set_changed(id, changed)
    if self:is_changed(id) == changed then return end
    self.changed[id] = changed or nil
    if not self:is_hidden(id) then
        count_change(self, id, changed and 1 or -1)
    end
end

---@param id     integer
---@param chunks table[]
function Tracker:set_drawn(id, chunks)
    self.drawn[id] = chunks
end

--- The counts, as a table of the caller's own.
---@return greplace.Stats
function Tracker:snapshot()
    local s = self.stats
    return {
        files = s.files, lines = s.lines, changes = s.changes,
        changed_files = s.changed_files,
    }
end

return M
