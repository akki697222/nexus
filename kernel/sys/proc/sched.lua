-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type scheduler
scheduler = {}

---@type table<integer, process>
local processes = {}

---@type integer
local current_pid = 0

-- Idle wait for hardware signals (seconds). Keeps the VM from spinning
-- (energy / CPU) while still waking up promptly for timers and events.
local IDLE_WAIT = 0.05

-- A process is runnable when it is not blocked in event.pull(), or when
-- the event it waits for (or its timeout) has arrived.
local function is_ready(proc)
    if proc.state ~= "running" then return false end
    local wait = proc.wait
    if not wait then return true end
    if wait.deadline and computer.uptime() >= wait.deadline then return true end
    for _, ev in ipairs(proc.event_queue) do
        if (not wait.type or ev.type == wait.type) and (not wait.match or wait.match(ev)) then
            return true
        end
    end
    return false
end

function scheduler.run()
    log.info("Scheduler started")
    while true do
        -- 1. collect OC hardware signal (sleep briefly only when idle)
        local any_ready = false
        for _, proc in pairs(processes) do
            if is_ready(proc) then any_ready = true break end
        end
        local sig = table.pack(computer.pullSignal(any_ready and 0 or IDLE_WAIT))
        if sig[1] then
            router.push({ type = sig[1], data = sig })
        end

        -- 2. fire expired timers
        timer.tick()

        -- 3. distribute bus events to process queues
        router.dispatch()

        -- 4. resume runnable processes (snapshot: resume may spawn / kill)
        local pids = {}
        for pid in pairs(processes) do
            pids[#pids + 1] = pid
        end
        for _, pid in ipairs(pids) do
            local proc = processes[pid]
            if proc and is_ready(proc) then
                scheduler.resume(pid)
            end
        end

        log.tick()
    end
end

function scheduler.resume(pid)
    local proc = processes[pid]
    if not proc then return false, "no such process" end
    if proc.state == "dead" then return false, "process is dead" end

    local prev = current_pid
    current_pid = pid

    local ok, err = coroutine.resume(proc.coroutine)

    current_pid = prev

    if not ok and type(err) == "table" and err.nexus_exit ~= nil then
        process_manager.reap(pid, "exit", err.nexus_exit)
        return true
    end

    if not ok then
        log.error("Process %d crashed: %s", pid, debug.traceback(proc.coroutine, tostring(err)))
        process_manager.reap(pid, "error")
        return false, err
    end

    if coroutine.status(proc.coroutine) == "dead" then
        process_manager.reap(pid, "exit", 0)
    end

    return true
end

function scheduler.yield()
    coroutine.yield()
end

function scheduler.sleep(seconds)
    arg(1, seconds, "number")
    local pid  = current_pid
    local proc = processes[pid]
    if not proc then
        log.warn("scheduler.sleep called outside a process (pid=%d)", pid)
        return
    end
    proc.state = "sleeping"
    timer.after(seconds, function()
        if processes[pid] and processes[pid].state == "sleeping" then
            processes[pid].state = "running"
        end
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
    if proc and proc.state == "waiting" then
        proc.state = "running"
    end
end

function scheduler.current()
    return current_pid
end
