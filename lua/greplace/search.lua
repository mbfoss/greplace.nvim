local M = {}

local util  = require("greplace.util")
local spawn = require("greplace.util.spawn")
local rgflags = require("greplace.rgflags")

-- ---------------------------------------------------------------------------
-- Search backend: one `rg --json` pass over the working tree, plus a second one
-- over the concatenated text of the *modified* loaded buffers, so unsaved edits
-- are searched as they currently stand. Disk matches for a path that one of
-- those buffers holds are dropped, so every match is reported against the text
-- the replacement will later be applied to.
--
-- An unmodified buffer is left to the disk pass: its file says what it says.
-- It is still known to be open, so its matches carry the buffer number the
-- panel draws its indicator from.
-- ---------------------------------------------------------------------------

---@class greplace.Submatch
---@field s integer 0-indexed byte start in the line
---@field e integer 0-indexed byte end (exclusive) in the line

---@class greplace.Match
---@field path    string  absolute file path
---@field relpath string  path relative to the search root
---@field lnum    integer 1-indexed line number
---@field text    string  the matched line, verbatim
---@field subs    greplace.Submatch[]
---@field bufnr   integer? loaded buffer the match came from, if any

---@class greplace.SearchOpts
---@field cwd    string?  search root (default: current directory)
---@field limit  integer? stop collecting after this many matches
---@field flags  table?    `:Gsearch` flags (see `greplace.rgflags`): which
---                        files are searched, and what counts as a match

---@class greplace.OpenBuf
---@field bufnr    integer
---@field path     string
---@field modified boolean   the buffer holds edits the file on disk does not
---@field lines    string[]  the text, for a modified buffer only; else `{}`

--- The absolute, symlink-resolved path, as `util.resolve` spells it, so a
--- match and its buffer compare equal. `util.resolve` cannot run in this libuv
--- callback, hence `fs_realpath`, cached; `expand_env = false` for `$NAME`s.
---@param abs  string  absolute
---@param real table<string, string>  the search's cache
---@return string
local function resolve_path(abs, real)
    local hit = real[abs]
    if hit then return hit end
    local resolved = vim.fs.normalize(vim.uv.fs_realpath(abs) or abs,
        { expand_env = false })
    real[abs] = resolved
    return resolved
end

---@param line string
---@param root string
---@param real table<string, string>  realpath cache, shared across the search
---@return greplace.Match?
local function parse_match(line, root, real)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or type(decoded) ~= "table" or decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text
    if not path then return end

    -- A line rg could not decode as UTF-8 arrives as `bytes`, with no text to
    -- show or edit, so the match is dropped.
    local raw = data.lines and data.lines.text
    if type(raw) ~= "string" then return end

    local text = raw:gsub("\r?\n$", "")
    local len  = #text
    local subs = {}
    for _, sm in ipairs(data.submatches or {}) do
        -- Offsets index the line as rg read it, terminator included, so a
        -- match at the end (`$`) reaches past the text we kept. Clamp both.
        local s = math.max(0, math.min(tonumber(sm.start) or 0, len))
        local e = math.max(s, math.min(tonumber(sm["end"]) or 0, len))
        if e > s then subs[#subs + 1] = { s = s, e = e } end
    end

    -- rg prints paths relative to its own cwd, which is the search root, not
    -- Neovim's.
    local abs = path
    if not vim.startswith(abs, "/") then
        abs = root .. "/" .. abs:gsub("^%./", "")
    end
    abs = resolve_path(abs, real)
    return {
        path    = abs,
        relpath = M.relative_path(abs, root),
        lnum    = data.line_number,
        text    = text,
        subs    = subs,
    }
end

--- Search root: resolved once so rg output, buffer names and the root itself
--- are comparable as plain strings.
---@param cwd string?
---@return string
function M.resolve_root(cwd)
    return util.resolve(cwd or vim.uv.cwd() or ".")
end

---@param path string absolute
---@param root string absolute
---@return string
function M.relative_path(path, root)
    root = root:gsub("/$", "")
    if path:sub(1, #root + 1) == root .. "/" then
        return path:sub(#root + 2)
    end
    return path
end

---@param opts greplace.SearchOpts
---@return string[] args
local function rg_base(opts)
    -- `--no-config`: a shell's `$RIPGREP_CONFIG_PATH` would reach the disk
    -- pass but not `buffer_filter`, leaving the two passes inconsistent.
    local args = { "rg", "--no-config", "--json", "--no-heading" }
    -- `--max-count` is per file, not per search, so `M.run` still stops. It
    -- only keeps rg from decoding a huge file's hits before our count catches
    -- up; the buffer pass sees one stream, so the cap covers them all.
    if opts.limit then
        vim.list_extend(args, { "--max-count", tostring(opts.limit) })
    end
    -- Without flags this is a literal, smart-case search; any other rule comes
    -- through `:Gsearch` flags, which decide all of it themselves.
    if opts.flags then
        vim.list_extend(args, rgflags.match_args(opts.flags))
    else
        table.insert(args, "--smart-case")
        table.insert(args, "--fixed-strings")
    end
    return args
end

--- Loaded, file-backed buffers under `root`; `keep` stands in for the
--- file-selection flags rg cannot apply to this nameless stdin pass. Only
--- modified buffers are read: the disk pass covers the rest.
---@param root string
---@param keep (fun(relpath:string):boolean)?
---@return greplace.OpenBuf[]
function M.open_buffers(root, keep)
    local out = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path = util.resolve(name)
                local rel = M.relative_path(path, root)
                if rel ~= path and (not keep or keep(rel)) then
                    local modified = vim.bo[bufnr].modified
                    out[#out + 1] = {
                        bufnr    = bufnr,
                        path     = path,
                        modified = modified,
                        lines    = modified
                            and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                            or {},
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

--- Where each buffer starts in the concatenated stdin document. Buffer lines
--- never contain a newline, so the stream's line counter maps back exactly.
---@param bufs greplace.OpenBuf[]
---@return integer[] starts
local function line_offsets(bufs)
    local starts, at = {}, 1
    for i, b in ipairs(bufs) do
        starts[i] = at
        at = at + #b.lines
    end
    return starts
end

--- Resolve a stdin line number back to the buffer that contributed it.
---@param bufs   greplace.OpenBuf[]
---@param starts integer[]
---@param lnum   integer
---@return greplace.OpenBuf?, integer? local_lnum
local function locate(bufs, starts, lnum)
    local lo, hi, found = 1, #bufs, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if starts[mid] <= lnum then
            found, lo = mid, mid + 1
        else
            hi = mid - 1
        end
    end
    if not found then return end
    local b = bufs[found]
    local rel = lnum - starts[found] + 1
    if rel > #b.lines then return end
    return b, rel
end

--- Run one `rg --json` pass, feeding matches to `sink` as they are parsed.
--- rg's JSON output is one object per line, but pipe reads split anywhere, so
--- the trailing partial line is carried over to the next chunk.
---@param cmd   string[]
---@param root  string
---@param real  table<string, string>  the search's realpath cache
---@param stdin string?  text to feed rg's `-` target, if any
---@param sink  fun(m:greplace.Match)
---@param done  fun(err:string?)
---@return greplace.util.SpawnHandle?
local function rg_json(cmd, root, real, stdin, sink, done)
    local rest, errbuf = "", {}

    local function feed(chunk, last)
        rest = rest .. chunk
        local from = 1
        while true do
            local nl = rest:find("\n", from, true)
            if not nl then break end
            local m = parse_match(rest:sub(from, nl - 1), root, real)
            if m then sink(m) end
            from = nl + 1
        end
        rest = rest:sub(from)
        if last and rest ~= "" then
            local m = parse_match(rest, root, real)
            if m then sink(m) end
            rest = ""
        end
    end

    local handle, start_err
    handle, start_err = spawn(cmd, {
        cwd    = root,
        stdin  = stdin ~= nil,
        stdout = function(data) feed(data, false) end,
        stderr = function(data) errbuf[#errbuf + 1] = data end,
    }, function(code)
        feed("", true)
        -- Exit 1 means no matches, not an error. A negative code means the
        -- process never started, which must not read as "no matches".
        if code < 0 then
            done(("could not run %s in %s: %s")
                :format(cmd[1], root, start_err or "process did not start"))
        elseif code > 1 then
            local msg = vim.trim(table.concat(errbuf))
            done(msg ~= "" and msg or "rg failed")
        else
            done(nil)
        end
    end)

    if handle and stdin then handle.write(stdin, function() handle.write(nil) end) end
    return handle
end

--- Run both searches and hand the merged, path/line-sorted matches back.
--- Returns a `cancel` that kills both processes and suppresses `callback`, so
--- a newer search cannot be overwritten by an older one landing late.
---@param query    string
---@param opts     greplace.SearchOpts
---@param callback fun(matches:greplace.Match[]?, err:string?, truncated:boolean?)
---                  `truncated`: collection stopped at `limit`
---@return fun()? cancel  aborts both rg processes; nil if none were started
function M.run(query, opts, callback)
    if query == "" then
        callback(nil, "empty search query")
        return
    end
    if vim.fn.executable("rg") ~= 1 then
        callback(nil, "ripgrep (rg) not found on $PATH")
        return
    end

    local root  = M.resolve_root(opts.cwd)
    -- Always filtered, even with no flags: the default rg selection excludes
    -- hidden files, and the buffer pass must agree.
    local all   = M.open_buffers(root, rgflags.buffer_filter(opts.flags or {}))
    -- Only modified buffers are searched here; unmodified ones are covered by
    -- the disk pass. Every loaded buffer still supplies its bufnr, for the
    -- panel's indicator.
    local bufs   = {} ---@type greplace.OpenBuf[]
    local open   = {} ---@type table<string, greplace.OpenBuf>
    local loaded = {} ---@type table<string, integer>  path -> bufnr
    for _, b in ipairs(all) do
        loaded[b.path] = b.bufnr
        if b.modified then
            bufs[#bufs + 1] = b
            open[b.path]    = b
        end
    end

    local matches   = {} ---@type greplace.Match[]
    local pending   = 2
    local errs      = {}
    local cancelled = false
    local finished  = false
    local truncated = false
    local limit     = opts.limit

    local handles = {} ---@type greplace.util.SpawnHandle[]
    local real    = {} ---@type table<string, string>  resolved paths, per search
    local seen    = {} ---@type table<string, boolean>  path\0lnum already collected

    --- Collect one match and stop both processes once `limit` arrive. Sinks
    --- check `truncated` first, so the list never grows past it and a huge
    --- tree is never fully decoded and retained just to be sliced.
    ---@param m greplace.Match
    local function add(m)
        -- One line of one file is one match, however many ways it was reached
        -- (e.g. `--follow` via a symlink). Keyed on the resolved path, so both
        -- passes dedup; a duplicate would offer and apply the same edit twice.
        local key = m.path .. "\0" .. tostring(m.lnum)
        if seen[key] then return end
        seen[key] = true

        matches[#matches + 1] = m
        if limit and not truncated and #matches >= limit then
            truncated = true
            for _, h in ipairs(handles) do h.kill() end
        end
    end

    local function done()
        pending = pending - 1
        if pending > 0 or cancelled or finished then return end
        finished = true
        if #matches == 0 and #errs > 0 then
            callback(nil, table.concat(errs, "; "))
            return
        end
        table.sort(matches, function(a, b)
            if a.relpath ~= b.relpath then return a.relpath < b.relpath end
            return a.lnum < b.lnum
        end)
        callback(matches, nil, truncated)
    end

    local function on_pass_done(err)
        if cancelled then return end
        -- A pass we killed ourselves dies by SIGTERM; that is not a failure.
        if err and not truncated then errs[#errs + 1] = err end
        done()
    end

    -- Disk pass.
    local dir_cmd = rg_base(opts)
    if opts.flags then vim.list_extend(dir_cmd, rgflags.file_args(opts.flags)) end
    vim.list_extend(dir_cmd, { "--", query, "." })
    handles[#handles + 1] = rg_json(dir_cmd, root, real, nil, function(m)
        if not cancelled and not truncated and not open[m.path] then
            m.bufnr = loaded[m.path]
            add(m)
        end
    end, on_pass_done)

    -- Open-buffer pass: one process fed every buffer's current text.
    if #bufs == 0 then
        vim.schedule(done)
    else
        local starts = line_offsets(bufs)
        local chunks = {}
        for _, b in ipairs(bufs) do
            chunks[#chunks + 1] = table.concat(b.lines, "\n")
        end

        local buf_cmd = rg_base(opts)
        vim.list_extend(buf_cmd, { "--", query, "-" })
        handles[#handles + 1] = rg_json(buf_cmd, root, real, table.concat(chunks, "\n"), function(m)
            if cancelled or truncated then return end
            local b, lnum = locate(bufs, starts, m.lnum)
            if b and lnum then
                m.path    = b.path
                m.relpath = M.relative_path(b.path, root)
                m.lnum    = lnum
                m.bufnr   = b.bufnr
                add(m)
            end
        end, on_pass_done)
    end

    --- Abort both passes without reporting anything.
    return function()
        if cancelled or finished then return end
        cancelled = true
        for _, h in ipairs(handles) do h.kill() end
        handles = {}
    end

end

return M
