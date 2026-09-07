local M = {}

-- ---------------------------------------------------------------------------
-- `:Gsearch`'s flags: the schema, what each one means to ripgrep, and the
-- part of it that ripgrep cannot be told at all.
--
-- The search runs twice -- once over the working tree, once over the
-- concatenated text of modified buffers fed to `rg -` -- and a file-selection flag
-- only reaches the first of those: rg sees the buffer pass as one nameless
-- stream, so `-g` and `--type` have nothing to filter there. Left at that, a
-- `--glob *.lua` search would skip `.md` files on disk and then report
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
        -- Blocking, and runs on the completion path too, so bound it: an `rg`
        -- that hangs leaves the types empty rather than wedging the editor.
        local ok, res = pcall(function()
            return vim.system({ "rg", "--type-list" }, { text = true }):wait(5000)
        end)
        if ok and res.code == 0 then
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
---@field arg      string?  what its value stands for; nil for a switch
---@field multi    boolean? the flag may be repeated, and the values collect
---@field num      boolean? its value has to be a whole number
---@field complete greplace.rgflags.CompleteSpec?
---@field desc     string

---@type greplace.rgflags.FlagDef[]
M.FLAGS = {
    { name = "dir",           arg = "path", complete = "dir", desc = "search root directory" },
    { name = "glob",          arg = "glob", multi = true, desc = "glob filter, repeatable: *.txt, !*.lua, **/dir/**" },
    { name = "iglob",         arg = "glob", multi = true, desc = "the same, matched regardless of case" },
    { name = "type",          arg = "name", multi = true, complete = complete_type, desc = "rg file type, repeatable: lua, rust, !md" },
    { name = "type-not",      arg = "name", multi = true, complete = complete_type, desc = "exclude an rg file type, repeatable: md" },
    { name = "max-depth",     arg = "n", num = true, desc = "max directory depth to descend" },
    { name = "regex",         desc = "treat the query as a regex" },
    { name = "fixed-strings", desc = "treat the query literally (default)" },
    { name = "case",          desc = "case-sensitive (default: smart case)" },
    { name = "nocase",        desc = "case-insensitive (default: smart case)" },
    { name = "word",          desc = "match whole words only" },
    { name = "line",          desc = "match whole lines only" },
    { name = "invert",        desc = "collect lines that do NOT match" },
    { name = "follow",        desc = "follow symlinks" },
    { name = "hidden",        desc = "include hidden (dotfiles)" },
    { name = "no-ignore",     desc = "disable .gitignore / .ignore rules" },
}

---@type table<string, greplace.rgflags.FlagDef>
local _by_spelling = {}
for _, def in ipairs(M.FLAGS) do
    _by_spelling["--" .. def.name] = def
end

---A parsed flag line. The keys are the flags' own names, hyphens included, so
---the two hyphenated ones are read as `flags["no-ignore"]`.
---@class greplace.RgFlags
---@field dir       string?
---@field glob      string[]?
---@field iglob     string[]?
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

--- rg arguments common to both passes: what counts as a match, but not which
--- files are looked at (the buffer pass has no files).
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
    local args = {}

    if flags.follow then args[#args + 1] = "--follow" end
    if flags.hidden then args[#args + 1] = "--hidden" end
    if flags["no-ignore"] then args[#args + 1] = "--no-ignore" end

    -- rg's own two spellings, and they are passed through as themselves: `-g`
    -- matches case as written, `--iglob` does not.
    for _, g in ipairs(flags.glob or {}) do
        args[#args + 1] = "-g"
        args[#args + 1] = g
    end
    for _, g in ipairs(flags.iglob or {}) do
        args[#args + 1] = "--iglob"
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
---@param globs      string[]
---@param ignorecase boolean?  compile them case-insensitively (`--iglob`)
---@param into       vim.regex[]?  append to this list rather than a new one
---@return vim.regex[]?  nil when none compiled, so a bad glob filters nothing
local function compile_globs(globs, ignorecase, into)
    local out = into or {}
    for _, g in ipairs(globs) do
        local re = strutil.compile_glob(g, ignorecase)
        if re then out[#out + 1] = re end
    end
    return #out > 0 and out or nil
end

--- Split glob lists ("*.lua", "!*_spec.lua") into compiled include and exclude
--- regexes for the buffer pass, where rg's `-g` cannot reach. `--glob` and
--- `--iglob` differ only in case, as they do to rg.
---@param globs  string[]?  `--glob` values
---@param iglobs string[]?  `--iglob` values
---@return vim.regex[]? include, vim.regex[]? exclude
local function compile_filter_globs(globs, iglobs)
    local include, exclude = { {}, {} }, { {}, {} }
    for i, list in ipairs({ globs or {}, iglobs or {} }) do
        for _, g in ipairs(list) do
            if g:sub(1, 1) == "!" then
                table.insert(exclude[i], g:sub(2))
            else
                table.insert(include[i], g)
            end
        end
    end

    local inc = compile_globs(include[1], false)
    inc       = compile_globs(include[2], true, inc)
    local exc = compile_globs(exclude[1], false)
    exc       = compile_globs(exclude[2], true, exc)
    return inc, exc
end

--- The same for `type`: rg's `-t` filters walked files, not stdin, so expand
--- its globs and match each buffer's basename as rg would.
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

--- Whether rg would call a root-relative path hidden: any component is a
--- dotfile. Without this, the buffer pass reports `.env` or `.git/` matches
--- the disk pass never looked at.
---@param relpath string
---@return boolean
local function is_hidden(relpath)
    for part in vim.gsplit(relpath, "/", { plain = true }) do
        if part:sub(1, 1) == "." then return true end
    end
    return false
end

--- A predicate over root-relative paths standing for the file-selection flags,
--- filtering buffers as rg filters the tree. Globs compile once per search.
---@param flags table
---@return fun(relpath:string):boolean
function M.buffer_filter(flags)
    local include, exclude           = compile_filter_globs(flags.glob, flags.iglob)
    local type_include, type_exclude = compile_type_globs(flags.type)
    local max_depth                  = tonumber(flags["max-depth"])

    return function(relpath)
        local base = vim.fs.basename(relpath)
        -- A matching `--glob` overrides the hidden rule (`-g .env` finds
        -- `.env`); `--type` and exclude-only globs do not.
        if not flags.hidden and is_hidden(relpath)
            and not (include and strutil.any_match(relpath, include)) then
            return false
        end
        return strutil.check_path_pattern(relpath, false, include, exclude)
            and strutil.check_path_pattern(base, false, type_include, type_exclude)
            and (not max_depth or select(2, relpath:gsub("/", "")) < max_depth)
    end
end

--- Split a token into its spelling and any value glued to it with `=`.
---@param token string
---@return string spelling
---@return string? value
local function split_assignment(token)
    local spelling, value = token:match("^(%-%-[%w][%w%-]*)=(.*)$")
    return spelling or token, value
end

--- Split raw arguments into words with `:h <f-args>` escapes, keeping offsets.
---@param raw string
---@return { text:string, s:integer, e:integer }[]
local function scan(raw)
    local tokens, i, n = {}, 1, #raw
    while i <= n do
        while i <= n and raw:sub(i, i):match("%s") do i = i + 1 end
        if i > n then break end
        local s, buf = i, {}
        while i <= n do
            local c = raw:sub(i, i)
            if c:match("%s") then break end
            local nxt = raw:sub(i + 1, i + 1)
            if c == "\\" and nxt ~= "" then
                -- `\ ` is whitespace, `\\` a backslash; anything else stays.
                buf[#buf + 1] = (nxt:match("%s") or nxt == "\\") and nxt or ("\\" .. nxt)
                i = i + 2
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        tokens[#tokens + 1] = { text = table.concat(buf), s = s, e = i - 1 }
    end
    return tokens
end

--- Whether a word opens a flag line. Short spellings are not accepted.
---@param token string
---@return boolean
local function is_flag_token(token)
    return token:sub(1, 2) == "--"
end
-- Exported for the ranged form, which has flags but no raw query.
M.is_flag_token = is_flag_token

--- Merge a flag into the parsed table, last spelling winning for exclusive ones.
---@param flags table
---@param def   greplace.rgflags.FlagDef
---@param value string?
local function apply_flag(flags, def, value)
    local name = def.name
    if name == "case" or name == "nocase" then
        flags.case, flags.nocase = nil, nil
    elseif name == "regex" then
        flags["fixed-strings"] = nil
    elseif name == "fixed-strings" then
        flags.regex = nil
    end

    if not def.arg then
        flags[name] = true
    elseif def.multi then
        local list = flags[name] or {}
        list[#list + 1] = value
        flags[name] = list
    else
        flags[name] = value
    end
end

--- Parse flag words up to `stop`; a value flag consumes the next word.
---@param tokens { text:string }[]
---@param stop   integer?
---@param query_after boolean?  a word that is not a flag starts the query
---                              rather than being an error
---@return table?  flags
---@return string? err
---@return integer? index of the first word left unread
local function parse_prefix(tokens, stop, query_after)
    stop = stop or #tokens
    local flags, i = {}, 1
    while i <= stop do
        if query_after and (tokens[i].text == "--" or not is_flag_token(tokens[i].text)) then
            break
        end

        local spelling, glued = split_assignment(tokens[i].text)
        local def = _by_spelling[spelling]
        if def then
            if def.arg then
                local value = glued
                if not value then
                    i = i + 1
                    value = i <= stop and tokens[i].text or nil
                    if not value then
                        return nil, ("--%s needs a %s"):format(def.name, def.arg)
                    end
                end
                apply_flag(flags, def, value)
            elseif glued then
                return nil, ("--%s takes no value"):format(def.name)
            else
                apply_flag(flags, def, nil)
            end
        else
            return nil, tokens[i].text:sub(1, 1) == "-"
                and ("unknown flag: %s"):format(spelling)
                or ("not a flag: %s (flags are written --like-this)"):format(tokens[i].text)
        end
        i = i + 1
    end

    if flags["type-not"] then
        flags.type = flags.type or {}
        for _, t in ipairs(flags["type-not"]) do flags.type[#flags.type + 1] = "!" .. t end
        flags["type-not"] = nil
    end
    flags["fixed-strings"] = nil

    for _, def in ipairs(M.FLAGS) do
        local value = def.num and flags[def.name]
        if value and not value:match("^%d+$") then
            return nil, ("--%s needs a whole number, not `%s`"):format(def.name, value)
        end
    end
    return flags, nil, i
end

--- Parse the raw `:Gsearch` arguments: flags first, then the query byte for
--- byte. The query starts at the first word that is not a flag, or after the
--- first bare `--`; on a line that does not open with a flag it is the line.
---@param raw string
---@return { flags:table, query:string }? parsed
---@return string? err
function M.parse(raw)
    local tokens = scan(raw)
    if #tokens == 0 then return nil, "empty search query" end

    if not is_flag_token(tokens[1].text) then
        return { flags = {}, query = raw:sub(tokens[1].s) }
    end

    -- An explicit `--` still settles where the flags end and the query starts,
    -- which is what a query of its own that begins with `--` needs; it also
    -- keeps a stray word before it an error rather than a query.
    local sep
    for i, t in ipairs(tokens) do
        if t.text == "--" then sep = i break end
    end

    local flags, err, first
    if sep then
        flags, err = parse_prefix(tokens, sep - 1)
        first = sep + 1
    else
        flags, err, first = parse_prefix(tokens, nil, true)
    end
    if not flags then return nil, err end
    if not tokens[first] then return nil, "empty search query" end

    -- From the query's first word to the end of the line, escapes and all.
    return { flags = flags, query = raw:sub(tokens[first].s) }
end

--- Parse a ranged line's flags; the visual selection supplies the query.
---@param fargs string[]
---@return table? flags
---@return string? err
function M.parse_flags(fargs)
    local tokens = {}
    for _, t in ipairs(fargs) do tokens[#tokens + 1] = { text = t } end
    local flags, err = parse_prefix(tokens)
    return flags, err
end

---@param def     greplace.rgflags.FlagDef
---@param partial string
---@return string[]
local function value_candidates(def, partial)
    local spec = def.complete
    if type(spec) == "function" then return spec(partial) end
    if type(spec) == "string" then return usercmd.complete_filename(partial, spec) end
    return {}
end

--- Flag spellings still worth offering, skipping switches already written.
---@param rest string[]  the words settled behind the one being typed
---@return string[]
local function flag_candidates(rest)
    local written, i = {}, 1
    while i <= #rest do
        local spelling, glued = split_assignment(rest[i])
        local def = _by_spelling[spelling]
        if def then
            written[def.name] = true
            if def.arg and not glued then i = i + 1 end
        end
        i = i + 1
    end

    local out = { "--" }
    for _, def in ipairs(M.FLAGS) do
        if def.multi or not written[def.name] then
            out[#out + 1] = "--" .. def.name
        end
    end
    return out
end

--- Whether the words settled so far are still all flags and flag values, so
--- the word being typed belongs to the flag section rather than the query.
---@param rest string[]
---@return boolean
local function in_flag_section(rest)
    local i = 1
    while i <= #rest do
        if rest[i] == "--" then return false end
        local spelling, glued = split_assignment(rest[i])
        local def = _by_spelling[spelling]
        if not def then return false end
        if def.arg and not glued then i = i + 1 end
        i = i + 1
    end
    return true
end

--- Command-line completion for the flag section, as `customlist` wants it.
---@param arglead string
---@param cmdline string
---@param cursor  integer  bytes of `cmdline` behind the cursor
---@return string[]
function M.complete(arglead, cmdline, cursor)
    local prefix = cmdline:sub(1, cursor)
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, prefix, {})
    local cmd = ok and parsed.cmd or "Gsearch"

    -- Everything after the command name is the raw argument line.
    local _, name_end = prefix:find("%f[%w]" .. vim.pesc(cmd) .. "%f[%W]")
    if not name_end then return {} end
    local raw = (prefix:sub(name_end + 1):gsub("^%s+", "", 1))

    local rest = {}
    for _, t in ipairs(scan(raw)) do rest[#rest + 1] = t.text end
    if arglead ~= "" then rest[#rest] = nil end

    if not in_flag_section(rest) then return {} end

    local spelling, partial = split_assignment(arglead)
    if partial then
        local def = _by_spelling[spelling]
        if not def or not def.arg then return {} end
        return vim.tbl_map(function(cand) return spelling .. "=" .. cand end,
            value_candidates(def, partial))
    end

    local prev_spelling, prev_glued = split_assignment(rest[#rest] or "")
    local prev_def = _by_spelling[prev_spelling]
    if prev_def and prev_def.arg and not prev_glued then
        return value_candidates(prev_def, arglead)
    end

    return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end,
        flag_candidates(rest))
end

return M
