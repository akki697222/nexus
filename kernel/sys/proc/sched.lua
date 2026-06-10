-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type table<integer, process>
local processes = {}

---@type integer
local current_pid = 0

function scheduler.run()
    while true do
        -- 1. collect OC hardware signal
        local sig = { computer.pullSignal(0) }
        if sig[1] then
            router.push({ type = sig[1], data = sig })
        end

        -- 2. fire expired timers
        timer.tick()

        -- 3. distribute bus events to process queues
        router.dispatch()

        -- 4. resume processes that have pending events
        for pid, proc in pairs(processes) do
            if proc.state == "running" and #proc.event_queue > 0 then
                scheduler.resume(pid)
            end
        end
    end
end

function scheduler.resume(pid)
    local proc = processes[pid]
    if not proc then return false, "no such process" end
    if proc.state == "dead" then return false, "process is dead" end

    local prev = current_pid
    current_pid = pid

    local ok, err = coroutine.resume(proc.coroutine)

    event._dispatch_listeners()

    current_pid = prev

    if not ok then
        process_manager.reap(pid, "error")
        return false, err
    end

    if coroutine.status(proc.coroutine) == "dead" then
        process_manager.reap(pid, "exit")
    end

    return true
end

function scheduler.yield()
    coroutine.yield()
end

function scheduler.sleep(seconds)
    local pid  = current_pid
    local proc = processes[pid]
    if not proc then return end
    proc.state = "sleeping"
    timer.after(seconds, function()
        scheduler.wake(pid)
    end)
    coroutine.yield()
end

function scheduler.register(proc)
    arg(1, proc, "table")
    processes[proc.pid] = proc
end

function scheduler.unregister(pid)
    arg(1, pid, "number")
    processes[pid] = nil
end

function scheduler.wake(pid)
    arg(1, pid, "number")
    local proc = processes[pid]
    if proc and (proc.state == "waiting" or proc.state == "sleeping") then
        proc.state = "running"
    end
end

function scheduler.current()
    return current_pid
end