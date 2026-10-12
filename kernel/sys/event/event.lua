-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type event_api
event = {}

---@type integer
local next_handle = 1

---@type table<integer, { type: event_type, callback: fun(event: event), once: boolean }>
local listeners = {}

function event.pull(type, timeout, match)
    arg(1, type,    "string",  true)
    arg(2, timeout, "number",  true)
    arg(3, match,   "function", true)

    local proc = process_manager.current_proc()
    if not proc then
        error("event.pull called outside a process", 2)
    end

    local deadline = timeout and (computer.uptime() + timeout)
    proc.wait = { type = type, deadline = deadline, match = match }

    while true do
        for i, ev in ipairs(proc.event_queue) do
            if (not type or ev.type == type) and (not match or match(ev)) then
                table.remove(proc.event_queue, i)
                proc.wait = nil
                return ev
            end
        end

        if deadline and computer.uptime() >= deadline then
            proc.wait = nil
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

-- Called once per event by the router (not per process queue), so kernel
-- listeners never steal events out of process queues.
function event._emit(ev)
    for handle, l in pairs(listeners) do
        if l.type == ev.type then
            if l.once then
                listeners[handle] = nil
            end
            local ok, err = pcall(l.callback, ev)
            if not ok then
                log.warn("event listener error (%s): %s", ev.type, tostring(err))
            end
        end
    end
end
