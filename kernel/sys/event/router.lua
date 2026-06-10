-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type event[]
local bus = {}

---@type table<integer, { filter: event_filter? }>
local subscribers = {}

function router.push(ev)
    arg(1, ev, "table")
    bus[#bus + 1] = ev
end

function router.dispatch()
    local pending = bus
    bus = {}
    for _, ev in ipairs(pending) do
        for pid, sub in pairs(subscribers) do
            local f = sub.filter
            if not f then
                router.push_to(pid, ev)
            elseif f.type and f.type ~= ev.type then
                -- type mismatch, skip
            elseif f.from and f.from ~= ev.from then
                -- sender mismatch, skip
            else
                router.push_to(pid, ev)
            end
        end
    end
end

function router.subscribe(pid, filter)
    arg(1, pid,    "number")
    arg(2, filter, "table", true)
    subscribers[pid] = { filter = filter }
end

function router.unsubscribe(pid)
    arg(1, pid, "number")
    subscribers[pid] = nil
end

function router.pop(pid)
    arg(1, pid, "number")
    local proc = process_manager.get(pid)
    if not proc then return nil end
    local ev = proc.event_queue[1]
    if ev then
        table.remove(proc.event_queue, 1)
    end
    return ev
end

function router.has_event(pid)
    arg(1, pid, "number")
    local proc = process_manager.get(pid)
    if not proc then return false end
    return #proc.event_queue > 0
end

function router.push_to(pid, ev)
    arg(1, pid, "number")
    arg(2, ev,  "table")
    local proc = process_manager.get(pid)
    if not proc then return end
    proc.event_queue[#proc.event_queue + 1] = ev
    scheduler.wake(pid)
end

function router.broadcast(ev)
    arg(1, ev, "table")
    for pid in pairs(subscribers) do
        router.push_to(pid, ev)
    end
end