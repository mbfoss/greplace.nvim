-- Editing the panel with real keystrokes.
--
-- The panel checks an edit from a `vim.schedule` callback, which runs from
-- Neovim's own main loop, and it is typed input that sets off the edits under
-- test; a spec run through `nvim -l` has neither. So these drive a second, embedded Neovim
-- with typed input instead, and read the panel back out of it.

local _root = vim.uv.cwd()

---@class Child
---@field chan integer
local Child = {}
Child.__index = Child

---@return Child
local function spawn()
    local chan = vim.fn.jobstart({
        vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n",
    }, { rpc = true })
    assert(chan > 0, "cannot start an embedded Neovim")
    local self = setmetatable({ chan = chan }, Child)
    self:lua([[
        local root = ...
        vim.opt.runtimepath:prepend(root)
        package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
        -- Warnings are collected rather than drawn, for the specs to read.
        _G.notes = {}
        vim.notify = function(msg) table.insert(_G.notes, msg) end
    ]], _root)
    return self
end

---@param code string
---@param ... any
function Child:lua(code, ...)
    return vim.rpcrequest(self.chan, "nvim_exec_lua", code, { ... })
end

--- Open a panel on `texts`, one match per line of `a.txt`.
---@param texts string[]
---@return integer bufnr  in the child
function Child:open(texts)
    return self:lua([[
        local matches = {}
        for i, text in ipairs(...) do
            matches[i] = { path = "/x/a.txt", relpath = "a.txt", lnum = i, text = text, subs = {} }
        end
        return require("greplace.panel").open(matches, {
            query = "q", root = "/x", height = 10, on_write = function() end,
        })
    ]], texts)
end

--- Type `keys`, then give the child's main loop a moment to run the autocmds
--- and scheduled redraws they set off.
---@param keys string
function Child:feed(keys)
    vim.rpcrequest(self.chan, "nvim_input", keys)
    -- A request is only served once the typed input has been, so this one
    -- returns after the keys; the wait covers the redraw scheduled behind them.
    vim.rpcrequest(self.chan, "nvim_eval", "1")
    vim.wait(50, function() return false end)
    vim.rpcrequest(self.chan, "nvim_eval", "1")
end

---@return string[]
function Child:lines()
    return self:lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
end

--- Which rows carry the changed marker in front of their `│`: `"•"`, or `" "`
--- for one that does not.
---@return string
function Child:markers()
    return self:lua([[
        local ns  = vim.api.nvim_get_namespaces()["greplace.anchor"]
        local out = ""
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
            local virt = m[4].virt_text
            if virt then out = out .. virt[#virt - 1][1] end
        end
        return out
    ]])
end

--- How many watches the panel has on its lines. Each one records a change of
--- its own, and the pass that clears the record is scheduled, so it cannot run
--- before this returns: the changes a single edit leaves behind are one per
--- watch.
---@return integer
function Child:watches()
    return self:lua([[
        local buf = vim.api.nvim_get_current_buf()
        local st  = require("greplace.panel").state(buf)
        st.changes = {}
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "probe" })
        return #st.changes
    ]])
end

--- Each anchor's row and column, and the location it draws (`false` for one
--- whose line was removed), in buffer order: `"0,0 a.txt:1"`.
---@return string[]
function Child:anchors()
    return self:lua([[
        local ns  = vim.api.nvim_get_namespaces()["greplace.anchor"]
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
            local virt = m[4].virt_text
            out[#out + 1] = ("%d,%d %s"):format(m[2], m[3], virt and virt[#virt - 3][1] or "false")
        end
        return out
    ]])
end

---@return integer[]
function Child:cursor()
    return self:lua("return vim.api.nvim_win_get_cursor(0)")
end

---@return string[]
function Child:notes()
    return self:lua("return _G.notes")
end

function Child:close()
    vim.fn.jobstop(self.chan)
end

describe("panel editing", function()
    local child ---@type Child

    before_each(function() child = spawn() end)
    after_each(function() child:close() end)

    it("takes back a line opened below a match", function()
        child:open({ "one", "two" })
        child:feed("ggoextra<Esc>")
        assert.same({ "one", "two" }, child:lines())
        assert.equals(1, #child:notes())
    end)

    it("takes back a linewise put", function()
        child:open({ "one", "two" })
        child:feed("yyjp")
        assert.same({ "one", "two" }, child:lines())
    end)

    it("takes back a substitution that splits a line", function()
        child:open({ "a-b", "c-d" })
        child:feed(":%s/-/\\r/<CR>")
        assert.same({ "a-b", "c-d" }, child:lines())
    end)

    it("puts a line broken in Insert mode back together", function()
        child:open({ "hello world", "two" })
        child:feed("gg05li<CR>")
        assert.same({ "hello world", "two" }, child:lines())
        -- Typing carries on from where the break was.
        child:feed(",<Esc>")
        assert.same({ "hello, world", "two" }, child:lines())
    end)

    it("takes back a line opened in Insert mode, and lets typing go on", function()
        child:open({ "one", "two" })
        child:feed("ggo")
        assert.same({ "one", "two" }, child:lines())
        -- `o` opens the new line in front of the next one, taking its anchor;
        -- the cursor is left where that break was.
        child:feed("X<Esc>")
        assert.same({ "one", "Xtwo" }, child:lines())
    end)

    it("takes back a line opened above the first match", function()
        child:open({ "one", "two" })
        child:feed("ggOabove<Esc>")
        assert.same({ "one", "two" }, child:lines())
        -- The anchor still starts the line it belongs to.
        assert.equals(0, child:lua([[
            local ns = vim.api.nvim_get_namespaces()["greplace.anchor"]
            return vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})[1][3]
        ]]))
    end)

    it("takes a reverted change back again when it is redone", function()
        child:open({ "one", "two" })
        child:feed("yyp")
        child:feed("<C-r>")
        assert.same({ "one", "two" }, child:lines())
    end)

    it("takes back a join", function()
        child:open({ "one", "two", "three" })
        child:feed("ggJ")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        assert.equals(1, #child:notes())
    end)

    it("takes back a charwise delete across a line break", function()
        child:open({ "one", "two", "three" })
        child:feed("gg0lvjd")
        assert.same({ "one", "two", "three" }, child:lines())
        child:feed(":%s/o\\n//<CR>")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        assert.equals(2, #child:notes())
    end)

    it("takes back a join across a removed line", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        child:feed("ggJ")
        assert.same({ "one", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 false", "1,0 a.txt:3" }, child:anchors())
    end)

    it("still lets the last line be deleted", function()
        child:open({ "one", "two" })
        child:feed("Gdd")
        assert.same({ "one" }, child:lines())
        assert.same({}, child:notes())
    end)

    it("splits a line joined by <BS> in Insert mode back apart", function()
        child:open({ "one", "two", "three" })
        child:feed("jI<BS>")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        -- The cursor is back at the start of the line it was on.
        assert.same({ 2, 0 }, child:cursor())
        child:feed("X<Esc>")
        assert.same({ "one", "Xtwo", "three" }, child:lines())
    end)

    it("splits a line joined by <Del> in Insert mode back apart", function()
        child:open({ "one", "two" })
        child:feed("ggA<Del><Esc>")
        assert.same({ "one", "two" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2" }, child:anchors())
    end)

    it("rebuilds an Insert-mode join across a removed line", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        child:feed("I<BS><Esc>")
        assert.same({ "one", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 false", "1,0 a.txt:3" }, child:anchors())
    end)

    it("keeps the edits made before the line that was taken back", function()
        child:open({ "one", "two" })
        child:feed("ggAX<Esc>")
        child:feed("jAY<Esc>")
        child:feed("yyp")
        assert.same({ "oneX", "twoY" }, child:lines())
    end)

    it("still lets a deleted line be undone", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        assert.same({ "one", "three" }, child:lines())
        child:feed("u")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({}, child:notes())
    end)

    it("leaves nothing of the old list behind when reloaded", function()
        child:open({ "one", "two", "three" })
        child:feed("jAX<Esc>")
        -- The panel is not a file: there is nothing to reload it from, and an
        -- unwritten edit stands in the way of throwing the list away.
        assert.is_true(child:lua("return vim.bo.modified"))
        assert.is_false(child:lua("return pcall(vim.cmd, 'edit')"))
        assert.same({ "one", "twoX", "three" }, child:lines())

        child:feed(":edit!<CR>")
        assert.same({ "" }, child:lines())
        assert.same({}, child:anchors())
        assert.is_false(child:lua("return require('greplace.panel').is_panel(0)"))
        assert.equals("", child:lua("return vim.wo.winbar"))
        -- And a write of what is left replaces nothing.
        child:feed(":write<CR>")
        assert.same({}, child:notes())
        assert.is_false(child:lua("return vim.bo.modified"))
    end)

    it("takes a new list in a reloaded panel", function()
        local buf = child:open({ "one", "two" })
        child:feed(":edit!<CR>")
        assert.equals(buf, child:open({ "one", "two", "three" }))
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
    end)

    it("still watches the lines of a reloaded panel", function()
        child:open({ "one", "two" })
        child:feed(":edit!<CR>")
        -- The reload empties the buffer, which is a change like any other:
        -- whatever it does to the watch on the lines, the second list is
        -- edited under the same rules as the first.
        child:open({ "one", "two", "three" })
        child:feed("jAX<Esc>")
        assert.same({ "one", "twoX", "three" }, child:lines())
        assert.equals(" • ", child:markers())
        child:feed("dd")
        assert.same({ "one", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 false", "1,0 a.txt:3" }, child:anchors())
        child:feed("u")
        assert.same({ "one", "twoX", "three" }, child:lines())
    end)

    it("watches a reloaded panel once, not twice", function()
        child:open({ "one", "two" })
        assert.equals(1, child:watches())
        -- The reload detaches the watch and puts a new one in its place; the
        -- one it detached must not come back with it. Two would record --
        -- and act on -- every edit twice over.
        child:feed(":edit!<CR>")
        child:open({ "one", "two", "three" })
        assert.equals(1, child:watches())
    end)

    it("does not ask to save unapplied edits on the way out", function()
        child:open({ "one", "two" })
        child:feed("AX<Esc>")
        assert.is_true(child:lua("return vim.bo.modified"))
        -- A prompt (or E37) would leave the child running instead.
        vim.rpcnotify(child.chan, "nvim_input", ":qall<CR>")
        assert.same({ 0 }, vim.fn.jobwait({ child.chan }, 5000))
    end)

    it("marks the lines that have been changed", function()
        child:open({ "one", "two", "three" })
        assert.equals("   ", child:markers())
        child:feed("jAX<Esc>")
        assert.equals(" • ", child:markers())
        -- The mark goes with its line, and comes back with it.
        child:feed("dd")
        assert.equals("  ", child:markers())
        child:feed("u")
        assert.equals(" • ", child:markers())
        -- Edited back to what it was, the line is no longer a change.
        child:feed("u")
        assert.equals("   ", child:markers())
    end)
end)
