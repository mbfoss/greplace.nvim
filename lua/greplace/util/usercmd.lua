local M = {}

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack

--- Split a command line into arguments on unescaped whitespace, honouring
--- backslash escapes and shell-style quoting, so that an argument containing
--- spaces can be given as one (`\ ` or `"..."`) rather than splitting into
--- two. Note that `:Greplace` does not use this: its query is taken from the
--- raw command line, spaces, quotes and backslashes included.
---@param str string
---@return string[]
local function _split_args(str)
    local args = {}
    local i = 1
    local len = #str
    local part = {}
    local quote = nil
    -- Tracked separately from `#part`, so a deliberately empty argument ("")
    -- still counts as one rather than vanishing.
    local started = false

    local function flush()
        if started then
            table.insert(args, table.concat(part))
            part, started = {}, false
        end
    end

    while i <= len do
        local c = str:sub(i, i)
        if c == '\\' and i < len then
            table.insert(part, str:sub(i + 1, i + 1))
            started = true
            i = i + 2
        elseif quote then
            -- Inside quotes whitespace is literal; only the matching close
            -- quote ends the run.
            if c == quote then quote = nil else table.insert(part, c) end
            i = i + 1
        elseif c == '"' or c == "'" then
            quote = c
            started = true
            i = i + 1
        elseif c:match('%s') then
            flush()
            i = i + 1
        else
            table.insert(part, c)
            started = true
            i = i + 1
        end
    end
    flush()
    return args
end

---@alias greplace.usercmd.subcommand_fn fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias greplace.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)

--- Completion for a command registered with `nargs = "*"`, to be called from
--- inside the `complete` callback so that this module -- and whatever
--- `subcommand_fn` closes over -- is only required once completion is first
--- attempted.
---@param arg_lead string
---@param cmd_line string
---@param subcommand_fn greplace.usercmd.subcommand_fn
---@return string[]
function M.complete(arg_lead, cmd_line, subcommand_fn)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if not vim.startswith(s, '_') and vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = _split_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(subcommand_fn(cmd, {}, arg_lead))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(subcommand_fn(cmd, rest, arg_lead))
    end
    return {}
end

--- Body of a command registered with `nargs = "*"`: splits `opts.args` and
--- hands them to `run_fn`, reporting any error it raises as a notification
--- rather than as a stack trace. Called from inside the command callback, so
--- nothing here is loaded until the command is first run.
---@param opts vim.api.keyset.create_user_command.command_args
---@param run_fn greplace.usercmd.run_fn
function M.handle(opts, run_fn)
    local cmd = opts.name
    local args = _split_args(opts.args)
    local ok, err = pcall(run_fn, cmd, args, opts)
    if not ok then
        vim.notify(
            "[greplace.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

return M
