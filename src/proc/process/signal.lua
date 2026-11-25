-- process/signal.lua - process exit and reaping, signal delivery and
-- default actions, kill and process groups.

-- from the sources before this one
local process_map = proci.process_map
local used_pids = proci.used_pids
local run_queue = proci.run_queue
local wait_queue = proci.wait_queue
local suspend_queue = proci.suspend_queue
local io_waiters = proci.io_waiters
local spawn_completions = proci.spawn_completions
local dequeue = proci.dequeue
local dequeue_entry = proci.dequeue_entry
local dequeue_process = proci.dequeue_process
local enqueue_run = proci.enqueue_run
local sig_impl = proci.sig_impl

local function resolve_process_waiters(target)
    local to_wake = {}
    for _, waiter in ipairs(processes) do
        if waiter.wait_target == target then
            waiter.wait_target = nil
            waiter.wait_result = target.err
            waiter.wait_status = target.exit_status
            dequeue(wait_queue, waiter.pid)
            if waiter.status == "waiting" then
                waiter.status = "running"
                table.insert(to_wake, waiter)
            end
        end
    end
    for _, waiter in ipairs(to_wake) do enqueue_run(waiter) end
end

local function normalize_exit_status(value, fallback)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        value = fallback or 0
    end
    return math.floor(value) % 256
end

local function record_spawn_completion(target)
    if not target.spawn_tracked or not target.spawn_parent_instance then return end
    local owned = spawn_completions[target.spawn_parent_instance]
    if not owned then return end -- parent exited; do not retain orphan records
    owned[target.instance] = {
        pid = target.pid,
        err = target.err,
        status = target.exit_status,
    }
end

local function finish_process(target, status)
    if target.status == "dead" then return end
    target.exit_status = normalize_exit_status(status, target.err and 1 or 0)
    target.status = "dead"
    record_spawn_completion(target)
    resolve_process_waiters(target)
end

function process.exit(code)
    local proc = process.getCurrent()
    if not proc then return end
    proc.requested_exit_status = normalize_exit_status(code, 0)
    sig_impl.destroy(proc)
    coroutine.yield("__exit__")
end

-- Ends a process now; `status` defaults to what it asked for, else 137
-- (128 + 9).
sig_impl.destroy = function(proc, status)
    local pid = proc.pid

    -- Resolve waiters while this exact process entry is still registered and
    -- before its PID can be allocated to another process.
    finish_process(proc, status or proc.requested_exit_status or 137)

    dequeue_process(run_queue, proc)
    dequeue_process(wait_queue, proc)
    dequeue_process(suspend_queue, proc)
    for channel, waiters in pairs(io_waiters) do
        for i = #waiters, 1, -1 do
            local waiter = waiters[i]
            if waiter.pid == proc.pid and waiter.instance == proc.instance then
                waiter.io_wait_channel = nil
                waiter.io_ready = nil
                table.remove(waiters, i)
            end
        end
        if #waiters == 0 then io_waiters[channel] = nil end
    end

    for i, p in ipairs(processes) do
        if p.pid == pid then
            table.remove(processes, i)
            break
        end
    end

    event.removeQueue(pid)
    if proc.tid == proc.pid and proc.fd then
        vfsk.closeAllFds(proc.fd)
    end
    if proc.tid == proc.pid and devmgr then
        devmgr.reap(pid)
    end
    process_map[pid] = nil
    used_pids[pid] = nil
    spawn_completions[proc.instance] = nil
    return true
end

-- Makes a process blocked in an event or IO wait runnable, so a signal it
-- handles is acted on now (its wait sees nothing and waits again, as a
-- system call would return EINTR).
function sig_impl.interrupt(proc)
    if proc.status ~= "waiting" or proc.wait_target then return end
    local channel = proc.io_wait_channel
    if channel ~= nil then
        local waiters = io_waiters[channel]
        if waiters then
            for i = #waiters, 1, -1 do
                if waiters[i] == proc then table.remove(waiters, i) end
            end
            if #waiters == 0 then io_waiters[channel] = nil end
        end
        proc.io_wait_channel = nil
    else
        dequeue_entry(wait_queue, proc)
    end
    proc.status = "running"
    enqueue_run(proc)
end

-- The default action of `sig` on `proc`. Returns true if it ended.
function sig_impl.default_action(proc, sig)
    local action = sig_impl.DEFAULT[sig] or "term"
    if action == "term" or action == "core" then
        sig_impl.destroy(proc, 128 + sig)
        return true
    elseif action == "stop" then
        if proc.status ~= "suspended" then process.suspend(proc.pid) end
    elseif action == "cont" then
        if proc.status == "suspended" then process.resume_handle(proc.pid) end
    end
    return false
end

-- Delivers `sig` to one process.
function sig_impl.deliver(proc, sig)
    if sig == 9 then
        sig_impl.destroy(proc, 128 + 9)
        return true
    end
    if sig == 19 then
        if proc.status ~= "suspended" then process.suspend(proc.pid) end
        return true
    end
    -- 18 continues a stopped process whatever its disposition
    if sig == 18 and proc.status == "suspended" then process.resume_handle(proc.pid) end
    local disposition = proc.sig_handlers[sig]
    if disposition == "ignore" then return true end
    if type(disposition) == "function" then
        table.insert(proc.signals, sig)
        sig_impl.interrupt(proc)
        return true
    end
    if sig ~= 18 then sig_impl.default_action(proc, sig) end
    return true
end

function sig_impl.valid_signal(sig)
    return math.type(sig) == "integer" and sig >= 1 and sig <= 31
end

-- kill(2): `pid` > 0 is one process, `pid` < 0 the process group -pid.
-- Without `sig` the process is killed outright (9), as before.
---@param pid integer
---@param sig? integer
function process.kill(pid, sig)
    sig = sig or 9
    if not sig_impl.valid_signal(sig) then return false, "Invalid signal" end
    if math.type(pid) ~= "integer" or pid == 0 then return false, "No such process" end
    if pid < 0 then return process.killpg(-pid, sig) end
    local proc = process.get(pid)
    if not proc then return false, "No such process" end
    return sig_impl.deliver(proc, sig)
end

-- Sends `sig` to every process in group `pgid`.
function process.killpg(pgid, sig)
    if not sig_impl.valid_signal(sig) then return false, "Invalid signal" end
    local targets = {}
    for _, p in ipairs(processes) do
        if p.pgid == pgid and p.tid == p.pid then targets[#targets + 1] = p end
    end
    if #targets == 0 then return false, "No such process" end
    for _, p in ipairs(targets) do
        if process.get(p.pid) == p then sig_impl.deliver(p, sig) end
    end
    return true
end

-- signal(2): sets the current process's disposition for `sig` to a handler
-- function, "ignore" or "default" (nil). Returns the previous one.
---@param sig integer
---@param handler function|string|nil
function process.signal(sig, handler)
    local proc = process.getCurrent()
    if not proc then return nil, "No process" end
    if not sig_impl.valid_signal(sig) then return nil, "Invalid signal" end
    if sig == 9 or sig == 19 then return nil, "Signal cannot be caught or ignored" end
    if handler == "default" then handler = nil end
    if handler ~= nil and handler ~= "ignore" and type(handler) ~= "function" then
        return nil, "Invalid handler"
    end
    local previous = proc.sig_handlers[sig] or "default"
    proc.sig_handlers[sig] = handler
    return previous
end

-- setpgid(2): `pid` 0 is the caller, `pgid` 0 makes the target a group
-- leader. Only the caller or one of its children can be moved.
function process.setpgid(pid, pgid)
    local cur = process.getCurrent()
    if pid == 0 or pid == nil then
        if not cur then return false, "No process" end
        pid = cur.pid
    end
    local target = process.get(pid)
    if not target then return false, "No such process" end
    if cur and target.pid ~= cur.pid and target.parent ~= cur.pid then
        return false, "Operation not permitted"
    end
    if pgid == 0 or pgid == nil then pgid = target.pid end
    if math.type(pgid) ~= "integer" or pgid < 0 then return false, "Invalid argument" end
    for _, p in ipairs(processes) do
        if p.pid == target.pid then p.pgid = pgid end -- threads too
    end
    return true
end

function process.getpgid(pid)
    local proc
    if pid == 0 or pid == nil then proc = process.getCurrent() else proc = process.get(pid) end
    if not proc then return nil, "No such process" end
    return proc.pgid
end

-- for the sources after this one
proci.finish_process = finish_process
