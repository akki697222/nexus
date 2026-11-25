-- process/run.lua - one scheduler pass: pending signals, resuming
-- processes, waking waiters; listing and looking up processes.

-- from the sources before this one
local process_map = proci.process_map
local run_queue = proci.run_queue
local wait_queue = proci.wait_queue
local io_waiters = proci.io_waiters
local enqueue = proci.enqueue
local dequeue = proci.dequeue
local dequeue_entry = proci.dequeue_entry
local enqueue_run = proci.enqueue_run
local sig_impl = proci.sig_impl
local finish_process = proci.finish_process

---@param proc process_entry
local function process_signals(proc, proc_idx)
    local pending = proc.signals
    if #pending == 0 then return end
    proc.signals = {}
    for _, sig in ipairs(pending) do
        local disposition = proc.sig_handlers[sig]
        if type(disposition) == "function" then
            local ok, err = pcall(disposition, sig)
            if not ok then printk("Process " .. proc.pid .. ": signal handler failed: " .. tostring(err), "warning") end
        elseif disposition ~= "ignore" then
            -- the handler was removed after the signal was queued
            if sig_impl.default_action(proc, sig) then return end
        end
        if not process.get(proc.pid) then return end
    end
end

---@param signal integer
---@param func fun()
function process.listenSignal(signal, func)
    return process.signal(signal, func)
end

---@param path string?
---@param parent process_entry?
---@return string?
function process.cwd(path, parent)
    local proc = parent or process.getCurrent()
    if not proc then return end
    if not path or path == "" then
        return vfs.realPath(proc.cwd)
    end
    path = vfs.resolve(path)
    local vnode = vfsk.lookup(path)
    if not vnode then return nil, "No such file or directory" end
    if not vfs.isDirectory(path) then return nil, "Not a directory" end
    if not vfs.can(path, "x") then return nil, "Permission denied" end
    proc.cwd = vnode
    local real = vfs.realPath(proc.cwd)
    proc.environ.PWD = real
    return real
end

---@param proc process_entry
---@param ev table
---@return boolean dead
function process.resume(proc, ev)
    if proc.status == "suspended" then return false end
    if proc.status == "dead" then return true end

    process.current = proc.pid

    if proc.status == "waiting" and (not ev or ev.n == 0) then
        return false
    end

    if coroutine.status(proc.thread) == "dead" then
        finish_process(proc, 0)
        return true
    end

    local idx = -1
    for i, p in ipairs(processes) do
        if p.pid == proc.pid then idx = i; break end
    end
    if idx ~= -1 then
        process_signals(proc, idx)
    end

    if not process.get(proc.pid) then return true end

    local args = proc.arguments
    if proc.status == "waiting" and ev and ev.n > 0 then
        args = ev
    end

    local ok, ret = coroutine.resume(proc.thread, table.unpack(args))
    if not ok then
        -- Scheduler diagnostics must use the kernel console, not the failed
        -- process's possibly piped descriptors or suspended coroutine.
        local old_current = process.current
        process.current = -1
        printk("Process " .. proc.pid .. " Exited on error: " .. tostring(ret), "warning")
        process.current = old_current
        finish_process(proc, 1)
        return true
    end

    -- A normal function return does not yield a scheduler sentinel. Notice its
    -- dead coroutine now so waiters are released in this same scheduler pass.
    if coroutine.status(proc.thread) == "dead" then
        finish_process(proc, ret)
        return true
    end

    if ret == "__exit__" then
        finish_process(proc, proc.requested_exit_status or 0)
        return true
    elseif ret == "__process_wait__" then
        dequeue(run_queue, proc.pid)
        proc.status = "waiting"
    elseif ret == "__event_wait__" then
        dequeue(run_queue, proc.pid)
        proc.status = "waiting"
        enqueue(wait_queue, proc)
    elseif ret == "__process_io_wait__" then
        if proc.io_wait_channel ~= nil then
            dequeue_entry(run_queue, proc)
            proc.status = "waiting"
            local waiters = io_waiters[proc.io_wait_channel]
            if not waiters then waiters = {}; io_waiters[proc.io_wait_channel] = waiters end
            enqueue(waiters, proc)
        else
            -- User code may yield arbitrary strings; only blockIO can set the
            -- matching private channel before yielding this scheduler marker.
            proc.status = "running"
        end
    else
        proc.status = "running"
    end

    return false
end

-- Wakes event waiters that have something to do: queued events, an
-- expired pull timeout or a due handler (event.wants). Called on every
-- scheduler pass, with or without a signal, so timeouts fire while idle.
function process.dispatchWaiting(ev)
    local wants = event and event.wants
    local now = wants and computer.uptime()
    local to_run = {}
    for _, proc in ipairs(wait_queue) do
        if not proc.wait_target then
            if wants then
                if wants(proc, now, ev) then to_run[#to_run + 1] = proc end
            elseif ev and ev.n > 0 then
                to_run[#to_run + 1] = proc
            end
        end
    end
    for _, proc in ipairs(to_run) do
        dequeue_entry(wait_queue, proc)
        proc.status = "running"
        enqueue_run(proc)
    end
end

---@return process_entry[]
function process.list()
    local result = {}
    for _, proc in ipairs(processes) do
        table.insert(result, {
            pid = proc.pid,
            instance = proc.instance,
            uid = proc.uid,
            status = proc.status,
            tty = proc.tty,
            path = proc.path,
            arguments = proc.arguments,
            nice = proc.nice
        })
    end
    return result
end

---@return process_entry|nil
function process.get(pid)
    return process_map[pid]
end

function process.getRunQueue()
    return run_queue
end
