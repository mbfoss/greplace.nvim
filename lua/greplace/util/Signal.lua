---@class keystone.util.Signal<T>
---@field _listeners T[]
local Signal = {}
Signal.__index = Signal

---@generic T: fun(...)
---@return keystone.util.Signal<T>
function Signal.new()
    return setmetatable({ _listeners = {} }, Signal)
end

---@param fn T
---@return fun() unsubscribe
function Signal:subscribe(fn)
    table.insert(self._listeners, fn)
    return function() self:unsubscribe(fn) end
end

---@param fn T
function Signal:unsubscribe(fn)
    for i, l in ipairs(self._listeners) do
        if l == fn then
            table.remove(self._listeners, i)
            return
        end
    end
end

function Signal:emit(...)
    local snapshot = vim.list_slice(self._listeners)
    for _, fn in ipairs(snapshot) do
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            vim.api.nvim_echo({ { tostring(err), "ErrorMsg" } },
                true, { err = true })
        end
    end
end

return Signal
