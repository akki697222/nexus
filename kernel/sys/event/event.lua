-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type event_api
local event = {}

---@type integer
local next_handle = 1

---@type table<integer, { type: event_type, callback: fun(event: event), once: boolean }>
local listeners = {}

function event.pull(type, timeout)
    arg(1, type,    "string",  true)
    arg(2, timeout, "number",  true)

    local deadline = timeout and (computer.uptime() + timeout)

    while true do
        local proc = process_manager.current_proc()
        for i, ev in ipairs(proc.event_queue) do
            if not type or ev.type == type then
                table.remove(proc.event_queue, i)
                return ev
            end
        end

        if deadline and computer.uptime() >= deadline then
            return nil
        end

        scheduler.yield()
    end
end

local function register(type, callback, once)
    arg(1, type,     "string")
    arg(2, callback, "function")
    local handle = next_handle
    next_handle  = next_handle + 1
    listeners[handle] = { type = type, callback = callback, once = once }
    return handle
end

function event.on(type, callback)
    return register(type, callback, false)
end

function event.once(type, callback)
    return register(type, callback, true)
end

function event.off(handle)
    arg(1, handle, "number")
    listeners[handle] = nil
end

-- Called by the scheduler after resuming a process to dispatch
-- pending events to registered listeners.
function event._dispatch_listeners()
    local proc = process_manager.current_proc()
    if not proc then return end

    local remaining = {}
    for i, ev in ipairs(proc.event_queue) do
        local matched = false
        for handle, l in pairs(listeners) do
            if l.type == ev.type then
                matched = true
                local ok, err = pcall(l.callback, ev)
                if not ok then
                    log.warn("event listener error (%s): %s", ev.type, tostring(err))
                end
                if l.once then
                    listeners[handle] = nil
                end
            end
        end
        if not matched then
            remaining[#remaining + 1] = ev
        end
    end
    proc.event_queue = remaining
end