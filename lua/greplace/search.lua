local M = {}

local util = require("greplace.util")

-- ---------------------------------------------------------------------------
-- Search backend: one `rg --json` pass over the working tree, plus a second one
-- over the concatenated text of loaded buffers so unsaved edits are searched as
-- they currently stand. Disk matches for a path that is also open in a buffer
-- are dropped, so every match is reported against the text the replacement will
-- later be applied to.
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
---@field regex  boolean? treat the query as a regex instead of a literal
---@field limit  integer? stop collecting after this many matches

---@class greplace.OpenBuf
---@field bufnr integer
---@field path  string
---@field lines string[]

---@param line string
---@param root string
---@return greplace.Match?
local function parse_match(line, root)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or type(decoded) ~= "table" or decoded.type ~= "match" then return end

    local data = decoded.data
    local path = data.path and data.path.text
    if not path then return end

    local text = (data.lines.text or ""):gsub("\r?\n$", "")
    local subs = {}
    for _, sm in ipairs(data.submatches or {}) do
        subs[#subs + 1] = { s = sm.start, e = sm["end"] }
    end

    -- rg prints paths relative to its own cwd, which is the search root, not
    -- Neovim's.
    local abs = path
    if not vim.startswith(abs, "/") then
        abs = root .. "/" .. abs:gsub("^%./", "")
    end
    abs = vim.fs.normalize(abs)
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
    local args = { "rg", "--json", "--no-heading", "--smart-case" }
    if not opts.regex then
        table.insert(args, "--fixed-strings")
    end
    return args
end

--- Loaded, file-backed buffers under `root`, with their in-memory text.
---@param root string
---@return greplace.OpenBuf[]
function M.open_buffers(root)
    local out = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" then
                local path = util.resolve(name)
                if M.relative_path(path, root) ~= path then
                    out[#out + 1] = {
                        bufnr = bufnr,
                        path  = path,
                        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
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

---@param out    string
---@param root   string
---@param sink   fun(m:greplace.Match)
local function each_match(out, root, sink)
    for line in vim.gsplit(out or "", "\n", { trimempty = true }) do
        local m = parse_match(line, root)
        if m then sink(m) end
    end
end

--- Run both searches and hand the merged, path/line-sorted matches back.
---@param query    string
---@param opts     greplace.SearchOpts
---@param callback fun(matches:greplace.Match[]?, err:string?)
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
    local bufs  = M.open_buffers(root)
    local open  = {} ---@type table<string, greplace.OpenBuf>
    for _, b in ipairs(bufs) do open[b.path] = b end

    local matches = {} ---@type greplace.Match[]
    local pending = 2
    local errs    = {}

    local function done()
        pending = pending - 1
        if pending > 0 then return end
        if #matches == 0 and #errs > 0 then
            callback(nil, table.concat(errs, "; "))
            return
        end
        table.sort(matches, function(a, b)
            if a.relpath ~= b.relpath then return a.relpath < b.relpath end
            return a.lnum < b.lnum
        end)
        if opts.limit and #matches > opts.limit then
            matches = vim.list_slice(matches, 1, opts.limit)
        end
        callback(matches)
    end

    -- Disk pass.
    local dir_cmd = rg_base(opts)
    vim.list_extend(dir_cmd, { "--sort", "path", "--", query, "." })
    vim.system(dir_cmd, { cwd = root, text = true }, function(res)
        -- rg exits 1 when nothing matched, which is not an error here.
        if res.code > 1 then
            errs[#errs + 1] = vim.trim(res.stderr or "rg failed")
        end
        each_match(res.stdout, root, function(m)
            if not open[m.path] then matches[#matches + 1] = m end
        end)
        vim.schedule(done)
    end)

    -- Open-buffer pass: one process fed every buffer's current text.
    if #bufs == 0 then
        vim.schedule(done)
        return
    end

    local starts = line_offsets(bufs)
    local chunks = {}
    for _, b in ipairs(bufs) do
        chunks[#chunks + 1] = table.concat(b.lines, "\n")
    end

    local buf_cmd = rg_base(opts)
    vim.list_extend(buf_cmd, { "--", query, "-" })
    vim.system(buf_cmd, {
        cwd   = root,
        text  = true,
        stdin = table.concat(chunks, "\n"),
    }, function(res)
        if res.code > 1 then
            errs[#errs + 1] = vim.trim(res.stderr or "rg failed")
        end
        each_match(res.stdout, root, function(m)
            local b, lnum = locate(bufs, starts, m.lnum)
            if b and lnum then
                m.path    = b.path
                m.relpath = M.relative_path(b.path, root)
                m.lnum    = lnum
                m.bufnr   = b.bufnr
                matches[#matches + 1] = m
            end
        end)
        vim.schedule(done)
    end)
end

return M
