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

---@alias greplace.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)


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

    -- Trailing whitespace means a new, still-empty argument has begun; without
    -- it the last argument is the one being completed, not context for it.
    local rest = parsed.args or {}
    if not cmd_line:match("%s$") then
        rest[#rest] = nil
    end

    return filter(subcommand(parsed.cmd, rest, arg_lead))
end

--- Body of a command registered with `nargs = "*"`: hands Neovim's `fargs` to
--- `run_fn`, reporting any error it raises as a notification rather than as a
--- stack trace. Called from inside the command callback, so nothing here is
--- loaded until the command is first run.
---@param opts vim.api.keyset.create_user_command.command_args
---@param run_fn greplace.usercmd.run_fn
function M.handle(opts, run_fn)
    local cmd = opts.name
    -- nargs="*" always yields fargs; the fallback is only to satisfy its
    -- optional type.
    local ok, err = pcall(run_fn, cmd, opts.fargs or {}, opts)
    if not ok then
        vim.notify(
            "[greplace.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

return M
