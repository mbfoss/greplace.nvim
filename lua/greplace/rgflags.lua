local M = {}

-- ---------------------------------------------------------------------------
-- `:GreplaceEx`'s flags: the schema, what each one means to ripgrep, and the
-- part of it that ripgrep cannot be told at all.
--
-- The search runs twice -- once over the working tree, once over the
-- concatenated text of open buffers fed to `rg -` -- and a file-selection flag
-- only reaches the first of those: rg sees the buffer pass as one nameless
-- stream, so `-g` and `--type` have nothing to filter there. Left at that, a
-- `--filter *.lua` search would skip `.md` files on disk and then report
-- matches from the `.md` you happen to have open. So the same globs are
-- compiled here and applied to the buffer list before the stream is built, and
-- rg's own file types are read once (`rg --type-list`) so `--type lua` can be
-- matched the same way on both sides.
--
-- Flags that would break the panel's contract -- that a shown line is the
-- source line, byte for byte -- are not in the schema and cannot be smuggled
-- in: there is no passthrough of raw rg arguments, only these names.
-- `--replace` and `--only-matching` rewrite the line, `-l`/`--count` report no
-- lines at all, and `-A/-B/-C` emit context the panel has no anchor for.
-- ---------------------------------------------------------------------------

local strutil    = require("greplace.util.strutil")
local usercmd    = require("greplace.util.usercmd")

--- rg's file types (`rg --type-list`), parsed once per session:
--- `{ lua = { "*.lua" }, … }`.
---@type table<string, string[]>?
local _rg_types

---@return table<string, string[]>
local function rg_types()
    if _rg_types then return _rg_types end

    local types = {}
    if vim.fn.executable("rg") == 1 then
        local res = vim.system({ "rg", "--type-list" }, { text = true }):wait()
        if res.code == 0 then
            for line in vim.gsplit(res.stdout or "", "\n", { trimempty = true }) do
                local name, globs = line:match("^([^:]+):%s*(.+)$")
                if name then
                    local list = {}
                    for g in vim.gsplit(globs, ",", { trimempty = true }) do
                        list[#list + 1] = vim.trim(g)
                    end
                    types[name] = list
                end
            end
        end
    end

    _rg_types = types
    return types
end

---@param partial string
---@return string[]
local function complete_type(partial)
    local names = vim.tbl_keys(rg_types())
    table.sort(names)
    return vim.tbl_filter(function(n) return vim.startswith(n, partial) end, names)
end

---A flag's completion source: a `vim.fn.getcompletion()` type ("dir", "file")
---or a function returning the candidates for what has been typed so far.
---@alias greplace.rgflags.CompleteSpec string|fun(partial:string):string[]

---@class greplace.rgflags.FlagDef
---@field name     string   written as `--name`
---@field arg      string?  what its value stands for, shown as `--name <arg>`;
---                         nil for a switch, which takes no value
---@field multi    boolean? the flag may be repeated, and the values collect
---@field complete greplace.rgflags.CompleteSpec?
---@field desc     string

---@type greplace.rgflags.FlagDef[]
M.FLAGS = {
    { name = "dir",       arg = "path", complete = "dir", desc = "search root directory" },
    { name = "filter",    arg = "glob", multi = true, desc = "glob filter, repeatable: *.txt, !*.lua, **/dir/**" },
    { name = "type",      arg = "name", multi = true, complete = complete_type, desc = "rg file type, repeatable: lua, rust, !md (rg --type-list)" },
    { name = "max-depth", arg = "n", desc = "max directory depth to descend" },
    { name = "regex",     desc = "treat the query as a regex" },
    { name = "case",      desc = "case-sensitive (default: smart case)" },
    { name = "nocase",    desc = "case-insensitive (default: smart case)" },
    { name = "word",      desc = "match whole words only" },
    { name = "line",      desc = "match whole lines only" },
    { name = "invert",    desc = "collect lines that do NOT match" },
    { name = "follow",    desc = "follow symlinks" },
    { name = "hidden",    desc = "include hidden (dotfiles)" },
    { name = "no-ignore", desc = "disable .gitignore / .ignore rules" },
}

---@type table<string, greplace.rgflags.FlagDef>
local _by_name = {}
for _, def in ipairs(M.FLAGS) do _by_name[def.name] = def end

---A parsed flag line. The keys are the flags' own names, hyphens included, so
---the two hyphenated ones are read as `flags["no-ignore"]`.
---@class greplace.RgFlags
---@field dir       string?
---@field filter    string[]?
---@field type      string[]?
---@field max-depth string?
---@field regex     boolean?
---@field case      boolean?
---@field nocase    boolean?
---@field word      boolean?
---@field line      boolean?
---@field invert    boolean?
---@field follow    boolean?
---@field hidden    boolean?
---@field no-ignore boolean?

--- rg arguments common to both passes: everything that decides what counts as a
--- match, and nothing that decides which files are looked at (those differ --
--- the buffer pass has no files).
---@param flags table
---@return string[] args
function M.match_args(flags)
    local args = {}

    if flags.case then
        args[#args + 1] = "--case-sensitive"
    elseif flags.nocase then
        args[#args + 1] = "--ignore-case"
    else
        args[#args + 1] = "--smart-case"
    end
    if not flags.regex then args[#args + 1] = "--fixed-strings" end
    if flags.word then args[#args + 1] = "--word-regexp" end
    if flags.line then args[#args + 1] = "--line-regexp" end
    if flags.invert then args[#args + 1] = "--invert-match" end

    return args
end

--- rg arguments for the disk pass alone: which files it walks.
---@param flags table
---@return string[] args
function M.file_args(flags)
    local args = { "--glob-case-insensitive" }

    if flags.follow then args[#args + 1] = "--follow" end
    if flags.hidden then args[#args + 1] = "--hidden" end
    if flags["no-ignore"] then args[#args + 1] = "--no-ignore" end

    for _, g in ipairs(flags.filter or {}) do
        args[#args + 1] = "-g"
        args[#args + 1] = g
    end
    for _, t in ipairs(flags.type or {}) do
        if t:sub(1, 1) == "!" then
            args[#args + 1] = "--type-not"
            args[#args + 1] = t:sub(2)
        else
            args[#args + 1] = "--type"
            args[#args + 1] = t
        end
    end
    local depth = tonumber(flags["max-depth"])
    if depth then
        args[#args + 1] = "--max-depth"
        args[#args + 1] = tostring(math.floor(depth))
    end

    return args
end

--- Compile a glob list, dropping any that fail to compile.
---@param globs string[]
---@return vim.regex[]?  nil when none compiled, so a bad glob filters nothing
local function compile_globs(globs)
    local out = {}
    for _, g in ipairs(globs) do
        local re = strutil.compile_glob(g)
        if re then out[#out + 1] = re end
    end
    return #out > 0 and out or nil
end

--- Split a `filter` list ("*.lua", "!*_spec.lua") into compiled include and
--- exclude regexes, for the buffer pass rg's own `-g` cannot reach.
---@param filters string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_filter_globs(filters)
    local include, exclude = {}, {}
    for _, g in ipairs(filters or {}) do
        if g:sub(1, 1) == "!" then
            exclude[#exclude + 1] = g:sub(2)
        else
            include[#include + 1] = g
        end
    end
    return compile_globs(include), compile_globs(exclude)
end

--- The same for `type`: rg's `-t` filters the files it walks, not stdin, so the
--- type's globs are expanded here and matched against each buffer's basename
--- (which is how rg matches a slashless type glob itself).
---@param types string[]?
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_type_globs(types)
    if not types or #types == 0 then return nil, nil end

    local known = rg_types()
    local include, exclude = {}, {}
    for _, t in ipairs(types) do
        local negated = t:sub(1, 1) == "!"
        local name    = negated and t:sub(2) or t
        local target  = negated and exclude or include
        for _, g in ipairs(known[name] or {}) do
            target[#target + 1] = g
        end
    end
    return compile_globs(include), compile_globs(exclude)
end

--- A predicate over root-relative paths standing for the file-selection flags,
--- for filtering open buffers the way rg filters the working tree. Compiling
--- the globs once per search rather than once per buffer is the point of
--- handing back a closure.
---@param flags table
---@return fun(relpath:string):boolean
function M.buffer_filter(flags)
    local include, exclude           = compile_filter_globs(flags.filter)
    local type_include, type_exclude = compile_type_globs(flags.type)
    local max_depth                  = tonumber(flags["max-depth"])

    return function(relpath)
        local base = vim.fs.basename(relpath)
        return strutil.check_path_pattern(relpath, false, include, exclude)
            and strutil.check_path_pattern(base, false, type_include, type_exclude)
            and (not max_depth or select(2, relpath:gsub("/", "")) < max_depth)
    end
end

--- Read a `:GreplaceEx` command line: the flags up to the first bare `--`,
--- then the query. The whole line is read from the split Neovim already did
--- for us, flags and query alike, so one escaping rule covers both -- the one
--- `:h <f-args>` states: words break on whitespace, `\ ` is a space inside a
--- word and `\\` a backslash, and every other backslash stands for itself.
--- So `--dir my\ src -- foo\ bar` searches for `foo bar`, and a query's
--- quotes, leading dashes and regex escapes (`\d`, `\s`) reach rg untouched.
---
--- Without the separator there is no query, which is an error rather than a
--- guess at where the flags stopped.
---@param fargs string[]  the whole argument line, as Neovim split it
---@return { flags:table, query:string }? parsed
---@return string? err
function M.parse(fargs)
    local sep
    for i, arg in ipairs(fargs) do
        if arg == "--" then
            sep = i
            break
        end
    end
    if not sep then
        return nil, "no query: write the flags, then `--`, then the query"
    end

    -- Nothing past the separator is the empty query. Whitespace past it is
    -- not: plain whitespace was consumed by the split, so a word that is
    -- there at all was written `\ ` and is a space worth searching for.
    if sep == #fargs then
        return nil, "empty search query"
    end

    -- The query is those words rejoined with the single space that separated
    -- them: runs of whitespace between them were Neovim's separators, and any
    -- space the query keeps is already inside a word.
    local query = table.concat(vim.list_slice(fargs, sep + 1), " ")

    local flags = {}
    local i     = 1
    while i < sep do
        local token = fargs[i]
        local name, glued = token:match("^%-%-([%w][%w%-]*)=(.*)$")
        if not name then name = token:match("^%-%-([%w][%w%-]*)$") end
        if not name then
            return nil, ("not a flag: %s (flags are written --like-this)"):format(token)
        end

        local def = _by_name[name]
        if not def then
            return nil, ("unknown flag: --%s"):format(name)
        end

        if not def.arg then
            if glued then
                return nil, ("--%s takes no value"):format(name)
            end
            flags[name] = true
        else
            local value = glued
            if not value then
                -- `--key value`: the next word is the value, whatever it looks
                -- like. A glob or a negated type starts with a character a flag
                -- could start with too, so only running out of words -- the
                -- separator counts as running out -- is an error here.
                i, value = i + 1, i + 1 < sep and fargs[i + 1] or nil
                if not value then
                    return nil, ("--%s needs a %s"):format(name, def.arg)
                end
            end
            if def.multi then
                local list = flags[name] or {}
                list[#list + 1] = value
                flags[name] = list
            else
                flags[name] = value
            end
        end
        i = i + 1
    end

    return { flags = flags, query = query }
end

---@param def     greplace.rgflags.FlagDef
---@param partial string
---@return string[]
local function value_candidates(def, partial)
    local spec = def.complete
    if type(spec) == "function" then return spec(partial) end
    if type(spec) == "string" then return vim.fn.getcompletion(partial, spec) end
    return {}
end

--- Flag names still worth offering: a switch already written is left out (it is
--- already on), while a repeatable one is offered for as long as it is legal to
--- write again.
---@param rest string[]  the words settled behind the one being typed
---@return string[]
local function flag_candidates(rest)
    local written = {}
    for _, token in ipairs(rest) do
        local n = token:match("^%-%-([%w][%w%-]*)")
        if n then written[n] = true end
    end

    local out = {}
    for _, def in ipairs(M.FLAGS) do
        if def.multi or not written[def.name] then
            out[#out + 1] = "--" .. def.name
        end
    end
    return out
end

--- Command-line completion for the flag section, as `customlist` wants it:
--- whole words, each one what `arglead` would be replaced by.
---
--- The splitting and the prefix filtering are `usercmd.complete`'s, which reads
--- the line rather than the cursor -- so what it is handed is the line up to
--- the cursor, and completing from the middle of one does not see the words
--- ahead of it. What is left here is the three places the cursor can be in,
--- told apart by what is behind it: after `--key`, where a value is next;
--- inside a `--key=`, where the value is glued on and the candidate has to
--- carry the `--key=` back with it; and anywhere else, where a flag name is
--- what can be written. Past the separator there is nothing to complete: those
--- words are a query, not a list.
---@param arglead  string
---@param cmdline  string
---@param cursor   integer  byte offset of the cursor: how much of `cmdline` is
---                         behind it, which is what `customlist` is handed
---@return string[]
function M.complete(arglead, cmdline, cursor)
    return usercmd.complete(arglead, cmdline:sub(1, cursor), function(_, rest, lead)
        if vim.tbl_contains(rest, "--") then return {} end

        -- A value glued to its flag, `--type=lu`.
        local name, partial = lead:match("^%-%-([%w][%w%-]*)=(.*)$")
        if name then
            local def = _by_name[name]
            if not def or not def.arg then return {} end
            return vim.tbl_map(function(cand)
                return ("--%s=%s"):format(name, cand)
            end, value_candidates(def, partial))
        end

        -- The word after a value flag is that flag's value.
        local prev      = rest[#rest]
        local prev_name = prev and prev:match("^%-%-([%w][%w%-]*)$")
        local prev_def  = prev_name and _by_name[prev_name]
        if prev_def and prev_def.arg then
            return value_candidates(prev_def, lead)
        end

        return flag_candidates(rest)
    end)
end

return M
