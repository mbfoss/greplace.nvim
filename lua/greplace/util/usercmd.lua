local M = {}

-- This module does no argument parsing of its own. Dispatch passes Neovim's
-- opts.fargs straight through, and completion runs the raw command line back
-- through nvim_parse_cmd, so both paths split by Vim's native rules
-- (:h <f-args>):
--
--   Arguments are separated by unescaped whitespace. A backslash escapes the
--   character after it: \<space> (or \<tab>) is that literal whitespace and
--   does not split the argument, \\ is a single backslash, and a backslash
--   before anything else -- including a trailing backslash at end of line --
--   is kept verbatim along with what follows it. Quotes are not special.
--
--     a\ b c   -> a b  and  c        a\\b     -> a\b
--     a\\\ b   -> a\ b               a\nb     -> a\nb
--     \ a      -> " a"               a\       -> a\
--     "a b"    -> "a  and  b"        --p=x\ y -> --p=x y
--
---@alias greplace.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

--- Escape `name` for use as one `<f-args>`-split command argument. Only
--- backslash and whitespace are special there, so escaping anything else (as
--- `fnameescape()` does) would corrupt the argument instead of protecting it.
---@param name string
---@return string
function M.escape_arg(name)
    return (name:gsub("\\", "\\\\"):gsub("[ \t]", { [" "] = "\\ ", ["\t"] = "\\\t" }))
end

--- Filename completion for a command argument. `arg_lead` arrives escaped as
--- typed, but `getcompletion()` returns nothing for a pattern ending in an
--- escaped whitespace ("a\ "), so spell whitespace literally there -- the
--- pattern means the same either way. Matches come back unescaped; escape them
--- so that `M.complete`'s filter and the command line both see valid arguments.
---@param arg_lead string
---@param type string e.g. "file", "dir"
---@return string[]
function M.complete_filename(arg_lead, type)
    local pattern = arg_lead:gsub("\\([ \t])", "%1")
    return vim.tbl_map(M.escape_arg, vim.fn.getcompletion(pattern, type))
end

--- Completion for a command registered with `nargs = "*"`, to be called from
--- inside the `complete` callback so that this module -- and whatever
--- `subcommand` closes over -- is only required once completion is first
--- attempted.
---@param arg_lead string
---@param cmd_line string
---@param subcommand greplace.usercmd.subcommand
---@return string[]
function M.complete(arg_lead, cmd_line, subcommand)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    -- nvim_parse_cmd splits exactly as <f-args> does, and strips any range or
    -- command modifiers. It throws on a command line it cannot parse.
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmd_line, {})
    if not ok then return {} end

    -- A non-empty `arg_lead` is the argument currently being completed, so the
    -- last parsed argument is that same word, not context for it. An empty
    -- `arg_lead` means a new argument has begun (or none was typed), leaving
    -- every parsed argument as context.
    local rest = parsed.args or {}
    if arg_lead ~= "" then
        rest[#rest] = nil
    end

    return filter(subcommand(parsed.cmd, rest, arg_lead))
end

return M
