---@class keystone.util.SpawnHandle
---@field kill  fun()
---@field write fun(data: string?, on_done?: fun())
---@field get_write_queue_size fun():integer

---@param cmd      string[]
---@param opts     { cwd?: string, env: {string:string}?, stdin?: boolean, stdout?: fun(data:string), stderr?: fun(data:string) }
---@param on_exit  fun(code:integer)
---@return keystone.util.SpawnHandle?
local function spawn(cmd, opts, on_exit)
    -- stdin is opt-in: only commands that read from stdin (the rg `-` target)
    -- get a pipe, so others keep inheriting/ignoring stdin exactly as before.
    local stdin  = opts.stdin and vim.uv.new_pipe(false) or nil
    local stdout = vim.uv.new_pipe(false)
    local stderr = vim.uv.new_pipe(false)

    local function close_stdin()
        if stdin and not stdin:is_closing() then stdin:close() end
    end

    -- Pipes closed by force (kill path only — drops buffered data intentionally)
    local function close_pipes()
        close_stdin()
        if stdout and not stdout:is_closing() then stdout:close() end
        if stderr and not stderr:is_closing() then stderr:close() end
    end

    -- Natural-exit path: wait for both pipes to reach EOF before firing on_exit
    local exit_code
    local pipes_open = 2

    local function on_pipe_closed()
        pipes_open = pipes_open - 1
        if pipes_open == 0 and exit_code ~= nil then
            vim.schedule(function() on_exit(exit_code) end)
        end
    end

    -- vim.uv.spawn's `env` REPLACES the child environment wholesale and must be an
    -- array of "NAME=VALUE" strings, not a dict. So injecting anything means seeding
    -- from the full parent environment first, or the child loses PATH.
    local env = nil
    if (opts.env and next(opts.env)) or (opts.cwd and vim.fn.has("win32") == 0) then
        local merged = vim.fn.environ() ---@type table<string, string>
        if opts.env then
            for k, v in pairs(opts.env) do merged[k] = v end
        end
        if opts.cwd and vim.fn.has("win32") == 0 then
            merged["PWD"] = opts.cwd
        end
        env = {}
        for k, v in pairs(merged) do
            env[#env + 1] = k .. "=" .. v
        end
    end

    local handle ---@type uv.uv_process_t?
    ---@diagnostic disable-next-line: missing-fields
    handle = vim.uv.spawn(cmd[1], {
        args  = vim.list_slice(cmd, 2),
        cwd   = opts.cwd,
        env = env,
        stdio = { stdin, stdout, stderr },
    }, function(code)
        exit_code = code
        local h = handle
        if h and not h:is_closing() then h:close() end
        -- Caller may not have finished stdin; drop it so the pipe never leaks.
        close_stdin()
        -- Pipes may still have data; fire on_exit once they drain to EOF
        if pipes_open == 0 then
            vim.schedule(function() on_exit(exit_code) end)
        end
    end)

    if not handle then
        close_pipes()
        vim.schedule(function() on_exit(-1) end)
        return nil
    end

    local out = assert(stdout)
    out:read_start(function(err, data)
        if data and not err and opts.stdout then
            opts.stdout(data)
        elseif data == nil then
            if not out:is_closing() then out:close() end
            on_pipe_closed()
        end
    end)

    local err_pipe = assert(stderr)
    err_pipe:read_start(function(err, data)
        if data and not err and opts.stderr then
            opts.stderr(data)
        elseif data == nil then
            if not err_pipe:is_closing() then err_pipe:close() end
            on_pipe_closed()
        end
    end)

    ---@type keystone.util.SpawnHandle
    return {
        kill = function()
            -- close_pipes() stops read callbacks (no EOF will arrive), so set
            -- pipes_open = 0 so the process exit callback can still fire on_exit.
            close_pipes()
            pipes_open = 0
            if handle and not handle:is_closing() then
                handle:kill("sigterm")
            end
        end,
        --- Push a chunk to the child's stdin. Call with `nil` to signal EOF
        --- (the write side is shut down and closed). No-op unless `opts.stdin`
        --- enabled a stdin pipe. Streams: write may be called repeatedly before
        --- the final `write(nil)`.
        ---@param data    string?  chunk to push, or nil to signal end-of-input
        ---@param on_done fun()?   called once this write/shutdown completes
        write = function(data, on_done)
            if not stdin or stdin:is_closing() then
                if on_done then on_done() end
                return
            end
            if data == nil then
                -- shutdown waits for queued writes to flush, then sends EOF.
                stdin:shutdown(function()
                    close_stdin()
                    if on_done then on_done() end
                end)
                return
            end
            stdin:write(data, function()
                if on_done then on_done() end
            end)
        end,
        get_write_queue_size = function ()
            if not stdin then return 0 end
            return stdin:get_write_queue_size()
        end
    }
end

return spawn
