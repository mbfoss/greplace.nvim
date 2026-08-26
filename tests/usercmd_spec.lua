-- Loaded up front: the specs `chdir` into a temp directory, and the plugin's
-- own runtimepath entry is relative, so a lazy `require` mid-test would miss.
require("greplace")
require("greplace.apply")
require("greplace.qflist")

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
    it("hands Neovim's own split of the arguments to the body", function()
        local seen
        usercmd.handle({ name = "Greplace", fargs = { "search", "one", "two" } },
            function(_, args) seen = args end)
        assert.are.same({ "search", "one", "two" }, seen)
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

    it("takes the query literally, dashes and regex metacharacters included", function()
        write_file("a.txt", { [[^alpha\s+ -- literal]], "alpha beta" })
        local bufnr = assert(run([[Greplace ^alpha\s+ -- literal]]))
        assert.are.same({ [[^alpha\s+ -- literal]] }, panel_lines(bufnr))
    end)

    it("cancels the search in flight when given no query", function()
        write_file("a.txt", { "hit one" })
        -- Start a search and stop it before it can land: `:Greplace` with no
        -- query cancels, and the results never arrive.
        vim.cmd("Greplace hit")
        vim.cmd("Greplace")

        local bufnr = assert(require("greplace.panel").find_buf())
        -- The panel is left with its status line, never with a result.
        local function has_results()
            local lines = panel_lines(bufnr)
            return #lines > 1 or lines[1] ~= ""
        end
        assert.is_false(has_results())
        assert.is_false(vim.wait(300, has_results, 20))
    end)

    it("says so when there is no search to cancel", function()
        local notified
        local orig = vim.notify
        vim.notify = function(msg) notified = msg end
        vim.cmd("Greplace")
        vim.cmd("GreplaceEx")
        vim.notify = orig
        assert.is_truthy(notified and notified:match("no search running"))
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

    it("filters the file set with GreplaceEx's flags", function()
        write_file("a.lua", { "hit lua" })
        write_file("b.md", { "hit md" })
        write_file(".hidden/c.lua", { "hit hidden" })

        local bufnr = assert(run("GreplaceEx --filter *.lua --hidden -- hit"))
        assert.are.same({ "hit hidden", "hit lua" }, panel_lines(bufnr))

        assert.are.same({ "hit md" },
            panel_lines(assert(run("GreplaceEx --type md -- hit"))))
        -- An excluding glob, and the `.gitignore`-blind default: without
        -- `hidden` the dotfile is out again.
        assert.are.same({ "hit lua" },
            panel_lines(assert(run("GreplaceEx --filter *.lua --filter !b.* -- hit"))))
    end)

    it("filters open buffers the same way, which rg cannot do itself", function()
        -- The buffer pass feeds rg one nameless stdin stream, so `-g` has
        -- nothing to filter there: unless greplace filters the buffer list
        -- itself, an unsaved `.md` shows up in a `filter=*.lua` search.
        write_file("a.lua", { "hit lua" })
        write_file("b.md", { "nothing here" })
        local mdbuf = assert(require("greplace.util").ensure_buf(_root .. "/b.md"))
        vim.api.nvim_buf_set_lines(mdbuf, 0, -1, false, { "hit md, unsaved" })

        assert.are.same({ "hit lua" },
            panel_lines(assert(run("GreplaceEx --filter *.lua -- hit"))))
        -- Unfiltered, that same unsaved line is found.
        assert.are.same({ "hit lua", "hit md, unsaved" },
            panel_lines(assert(run("GreplaceEx -- hit"))))
    end)

    it("leaves a `--` past the separator to the query, and rejects a line without one", function()
        write_file("a.txt", { "a -- b", "alpha" })
        assert.are.same({ "a -- b" }, panel_lines(assert(run("GreplaceEx -- a -- b"))))

        local notified
        local orig = vim.notify
        vim.notify = function(msg) notified = msg end
        vim.cmd("GreplaceEx alpha")
        vim.notify = orig
        assert.is_truthy(notified and notified:match("no query"))
    end)

    it("searches with regex and word flags from the flag line", function()
        write_file("a.txt", { "hit", "hitter" })
        assert.are.same({ "hit" }, panel_lines(assert(run("GreplaceEx --word -- hit"))))
        assert.are.same({ "hitter" },
            panel_lines(assert(run([[GreplaceEx --regex -- ^hit\w+$]]))))
    end)

    it("completes flag names and values, but not the query", function()
        local rgflags = require("greplace.rgflags")
        ---@param lead string
        ---@param line string  the command line, cursor at its end -- where
        ---                    `customlist` reports the whole line as written
        ---                    behind the cursor, not one past it
        local function complete(lead, line)
            return rgflags.complete(lead, line, #line)
        end

        -- One space along from the command, with nothing typed yet: the
        -- single space is all that separates the two, and it must survive.
        assert.is_truthy(vim.tbl_contains(
            vim.fn.getcompletion("GreplaceEx ", "cmdline"), "--hidden"))

        -- A flag name, whether or not a leading `-` has been typed.
        assert.are.same({ "--filter" }, complete("--fi", "GreplaceEx --fi"))
        assert.is_truthy(vim.tbl_contains(complete("", "GreplaceEx "), "--hidden"))

        -- A value: bare after `--type`, and carrying its flag back when glued.
        assert.is_truthy(vim.tbl_contains(complete("lu", "GreplaceEx --type lu"), "lua"))
        assert.are.same({ "--type=lua" }, complete("--type=lu", "GreplaceEx --type=lu"))

        -- A switch already written is not offered again; a repeatable flag is.
        local after = complete("--", "GreplaceEx --hidden --")
        assert.is_false(vim.tbl_contains(after, "--hidden"))
        assert.is_true(vim.tbl_contains(after, "--filter"))

        -- Past the separator the words are a query, not a list.
        assert.are.same({}, complete("h", "GreplaceEx -- h"))
    end)

    it("reports what is wrong with a flag line rather than searching", function()
        local rgflags = require("greplace.rgflags")
        ---@param raw string
        ---@return string
        local function err(raw)
            -- Split the way Neovim splits it before a command body ever sees
            -- it, so what is tested is what `:GreplaceEx` would parse.
            local fargs = vim.split(raw, "%s+", { trimempty = true })
            local parsed, e = rgflags.parse(fargs)
            assert.is_nil(parsed)
            return assert(e)
        end

        assert.is_truthy(err("--alpha"):match("no query"))
        assert.is_truthy(err("--bogus -- hit"):match("unknown flag: %-%-bogus"))
        assert.is_truthy(err("--regex=1 -- hit"):match("takes no value"))
        assert.is_truthy(err("--filter -- hit"):match("needs a glob"))
        assert.is_truthy(err("filter *.lua -- hit"):match("not a flag"))
    end)

    it("takes an escaped space in a `:Greplace` query", function()
        write_file("a.txt", { "two words here" })
        assert.are.same({ "two words here" },
            panel_lines(assert(run([[Greplace two\ words]]))))

        -- A query of nothing but a space is a query, not the empty line that
        -- cancels the search in flight.
        assert.are.same({ "two words here" }, panel_lines(assert(run([[Greplace \ ]]))))
    end)

    it("takes an escaped space, as `:h <f-args>` has it, on either side of `--`", function()
        write_file("my src/a.txt", { "two words here" })
        -- The flag value and the query are read the same way: both are words
        -- of Neovim's split, so both spell a space `\ `.
        local bufnr = assert(run([[GreplaceEx --dir my\ src -- two\ words]]))
        assert.are.same({ "two words here" }, panel_lines(bufnr))
    end)

    it("fills the panel from the quickfix list, line by line", function()
        write_file("a.txt", { "alpha one", "beta two" })
        write_file("b.txt", { "gamma three" })
        vim.fn.setqflist({
            { filename = _root .. "/a.txt", lnum = 2, col = 1, end_col = 5, text = "beta" },
            { filename = _root .. "/b.txt", lnum = 1, text = "whatever the producer wrote" },
        })

        -- Synchronous: there is no search to wait for.
        vim.cmd("GreplaceQf")
        local bufnr = assert(panel.find_buf())
        -- The entry's own `text` is ignored; the source line is read back.
        assert.are.same({ "beta two", "gamma three" }, panel_lines(bufnr))
    end)

    it("writes an edited quickfix panel back to the source lines", function()
        write_file("a.txt", { "alpha one" })
        vim.fn.setqflist({ { filename = _root .. "/a.txt", lnum = 1 } })
        vim.cmd("GreplaceQf")

        local bufnr = assert(panel.find_buf())
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha ONE" })
        vim.cmd("silent write")

        local target = assert(require("greplace.util").find_buf(_root .. "/a.txt"))
        assert.are.same({ "alpha ONE" }, vim.api.nvim_buf_get_lines(target, 0, -1, false))
    end)

    it("lists a line once however many quickfix entries point at it", function()
        write_file("a.txt", { "alpha alpha" })
        vim.fn.setqflist({
            { filename = _root .. "/a.txt", lnum = 1, col = 1, end_col = 6 },
            { filename = _root .. "/a.txt", lnum = 1, col = 7, end_col = 12 },
        })
        vim.cmd("GreplaceQf")
        assert.are.same({ "alpha alpha" }, panel_lines(assert(panel.find_buf())))
    end)

    it("says so when the quickfix list holds nothing it can edit", function()
        vim.fn.setqflist({})
        local notified
        local orig = vim.notify
        vim.notify = function(msg) notified = msg end
        vim.cmd("GreplaceQf")
        vim.notify = orig
        assert.is_truthy(notified and notified:match("no editable lines"))
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
