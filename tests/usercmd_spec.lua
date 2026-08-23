local usercmd  = require("greplace.util.usercmd")
local greplace = require("greplace")
local panel    = require("greplace.panel")

local _root

---@param rel   string
---@param lines string[]
local function write_file(rel, lines)
    local path = _root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
end

--- Run `:Greplace ...` and wait for the panel it opens, since the search is
--- asynchronous.
---@param cmd string
---@return integer? bufnr
local function run(cmd)
    vim.cmd(cmd)
    vim.wait(5000, function() return panel.find_buf() ~= nil end, 20)
    return panel.find_buf()
end

---@param bufnr integer
---@return string[]
local function panel_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

describe("greplace.util.usercmd", function()
    it("splits arguments on unescaped whitespace", function()
        local seen
        usercmd.handle({ name = "Greplace", args = [[search one two]] },
            function(_, args) seen = args end)
        assert.are.same({ "search", "one", "two" }, seen)
    end)

    it("keeps quoted and escaped whitespace inside one argument", function()
        local seen
        usercmd.handle({ name = "Greplace", args = [["one two" three\ four]] },
            function(_, args) seen = args end)
        assert.are.same({ "one two", "three four" }, seen)
    end)

    it("reports an error from the command body as a notification", function()
        local notified
        local orig = vim.notify
        vim.notify = function(msg) notified = msg end
        local ok = pcall(usercmd.handle, { name = "Greplace", args = "search x" },
            function() error("boom") end)
        vim.notify = orig
        assert.is_true(ok)
        assert.is_truthy(notified and notified:match("boom"))
    end)

    it("completes the subcommand, then defers to the subcommand", function()
        local subs = usercmd.complete("", "Greplace ", function(_, rest)
            return #rest == 0 and { "search", "refresh" } or { "inner" }
        end)
        assert.are.same({ "search", "refresh" }, subs)

        local inner = usercmd.complete("i", "Greplace search i", function(_, rest)
            return #rest == 0 and { "search", "refresh" } or { "inner" }
        end)
        assert.are.same({ "inner" }, inner)
    end)
end)

describe(":Greplace", function()
    before_each(function()
        local tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")
        _root = require("greplace.util").resolve(tmp)
        vim.fn.chdir(_root)
        vim.cmd("runtime! plugin/greplace.lua")
    end)

    after_each(function()
        vim.cmd("silent! %bwipeout!")
        vim.fn.delete(_root, "rf")
    end)

    it("searches for the whole tail as one literal query", function()
        write_file("a.txt", { "alpha beta", "alpha", "gamma" })
        local bufnr = assert(run("Greplace search alpha beta"))
        assert.are.same({ "alpha beta" }, panel_lines(bufnr))
    end)

    it("treats the query as a regex with a bang", function()
        write_file("a.txt", { "alpha beta", "alpha", "gamma" })
        local bufnr = assert(run([[Greplace! search ^alpha\s+\w+]]))
        assert.are.same({ "alpha beta" }, panel_lines(bufnr))
    end)

    it("re-runs the last query on refresh", function()
        write_file("a.txt", { "hit one" })
        local bufnr = assert(run("Greplace search hit"))
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "scribbled over" })

        write_file("b.txt", { "hit two" })
        vim.cmd("Greplace refresh")
        assert.is_true(vim.wait(5000, function()
            return #panel_lines(bufnr) == 2
        end, 20))
        local lines = panel_lines(bufnr)
        table.sort(lines)
        assert.are.same({ "hit one", "hit two" }, lines)
    end)

    it("opens the source of the line under the cursor on <CR>", function()
        write_file("a.txt", { "one", "alpha beta", "three" })
        local bufnr = assert(run("Greplace search alpha"))
        vim.api.nvim_win_set_cursor(0, { 1, 6 })
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

        assert.are.equal(_root .. "/a.txt",
            vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
        assert.are.same({ 2, 6 }, vim.api.nvim_win_get_cursor(0))
        -- The panel keeps its own window rather than being opened over.
        local shown = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == bufnr then shown = true end
        end
        assert.is_true(shown)
    end)

    it("completes its subcommands", function()
        assert.are.same({ "search", "refresh" },
            greplace.complete("Greplace", {}, ""))
        assert.are.same({}, greplace.complete("Greplace", { "search" }, ""))
    end)
end)
