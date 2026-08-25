local M = {}

---@param timer table?
---@return nil
function M.stop_and_close_timer(timer)
    if timer and not timer:is_closing() then
        timer:close()
    end
    return nil
end

local function _make_stop(timer_ref)
    return function()
        M.stop_and_close_timer(timer_ref[1])
        timer_ref[1] = nil
    end
end

---Fire `fn` once after `interval` ms.
---@param interval number Delay in milliseconds.
---@param fn function Callback to execute.
---@return function stop A function that stops and closes the timer.
function M.defer(interval, fn)
    local t = vim.uv.new_timer()
    assert(t, "Timer creation failed")
    local ref = { t }
    t:start(interval, 0, vim.schedule_wrap(fn))
    return _make_stop(ref)
end

---Fire `fn` every `interval` ms.
---@param interval number Repeat interval in milliseconds.
---@param fn function Callback to execute.
---@return function stop A function that stops and closes the timer.
function M.every(interval, fn)
    local t = vim.uv.new_timer()
    assert(t, "Timer creation failed")
    local ref = { t }
    t:start(interval, interval, vim.schedule_wrap(fn))
    return _make_stop(ref)
end

return M
