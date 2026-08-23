local apply   = require("greplace.apply")
local panel   = require("greplace.panel")
local search  = require("greplace.search")

local _root

---@param rel   string
---@param lines string[]
---@return string abs path
local function write_file(rel, lines)
    local path = _root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
    return vim.fs.normalize(path)
end

---@param query string
---@return greplace.Match[]
local function run_search(query)
    local result, done
    search.run(query, { cwd = _root }, function(matches, err)
        result, done = matches or { err = err }, true
    end)
    assert.is_true(vim.wait(5000, function() return done end, 20))
    return result
end

---@param path string
---@return string[]
local function buf_lines(path)
    local bufnr = assert(require("greplace.util").find_buf(path), "no buffer for " .. path)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- The location each anchor is currently drawing, in buffer order, with a
--- deleted line's anchor showing as `false`.
---@param bufnr integer
---@return (string|boolean)[]
local function locations(bufnr)
    local ns    = vim.api.nvim_get_namespaces()["greplace.anchor"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local out   = {}
    for i, mark in ipairs(marks) do
        local virt = mark[4].virt_text
        -- An anchor pushed past the last line has nothing to draw on.
        out[i] = mark[2] < vim.api.nvim_buf_line_count(bufnr) and virt ~= nil
            and virt[1][1] or false
    end
    return out
end

--- Delete panel row `row` (0-indexed) as `dd` would, and let the deferred
--- redraw of the anchors run.
---@param bufnr integer
---@param row   integer
local function delete_row(bufnr, row)
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, {})
    vim.wait(100, function() return false end)
end

--- Rewrite one panel row the way a user editing it would: an in-line change,
--- not a line-wise delete-and-insert (which would collapse the anchors).
---@param bufnr integer
---@param row   integer 0-indexed
---@param lines string[]
local function edit_row(bufnr, row, lines)
    local old = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    vim.api.nvim_buf_set_text(bufnr, row, 0, row, #old, lines)
end

describe("greplace", function()
    before_each(function()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        _root = require("greplace.util").resolve(tmp)
        vim.fn.chdir(_root)
    end)

    after_each(function()
        vim.cmd("silent! %bwipeout!")
        vim.fn.delete(_root, "rf")
    end)

    it("collects matches from disk", function()
        write_file("a.txt", { "keep", "hit one", "hit two" })
        local matches = run_search("hit")
        assert.equals(2, #matches)
        assert.equals("a.txt", matches[1].relpath)
        assert.equals(2, matches[1].lnum)
        assert.equals("hit one", matches[1].text)
        assert.is_nil(matches[1].bufnr)
    end)

    it("searches unsaved buffer text instead of the file on disk", function()
        local path  = write_file("a.txt", { "old line" })
        local bufnr = assert(require("greplace.util").ensure_buf(path))
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "nothing", "hit here" })

        local matches = run_search("hit")
        assert.equals(1, #matches)
        assert.equals(2, matches[1].lnum)
        assert.equals("hit here", matches[1].text)
        assert.equals(bufnr, matches[1].bufnr)

        assert.equals(0, #run_search("old line"))
    end)

    it("renders matched lines verbatim, location as virtual text", function()
        write_file("a.txt", { "    hit one" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        assert.same({ "    hit one" }, vim.api.nvim_buf_get_lines(pbuf, 0, -1, false))

        local ns    = vim.api.nvim_get_namespaces()["greplace.anchor"]
        local marks = vim.api.nvim_buf_get_extmarks(pbuf, ns, 0, -1, { details = true })
        assert.equals(1, #marks)
        assert.equals("a.txt:1", marks[1][4].virt_text[1][1])
        assert.is_false(vim.bo[pbuf].modified)
    end)

    it("applies edits to buffers without touching disk", function()
        local a = write_file("a.txt", { "hit one", "plain" })
        local b = write_file("sub/b.txt", { "x", "hit two" })

        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        edit_row(pbuf, 0, { "HIT one" })
        edit_row(pbuf, 1, { "HIT two" })

        local result = apply.run(panel.regions(pbuf))
        assert.equals(2, result.replaced)
        assert.equals(2, result.files)
        assert.equals(0, result.skipped)

        assert.same({ "HIT one", "plain" }, buf_lines(a))
        assert.same({ "x", "HIT two" }, buf_lines(b))
        -- Nothing was written out.
        assert.same({ "hit one", "plain" }, vim.fn.readfile(a))
        assert.same({ "x", "hit two" }, vim.fn.readfile(b))
    end)

    it("splits a source line when a region grows", function()
        local a = write_file("a.txt", { "one hit", "tail" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        edit_row(pbuf, 0, { "first", "second" })

        local result = apply.run(panel.regions(pbuf))
        assert.equals(1, result.replaced)
        assert.same({ "first", "second", "tail" }, buf_lines(a))
    end)

    it("deletes a source line when its region is emptied", function()
        local a = write_file("a.txt", { "hit one", "hit two", "tail" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        -- Drop the first result line; its anchor collapses onto the second.
        vim.api.nvim_buf_set_lines(pbuf, 0, 1, false, {})

        local result = apply.run(panel.regions(pbuf))
        assert.same({ "hit two", "tail" }, buf_lines(a))
        assert.equals(1, #result.entries)
        assert.equals(1, result.entries[1].lnum)
    end)

    it("drops the location of a deleted line, leaving the rest in place", function()
        write_file("a.txt", { "hit one", "hit two", "hit three" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        assert.same({ "a.txt:1", "a.txt:2", "a.txt:3" }, locations(pbuf))

        delete_row(pbuf, 1)
        -- The middle anchor collapsed onto the last line; only the line that
        -- is really there still shows its location.
        assert.same({ "a.txt:1", false, "a.txt:3" }, locations(pbuf))

        delete_row(pbuf, 0)
        assert.same({ false, false, "a.txt:3" }, locations(pbuf))
    end)

    it("deletes the last source line when the last panel line goes", function()
        local a = write_file("a.txt", { "hit one", "hit two" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        delete_row(pbuf, 1)
        assert.same({ "a.txt:1", false }, locations(pbuf))

        apply.run(panel.regions(pbuf))
        assert.same({ "hit one" }, buf_lines(a))
    end)

    it("deletes every source line when the panel is emptied", function()
        local a = write_file("a.txt", { "hit one", "keep", "hit two" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        -- `ggdG` leaves one empty line behind, which means "everything is
        -- gone", not "blank out the last match".
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, {})
        vim.wait(100, function() return false end)
        assert.same({ false, false }, locations(pbuf))

        local result = apply.run(panel.regions(pbuf))
        assert.same({ "keep" }, buf_lines(a))
        assert.equals(0, #result.entries)
    end)

    it("keeps later line numbers correct after a region grows", function()
        local a = write_file("a.txt", { "hit one", "mid", "hit two" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        edit_row(pbuf, 0, { "A", "B" })

        local result = apply.run(panel.regions(pbuf))
        assert.same({ "A", "B", "mid", "hit two" }, buf_lines(a))
        assert.equals(4, result.entries[2].lnum)
        assert.equals("hit two", result.entries[2].text)
    end)

    it("skips a region whose source line moved underneath it", function()
        local a = write_file("a.txt", { "hit one" })
        local pbuf = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        local abuf = assert(require("greplace.util").ensure_buf(a))
        vim.api.nvim_buf_set_lines(abuf, 0, -1, false, { "someone else edited this" })
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "HIT one" })

        local result = apply.run(panel.regions(pbuf))
        assert.equals(0, result.replaced)
        assert.equals(1, result.skipped)
        assert.same({ "someone else edited this" }, buf_lines(a))
    end)

    it("reuses the panel buffer across searches", function()
        write_file("a.txt", { "hit one" })
        local first = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        local second = panel.open(run_search("hit"), {
            query = "hit", root = _root, height = 10, on_write = function() end,
        })
        assert.equals(first, second)
    end)
end)
