-- Loaded up front: the specs `chdir` into a temp directory, and the plugin's
-- own runtimepath entry is relative, so a lazy `require` mid-test would miss.
require("greplace")
require("greplace.apply")

local usercmd  = require("greplace.util.usercmd")
local panel    = require("greplace.panel")

local _root

---@param rel   string
---@param lines string[]
local function write_file(rel, lines)
    local path = _root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
end

--- Run `:Greplace ...` and wait for its results. The panel goes up
--- immediately, showing that a search is running, so its mere existence says
--- nothing: wait for it to hold matches.
---@param cmd string
---@return integer? bufnr
local function run(cmd)
    vim.cmd(cmd)
    vim.wait(5000, function()
        local bufnr = panel.find_buf()
        local state = bufnr and panel.state(bufnr)
        return state ~= nil and next(state.entries) ~= nil
    end, 20)
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

    it("opens the panel with a status line before the results arrive", function()
        write_file("a.txt", { "alpha beta" })
        vim.cmd("Greplace alpha")

        -- Synchronously after the command: the search has not run yet.
        local bufnr = assert(panel.find_buf())
        assert.are.same({ "" }, panel_lines(bufnr))
        assert.is_false(vim.bo[bufnr].modifiable)
        local marks = vim.api.nvim_buf_get_extmarks(bufnr,
            vim.api.nvim_create_namespace("greplace.status"), 0, -1, { details = true })
        assert.are.equal(1, #marks)
        assert.is_truthy(vim.inspect(marks[1][4].virt_text):match("searching"))

        -- And it is an ordinary, editable result panel once they do.
        assert.is_true(vim.wait(5000, function()
            return panel_lines(bufnr)[1] == "alpha beta"
        end, 20))
        assert.is_true(vim.bo[bufnr].modifiable)
    end)

    it("searches for the whole command line as one literal query", function()
        write_file("a.txt", { "alpha beta", "alpha", "gamma" })
        local bufnr = assert(run("Greplace alpha beta"))
        assert.are.same({ "alpha beta" }, panel_lines(bufnr))
    end)

    it("treats the query as a regex with a bang", function()
        write_file("a.txt", { "alpha beta", "alpha", "gamma" })
        local bufnr = assert(run([[Greplace! ^alpha\s+\w+]]))
        assert.are.same({ "alpha beta" }, panel_lines(bufnr))
    end)

    it("re-runs the last query when given no query", function()
        write_file("a.txt", { "hit one" })
        local bufnr = assert(run("Greplace hit"))
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "scribbled over" })

        write_file("b.txt", { "hit two" })
        vim.cmd("Greplace")
        assert.is_true(vim.wait(5000, function()
            return #panel_lines(bufnr) == 2
        end, 20))
        local lines = panel_lines(bufnr)
        table.sort(lines)
        assert.are.same({ "hit one", "hit two" }, lines)
    end)

    it("opens the source of the line under the cursor on <CR>", function()
        write_file("a.txt", { "one", "alpha beta", "three" })
        local bufnr = assert(run("Greplace alpha"))
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

    it("loads edited files with their filetype set", function()
        write_file("a.lua", { "local hit = 1" })
        local pbuf = assert(run("Greplace hit"))
        -- Write through the panel's own `BufWriteCmd`, the path that loads the
        -- file: the events it fires only reach the new buffer if that autocmd
        -- is `nested`, and without them the file arrives with no filetype and
        -- so no syntax, treesitter or LSP.
        vim.api.nvim_buf_set_text(pbuf, 0, 0, 0, 0, { "-- " })
        vim.cmd("silent write")

        local target = assert(require("greplace.util").find_buf(_root .. "/a.lua"))
        assert.equals("lua", vim.bo[target].filetype)
    end)
end)
