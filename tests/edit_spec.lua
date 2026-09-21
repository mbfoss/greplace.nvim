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
        vim.api.nvim_echo = function(chunks)
            table.insert(_G.notes, table.concat(vim.tbl_map(function(c) return c[1] end, chunks)))
        end
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
            local virt = not m[4].invalid and m[4].virt_text
            if virt then out = out .. virt[#virt - 1][1] end
        end
        return out
    ]])
end

--- How many watches the panel has on its lines. Each one counts a change of
--- its own, so a single edit is counted once per watch.
---@return integer
function Child:watches()
    return self:lua([[
        local buf = vim.api.nvim_get_current_buf()
        local st  = require("greplace.panel").state(buf)
        st.ticks = 0
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "probe" })
        return st.ticks
    ]])
end

--- Each anchor's row and column, and the location it draws, in buffer order:
--- `"0,0 a.txt:1"`. An anchor whose line was removed is invalid -- it draws
--- nothing wherever it sits -- and reads as `false`.
---@return string[]
function Child:anchors()
    return self:lua([[
        local ns  = vim.api.nvim_get_namespaces()["greplace.anchor"]
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
            local virt = not m[4].invalid and m[4].virt_text
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

    it("joins a line split by a substitution back up", function()
        child:open({ "a-b", "c-d" })
        child:feed(":%s/-/\\r/<CR>")
        -- The break goes; what the substitution took out with it does not
        -- come back, the marks saying where a line was split and nothing
        -- about what it held.
        assert.same({ "ab", "cd" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2" }, child:anchors())
    end)

    it("puts a line broken in Insert mode back together", function()
        child:open({ "hello world", "two" })
        child:feed("gg05li<CR>")
        assert.same({ "hello world", "two" }, child:lines())
        -- Typing carries on from where the break was.
        child:feed(",<Esc>")
        assert.same({ "hello, world", "two" }, child:lines())
    end)

    it("keeps the leading white space of a line broken at its start with 'autoindent'", function()
        child:lua("vim.o.autoindent = true; vim.o.smartindent = true")
        child:open({ "    foo", "  bar" })
        child:feed("gg0i<CR>")
        assert.same({ 1, 0 }, child:cursor())
        child:feed("<Esc>")
        assert.same({ "    foo", "  bar" }, child:lines())
        child:feed("u")
        assert.same({ "    foo", "  bar" }, child:lines())
        child:feed("<C-r>")
        assert.same({ "    foo", "  bar" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2" }, child:anchors())
    end)

    it("keeps the leading white space of a comment line broken at its start", function()
        child:lua("vim.o.formatoptions = vim.o.formatoptions .. 'ro'")
        child:open({ "    # foo", "  bar" })
        child:feed("gg0i<CR><Esc>")
        assert.same({ "    # foo", "  bar" }, child:lines())
    end)

    it("takes back a line opened in Insert mode, and lets typing go on", function()
        child:open({ "one", "two" })
        child:feed("ggo")
        assert.same({ "one", "two" }, child:lines())
        -- `o` opens the new line in front of the next one, taking its anchor;
        -- the cursor is left where that break was.
        assert.same({ 2, 0 }, child:cursor())
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

    it("takes a repaired change back out again when it is redone", function()
        child:open({ "one", "two" })
        child:feed("yyp")
        child:feed("<C-r>")
        assert.same({ "one", "two" }, child:lines())
    end)

    it("walks undo and redo across a repaired join without branching", function()
        child:open({ "one", "two", "three" })
        child:feed("ggcwA<Esc>")
        child:feed("ggJ")
        child:feed("3GcwB<Esc>")
        child:feed("uuu")
        child:feed("<C-r><C-r><C-r>")
        assert.same({ "A", "two", "B" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        child:feed("uu")
        assert.same({ "A", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        assert.same({ 1, 3 }, child:lua([[
            local t = vim.fn.undotree()
            return { t.seq_cur, t.seq_last }
        ]]))
        assert.equals(1, #child:notes())
    end)

    it("keeps a removed line hidden when redoing across a repaired join", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        child:feed("ggJ")
        child:feed("uu")
        child:feed("<C-r><C-r>")
        assert.same({ "one", "three" }, child:lines())
        -- The removed match's anchor draws nothing and owns no row; it
        -- sits wherever the text it was on went.
        assert.same({ "0,0 a.txt:1", "0,3 false", "1,0 a.txt:3" }, child:anchors())
        assert.equals(1, #child:notes())
    end)

    it("puts back only the rows near a repaired change, and all of them right", function()
        local texts = {}
        for i = 1, 40 do texts[i] = ("line %02d"):format(i) end
        -- Every anchor that still stands where a layout of the whole list
        -- would put it: the matches with a line, one per row, in listing
        -- order. A removed match's anchor is invalid and owns no row.
        local misplaced = [[
            local buf = vim.api.nvim_get_current_buf()
            local st  = require("greplace.panel").state(buf)
            local ns  = vim.api.nvim_get_namespaces()["greplace.anchor"]
            local rows, row = {}, 0
            for _, id in ipairs(st.order) do
                local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
                if not m[3].invalid then rows[id], row = row, row + 1 end
            end
            local bad = 0
            for id, want in pairs(rows) do
                local p = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
                if p[1] ~= want or p[2] ~= 0 then bad = bad + 1 end
            end
            return bad
        ]]
        child:open(texts)
        child:lua([[
            local set = vim.api.nvim_buf_set_extmark
            _G.sets = 0
            vim.api.nvim_buf_set_extmark = function(...) _G.sets = _G.sets + 1; return set(...) end
        ]])
        for _, keys in ipairs({ "5Gdd", "10Gdd", "4G8J", "20G5dd", "18G0lv4jd", "GoX<Esc>", "ggOX<Esc>" }) do
            child:lua("_G.sets = 0")
            child:feed(keys)
            assert.equals(0, child:lua(misplaced), keys)
            assert.is_true(child:lua("return _G.sets") < 20,
                keys .. ": " .. child:lua("return _G.sets"))
        end
    end)

    it("takes back a join", function()
        child:open({ "one", "two", "three" })
        child:feed("ggJ")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        assert.equals(1, #child:notes())
    end)

    it("splits a charwise delete across a line break back apart", function()
        child:open({ "one", "two", "three" })
        -- The text the delete took goes; the line break it took with it is
        -- put back, so the two matches have a line each again.
        child:feed("gg0lvjd")
        assert.same({ "o", "o", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        assert.equals(1, #child:notes())
    end)

    it("drops a match whose line a substitution consumed whole", function()
        child:open({ "one", "two", "three" })
        -- Each line's text and the break after it: there is no line left for
        -- either match to stand on, which is how a match is removed.
        child:feed(":%s/\\v(one|two)\\n//<CR>")
        assert.same({ "three" }, child:lines())
        assert.same({ "0,0 false", "0,0 false", "0,0 a.txt:3" }, child:anchors())
    end)

    it("takes back a join across a removed line", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        child:feed("ggJ")
        assert.same({ "one", "three" }, child:lines())
        -- The removed match's anchor draws nothing and owns no row; it
        -- sits wherever the text it was on went.
        assert.same({ "0,0 a.txt:1", "0,3 false", "1,0 a.txt:3" }, child:anchors())
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
        -- The removed match's anchor draws nothing and owns no row; it
        -- sits wherever the text it was on went.
        assert.same({ "0,0 a.txt:1", "0,3 false", "1,0 a.txt:3" }, child:anchors())
    end)

    it("keeps the edits made before the line that was taken back", function()
        child:open({ "one", "two" })
        child:feed("ggAX<Esc>")
        child:feed("jAY<Esc>")
        child:feed("yyp")
        assert.same({ "oneX", "twoY" }, child:lines())
    end)

    it("keeps two ordinary edits in undo steps of their own", function()
        child:open({ "one", "two" })
        child:feed("ggAX<Esc>")
        child:feed("jAY<Esc>")
        -- Nothing was put back, so nothing joined the two changes: `u` takes
        -- back the second edit alone.
        child:feed("u")
        assert.same({ "oneX", "two" }, child:lines())
    end)

    it("walks several undos and redos at once", function()
        child:open({ "one", "two", "three" })
        child:feed("ggcwA<Esc>")
        child:feed("ggJ")
        child:feed("3GcwB<Esc>")
        -- All of them replayed before the panel gets a look in, which is what
        -- `3u` or a held-down `u` does: the marks of the rows they touch are
        -- piled onto one row, and are laid out from the listing again.
        child:feed("uuu")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        child:feed("<C-r><C-r><C-r>")
        assert.same({ "A", "two", "B" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
    end)

    it("keeps a removed line removed across several redos at once", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        child:feed("ggJ")
        child:feed("uu")
        assert.same({ "one", "two", "three" }, child:lines())
        child:feed("<C-r><C-r>")
        assert.same({ "one", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "0,3 false", "1,0 a.txt:3" }, child:anchors())
    end)

    it("still lets a deleted line be undone", function()
        child:open({ "one", "two", "three" })
        child:feed("jdd")
        assert.same({ "one", "three" }, child:lines())
        child:feed("u")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({}, child:notes())
    end)

    it("refills the list from the stored lines when reloaded, dropping edits", function()
        child:open({ "one", "two", "three" })
        child:feed("jAX<Esc>")
        -- An unwritten edit stands in the way of a plain `:edit`.
        assert.is_true(child:lua("return vim.bo.modified"))
        assert.is_false(child:lua("return pcall(vim.cmd, 'edit')"))
        assert.same({ "one", "twoX", "three" }, child:lines())

        child:feed(":edit!<CR>")
        assert.same({ "one", "two", "three" }, child:lines())
        assert.same({ "0,0 a.txt:1", "1,0 a.txt:2", "2,0 a.txt:3" }, child:anchors())
        assert.is_true(child:lua(
            "return require('greplace.panel').is_panel(vim.api.nvim_get_current_buf())"))
        assert.is_false(child:lua("return vim.bo.modified"))
        assert.is_true(child:lua("return vim.wo.winbar ~= ''"))
    end)

    it("can be shown again after a reload left it with no list", function()
        local buf = child:lua([[
            local panel = require("greplace.panel")
            local buf = panel.open_loading({
                query = "q", root = "/x", height = 10, on_write = function() end,
            })
            vim.cmd("edit!")
            vim.cmd("new")
            panel.close(buf)
            return buf
        ]])
        assert.is_true(child:lua("return (pcall(require('greplace.panel').show, (...), 10))", buf))
    end)

    it("drops a stale status message when the list is drawn again", function()
        child:open({ "one", "two" })
        child:lua("require('greplace.panel').state(vim.api.nvim_get_current_buf()).message = 'render failed: x'")
        child:feed(":edit!<CR>")
        assert.same({ "one", "two" }, child:lines())
        assert.is_true(child:lua(
            "return require('greplace.panel').state(vim.api.nvim_get_current_buf()).message == nil"))
        assert.is_false(child:lua("return vim.wo.winbar:find('render failed', 1, true) ~= nil"))
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

    it("steps between the edited lines with ]c and [c", function()
        child:open({ "one", "two", "three", "four", "five" })
        child:feed("jAX<Esc>")   -- line 2
        child:feed("3jAY<Esc>")  -- line 5
        assert.equals(" •  •", child:markers())

        child:feed("gg0]c")
        assert.same({ 2, 0 }, child:cursor())
        -- Off the edit it is sitting on, not stuck on it.
        child:feed("]c")
        assert.same({ 5, 0 }, child:cursor())
        child:feed("[c")
        assert.same({ 2, 0 }, child:cursor())
        -- And back to where the stepping began.
        child:feed("''")
        assert.same({ 5, 0 }, child:cursor())
    end)

    it("takes a count on ]c, stopping at the last edit", function()
        child:open({ "one", "two", "three", "four", "five" })
        child:feed("jAX<Esc>")
        child:feed("jAY<Esc>")
        child:feed("jAZ<Esc>")
        child:feed("gg02]c")
        assert.same({ 3, 0 }, child:cursor())
        -- More edits asked for than there are left: the last one, rather than
        -- nowhere at all.
        child:feed("gg09]c")
        assert.same({ 4, 0 }, child:cursor())
    end)

    it("says so when there is no edit to step to", function()
        child:open({ "one", "two", "three" })
        child:feed("gg0]c")
        assert.same({ 1, 0 }, child:cursor())
        assert.same({ "greplace: nothing has been edited" }, child:notes())

        child:feed("jAX<Esc>")
        -- Past the only edit there is, in both directions: the cursor stays
        -- where it was rather than being taken to the end of the list.
        child:feed("]c")
        assert.same({ 2, 3 }, child:cursor())
        child:feed("gg0[c")
        assert.same({ 1, 0 }, child:cursor())
        assert.same({
            "greplace: nothing has been edited",
            "greplace: no more edits",
            "greplace: no more edits",
        }, child:notes())
    end)

    it("counts an edited row once when a deleted line shares it", function()
        child:open({ "one", "two", "three", "four", "five" })
        child:feed("jAX<Esc>")   -- line 2
        child:feed("GAY<Esc>")   -- line 5
        -- Line 4 goes, leaving its anchor on the row line 5 now occupies: two
        -- anchors on one edited row, which is still one edit to step to.
        child:feed("3Gjdd")
        assert.same({ "one", "twoX", "three", "fiveY" }, child:lines())
        child:feed("gg02]c")
        assert.same({ 4, 0 }, child:cursor())
        child:feed("2[c")
        assert.same({ 2, 0 }, child:cursor())
    end)

    it("forgets an edit that has been undone", function()
        child:open({ "one", "two", "three" })
        child:feed("jAX<Esc>")
        child:feed("u")
        child:feed("gg0]c")
        assert.same({ 1, 0 }, child:cursor())
        assert.same({ "greplace: nothing has been edited" }, child:notes())
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
