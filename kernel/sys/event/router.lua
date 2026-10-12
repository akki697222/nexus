-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type router
router = {}

---@type event[]
local bus = {}

---@type table<integer, { filter: event_filter? }>
local subscribers = {}

-- per-process queue cap (OC RAM is small; unread broadcasts must not pile up)
local MAX_QUEUE = 256

-- Input events (keyboard / pointer) are NOT broadcast: only processes that
-- asked for them with router.watch_input() receive them, so a program reading
-- the keyboard does not leak its keystrokes into other processes' queues.
local INPUT_TYPES = {
    key_down = true, key_up = true, clipboard = true,
    touch = true, drag = true, drop = true, scroll = true,
}

---@type table<integer, fun(ev: event): boolean>|true
local input_watchers = {}
local input_grab = nil

---Receive input events. `filter` (optional) narrows them, e.g. Ctrl+C only.
function router.watch_input(pid, filter)
    arg(1, pid,    "number")
    arg(2, filter, "function", true)
    input_watchers[pid] = filter or true
end

---Exclusive input: while a process holds the grab (e.g. the compositor),
---only it receives input events; watchers get nothing.
function router.grab_input(pid)
    arg(1, pid, "number")
    input_grab = pid
end

function router.release_input(pid)
    arg(1, pid, "number")
    if input_grab == pid then input_grab = nil end
end

function router.unwatch_input(pid)
    arg(1, pid, "number")
    input_watchers[pid] = nil
end

function router.push(ev)
    arg(1, ev, "table")
    bus[#bus + 1] = ev
end

function router.dispatch()
    local pending = bus
    bus = {}
    for _, ev in ipairs(pending) do
        event._emit(ev)
        if INPUT_TYPES[ev.type] then
            if input_grab and subscribers[input_grab] then
                router.push_to(input_grab, ev)
            else
                for pid, f in pairs(input_watchers) do
                    if subscribers[pid] and (f == true or f(ev)) then
                        router.push_to(pid, ev)
                    end
                end
            end
            goto continue
        end
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
        ::continue::
    end
end

function router.subscribe(pid, filter)
    arg(1, pid,    "number")
    arg(2, filter, "table", true)
    subscribers[pid] = { filter = filter }
end

function router.unsubscribe(pid)
    arg(1, pid, "number")
    input_watchers[pid] = nil
    if input_grab == pid then input_grab = nil end
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
    local q = proc.event_queue
    if #q >= MAX_QUEUE then
        table.remove(q, 1)
        if not proc.overflow_warned then
            proc.overflow_warned = true
            log.warn("event queue overflow for pid %d, dropping oldest events", pid)
        end
    end
    q[#q + 1] = ev
    scheduler.wake(pid)
end

function router.broadcast(ev)
    arg(1, ev, "table")
    event._emit(ev)
    for pid in pairs(subscribers) do
        router.push_to(pid, ev)
    end
end