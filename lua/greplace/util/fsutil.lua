local M = {}

local timer = require("keystone.util.timer")
local strutil = require("keystone.util.strutil")

---@param path string
function M.file_exists(path)
    local stat = vim.loop.fs_stat(path)
    return stat and stat.type == "file"
end

---@param path string
---@return boolean
function M.dir_exists(path)
    local stat = vim.loop.fs_stat(path)
    return stat and stat.type == "directory" or false
end

---@param path string
---@return boolean
---@return string|nil
function M.make_dir(path)
    vim.fn.mkdir(path, "p")
    if not vim.fn.isdirectory(path) then
        local errmsg = vim.v.errmsg or ""
        return false, "Failed to create directory: " .. errmsg
    end
    return true
end

---@param path string
---@return boolean
---@return string? -- error msg
function M.create_file(path)
    local fd, err, err_name = vim.uv.fs_open(path, "wx", 420)
    if not fd then
        if err_name == "EEXIST" then
            return false, "File already exists"
        end
        return false, "Failed to create file: " .. tostring(err)
    end
    vim.uv.fs_close(fd)
    return true
end

---@param path string
---@param base string?
function M.get_relative_path(path, base)
    base = base or vim.fn.getcwd()

    local full_path = vim.fn.fnamemodify(path, ":p")
    base = vim.fn.fnamemodify(base, ":p")

    -- ensure trailing slash for proper prefix match
    if base:sub(-1) ~= "/" then
        base = base .. "/"
    end

    if full_path:find(base, 1, true) == 1 then
        return full_path:sub(#base + 1)
    end

    return nil -- not relative to base
end

---@param filepath string
---@param data string
---@return boolean
---@return string | nil
function M.write_content(filepath, data)
    local fd = io.open(filepath, "w")
    if not fd then
        return false, "Cannot open file for write '" .. filepath or "" .. "'"
    end
    local ok, ret_or_err = pcall(function() fd:write(data) end)
    fd:close()
    return ok, ret_or_err
end

---@param filepath  string
---@return boolean success
---@return string content or error
function M.read_content(filepath)
    local fd = io.open(filepath, "r")
    if not fd then
        return false, "Cannot open file for read '" .. (filepath or "") .. "'"
    end
    local read_ok, content_or_err = pcall(function() return fd:read("*a") end)
    fd:close()
    if not content_or_err then
        return false, "failed to read from file '" .. (filepath or "") .. "'"
    end
    return read_ok, content_or_err
end

---@param path string
---@param opts { max_size: number?, timeout: number? }?
---@param callback fun(err:string|nil, data:string|nil,cropped:boolean?)
---@return fun() abort
function M.async_load_text_file(path, opts, callback)
    opts = opts or {}

    local max_size = opts.max_size
    local timeout_ms = opts.timeout
    local uv = vim.uv or vim.loop

    local t = uv.new_timer()
    local fd = nil
    local chunks = {}
    local total_read = 0
    local offset = 0

    local finished = false
    local aborted = false

    ---@param err string|nil
    ---@param cropped boolean?
    local function finish(err, cropped)
        if finished then return end
        finished = true
        if t then
            if not t:is_closing() then
                t:stop()
                t:close()
            end
            t = nil
        end
        if fd then
            uv.fs_close(fd)
            fd = nil
        end
        if err then chunks = {} end
        vim.schedule(function()
            if not aborted then
                local final_data = table.concat(chunks)
                callback(err, final_data)
                chunks = {}
            end
        end)
    end
    local timeout_timer
    if timeout_ms then
        timeout_timer = vim.defer_fn(function()
            finish("Timeout", nil)
        end, timeout_ms)
    end
    uv.fs_open(path, "r", 438, function(open_err, opened_fd)
        if open_err or finished or aborted then
            if opened_fd then uv.fs_close(opened_fd) end
            if open_err and not (finished or aborted) then
                return finish("Could not open file: " .. open_err)
            end
            return
        end

        fd = opened_fd
        local function read_next()
            if not fd or finished or aborted then return end

            uv.fs_read(fd, 8192, offset, function(read_err, data)
                if finished or aborted then return end

                if read_err then
                    return finish("Read error: " .. read_err)
                end
                if not data or #data == 0 then
                    return finish()
                end
                if data:find("\0", 1, true) then
                    return finish("Binary file")
                end

                total_read = total_read + #data
                if max_size and total_read > max_size then
                    table.insert(chunks, data:sub(1, #data - (total_read - max_size)))
                    return finish(nil, true)
                end

                table.insert(chunks, data)
                offset = offset + #data

                read_next()
            end)
        end

        read_next()
    end)
    return function()
        if finished or aborted then return end
        aborted = true
        timer.stop_and_close_timer(timeout_timer)
        finish("Aborted")
    end
end

---@param dir string Directory path to monitor
---@param change_callback fun(file:string, status:table|nil) Callback called with changed file name
---@return fun()? cancel_fn Function that stops the monitoring
---@return string? error message
function M.monitor_dir(dir, change_callback)
    local uv = vim.uv or vim.loop

    local handle, err_msg = uv.new_fs_event()
    if not handle then
        return nil, err_msg
    end

    local terminated = false

    handle:start(dir, {}, function(err, fname, status)
        if terminated then
            return
        end
        if err then
            vim.schedule(function()
                if not terminated then
                    vim.notify("monitor_dir error: " .. err, vim.log.levels.ERROR)
                end
            end)
            return
        end
        if fname then
            vim.schedule(function()
                if not terminated then
                    change_callback(fname, status)
                end
            end)
        end
    end)
    local function cancel()
        if terminated then
            return
        end
        terminated = true
        if handle then
            if handle:is_active() then
                uv.fs_event_stop(handle)
            end
            handle:close()
            handle = nil
        end
    end
    return cancel
end

local _uv = vim.uv or vim.loop


---@param dir string
---@param on_file fun(name:string,type:"file"|"directory"|"link")
---@param on_done fun()
---@return function # cancel function
function M.async_scan_dir(dir, include_regex_list, exclude_regex_list, on_file, on_done)
    local is_cancelled = false
    local cancel_fn = function()
        is_cancelled = true
    end

    local on_done_called = false
    local call_on_done = function()
        if not on_done_called then
            vim.schedule(function()
                on_done()
            end)
            on_done_called = true
        end
    end
    local fd = _uv.fs_scandir(dir)
    if not fd then
        call_on_done()
        return cancel_fn
    end
    while true do
        local name, type = _uv.fs_scandir_next(fd)
        if not name or is_cancelled then break end
        on_file(name, type)
    end
    call_on_done()
    return cancel_fn
end

---@class keystone.util.fsutil.walk_dir_opts
---@field include_regex_list vim.regex[]?
---@field exclude_regex_list vim.regex[]?
---@field on_dir_enter fun(path:string)?
---@field on_file fun(filepath:string,filename:string,relative_path:string)
---@field on_done fun()
---@field follow_symlinks boolean?
---@field slice_ms number? work budget per slice in ms before yielding (default 10)
---@field yield_ms number? idle gap between slices in ms (default 1)

--- Walk `dir` recursively without blocking the UI.
---
--- Directories are scanned in slices of `slice_ms`; between slices the walk
--- parks on a `yield_ms` timer so libuv returns to the main loop and Neovim can
--- process typed keys and redraw. A plain `vim.schedule` chain is not enough
--- here — its callbacks drain within the same loop iteration, so a deep tree
--- still holds the UI.
---@param dir string
---@param opts keystone.util.fsutil.walk_dir_opts
---@return function # cancel function
function M.async_walk_dir(dir, opts)
    local pending_dirs = { dir }
    local is_cancelled = false
    local slice_ns     = (opts.slice_ms or 10) * 1e6
    local yield_ms     = opts.yield_ms or 1
    local stop_yield ---@type fun()?

    local on_done_called = false
    local call_on_done = function()
        if not on_done_called then
            vim.schedule(function()
                opts.on_done()
            end)
            on_done_called = true
        end
    end

    ---@param path string
    local function scan_dir(path)
        if opts.on_dir_enter then
            opts.on_dir_enter(path)
        end
        local fd = _uv.fs_scandir(path)
        if not fd then return end
        while true do
            -- `on_file` may cancel mid-directory; stop there rather than
            -- matching every remaining entry of a huge directory.
            if is_cancelled then return end
            local name, type_ = _uv.fs_scandir_next(fd)
            if not name then break end

            local full_path = vim.fs.joinpath(path, name)
            local rel_path = vim.fs.relpath(dir, full_path)
            if rel_path then
                local resolved_type = type_ ---@type string?
                if type_ == "link" and opts.follow_symlinks then
                    local stat = _uv.fs_stat(full_path)
                    resolved_type = stat and stat.type or nil
                end
                if resolved_type == "directory" then
                    if strutil.check_path_pattern(rel_path, true, nil, opts.exclude_regex_list) then
                        table.insert(pending_dirs, full_path)
                    end
                elseif resolved_type == "file" then
                    if strutil.check_path_pattern(rel_path, false, opts.include_regex_list, opts.exclude_regex_list) then
                        opts.on_file(full_path, name, rel_path)
                    end
                end
            end
        end
    end

    local function run_slice()
        -- The one-shot timer that woke us is still an open handle; close it.
        if stop_yield then
            stop_yield()
            stop_yield = nil
        end

        local deadline = _uv.hrtime() + slice_ns
        while true do
            if is_cancelled or #pending_dirs == 0 then
                call_on_done()
                return
            end
            scan_dir(table.remove(pending_dirs, 1))
            if _uv.hrtime() >= deadline then break end
        end

        stop_yield = timer.defer(yield_ms, run_slice)
    end

    -- The first slice is deferred too, so the caller always holds the cancel
    -- handle before any `on_file` fires: a cancel from inside a callback can
    -- never be dropped for want of a handle it hasn't been given yet.
    stop_yield = timer.defer(yield_ms, run_slice)

    return function()
        is_cancelled = true
        pending_dirs = {}
        if stop_yield then
            stop_yield()
            stop_yield = nil
        end
        -- Cancelling between slices leaves nobody to reach the loop head, so
        -- close the walk out here; `call_on_done` is idempotent.
        call_on_done()
    end
end

--- Rename a file and update buffers (LSP aware)
---@param from string
---@param to string
---@return boolean ok,string?
function M.rename_file(from, to)
    vim.validate("form", from, "string")
    vim.validate("to", to, "string")

    from = vim.fn.fnamemodify(from, ":p")
    to = vim.fn.fnamemodify(to, ":p")

    local lsp_changes = {
        files = { {
            oldUri = vim.uri_from_fname(from),
            newUri = vim.uri_from_fname(to),
        } }
    }

    local lsp_clients = vim.lsp.get_clients()
    for _, client in ipairs(lsp_clients) do
        if client:supports_method("workspace/willRenameFiles") then
            local resp = client:request_sync("workspace/willRenameFiles", lsp_changes, 1000, 0)
            if resp and resp.result ~= nil then
                vim.lsp.util.apply_workspace_edit(resp.result, client.offset_encoding)
            end
        end
    end

    vim.fn.mkdir(vim.fs.dirname(to), "p")
    local ok, rename_err = vim.uv.fs_rename(from, to)
    if not ok then
        return false, rename_err
    end

    -- replace buffer in all windows
    local from_buf = vim.fn.bufnr(from)
    if from_buf >= 0 then
        local to_buf = vim.fn.bufadd(to)
        vim.bo[to_buf].buflisted = true
        for _, win in ipairs(vim.fn.win_findbuf(from_buf)) do
            vim.api.nvim_win_set_buf(win, to_buf)
        end
        vim.api.nvim_buf_delete(from_buf, { force = true })
    end

    for _, client in ipairs(lsp_clients) do
        if client:supports_method("workspace/didRenameFiles") then
            client:notify("workspace/didRenameFiles", lsp_changes)
        end
    end

    return true
end

local _trash_fn = nil ---@type (fun(path:string):boolean,string?)|nil
local _trash_resolved = false

--- Resolve (and cache) a function that moves a single path to the system
--- trash, or nil when no trash mechanism is available on this platform.
---@return (fun(path:string):boolean,string?)|nil
local function resolve_trash_fn()
    if _trash_resolved then return _trash_fn end
    _trash_resolved = true

    ---@param argv_builder fun(path:string):string[]
    ---@return fun(path:string):boolean,string?
    local function cmd_trash(argv_builder)
        return function(path)
            local out = vim.fn.system(argv_builder(path))
            if vim.v.shell_error ~= 0 then
                return false, vim.trim(out)
            end
            return true
        end
    end

    if vim.fn.has("mac") == 1 then
        if vim.fn.executable("trash") == 1 then
            -- macOS' /usr/bin/trash takes only positional paths; it has no "--"
            -- end-of-options separator (paths here are always absolute).
            _trash_fn = cmd_trash(function(path) return { "trash", path } end)
        else
            _trash_fn = function(path)
                -- json_encode yields a double-quoted, escaped literal that is
                -- also valid as an AppleScript string.
                local script = ('tell application "Finder" to delete (POSIX file %s)')
                    :format(vim.fn.json_encode(path))
                local out = vim.fn.system({ "osascript", "-e", script })
                if vim.v.shell_error ~= 0 then
                    return false, vim.trim(out)
                end
                return true
            end
        end
    elseif vim.fn.has("win32") == 1 then
        local pwsh = vim.fn.executable("pwsh") == 1 and "pwsh"
            or (vim.fn.executable("powershell") == 1 and "powershell" or nil)
        if pwsh then
            _trash_fn = function(path)
                -- Route through the Recycle Bin via Microsoft.VisualBasic.
                -- Single-quoted PowerShell literal: escape ' by doubling it.
                local lit = "'" .. path:gsub("'", "''") .. "'"
                local script = table.concat({
                    "Add-Type -AssemblyName Microsoft.VisualBasic;",
                    ("$p = %s;"):format(lit),
                    "if (Test-Path -LiteralPath $p -PathType Container) {",
                    "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(" ..
                    "$p,'OnlyErrorDialogs','SendToRecycleBin')",
                    "} else {",
                    "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(" ..
                    "$p,'OnlyErrorDialogs','SendToRecycleBin')",
                    "}",
                }, " ")
                local out = vim.fn.system({ pwsh, "-NoProfile", "-NonInteractive", "-Command", script })
                if vim.v.shell_error ~= 0 then
                    return false, vim.trim(out)
                end
                return true
            end
        end
    elseif vim.fn.has("unix") == 1 then
        if vim.fn.executable("gio") == 1 then
            _trash_fn = cmd_trash(function(path) return { "gio", "trash", "--", path } end)
        elseif vim.fn.executable("trash-put") == 1 then
            _trash_fn = cmd_trash(function(path) return { "trash-put", "--", path } end)
        elseif vim.fn.executable("trash") == 1 then
            _trash_fn = cmd_trash(function(path) return { "trash", "--", path } end)
        end
    end

    return _trash_fn
end

--- Whether a system trash mechanism is available on this platform.
---@return boolean
function M.has_trash()
    return resolve_trash_fn() ~= nil
end

--- Move a path to the system trash.
---@param path string
---@return boolean ok
---@return string? err
function M.trash_path(path)
    local trash_fn = resolve_trash_fn()
    if not trash_fn then
        return false, "No system trash available"
    end
    return trash_fn(path)
end

--- Recursively copy a file, directory or symlink from `from` to `to`.
---@param from string
---@param to string
---@return boolean
---@return string? -- error msg
function M.copy_path(from, to)
    local stat = vim.uv.fs_lstat(from)
    if not stat then
        return false, "Source does not exist"
    end

    if stat.type == "link" then
        local target, read_err = vim.uv.fs_readlink(from)
        if not target then return false, read_err end
        local ok, sym_err = vim.uv.fs_symlink(target, to)
        if not ok then return false, sym_err end
        return true
    end

    if stat.type == "directory" then
        local ok, mk_err, mk_name = vim.uv.fs_mkdir(to, stat.mode)
        if not ok and mk_name ~= "EEXIST" then
            return false, mk_err
        end
        local handle = vim.uv.fs_scandir(from)
        if not handle then return false, "Cannot scan directory: " .. from end
        while true do
            local name = vim.uv.fs_scandir_next(handle)
            if not name then break end
            local sub_ok, sub_err = M.copy_path(
                vim.fs.joinpath(from, name),
                vim.fs.joinpath(to, name))
            if not sub_ok then return false, sub_err end
        end
        return true
    end

    local ok, copy_err = vim.uv.fs_copyfile(from, to)
    if not ok then return false, copy_err end
    return true
end

return M
