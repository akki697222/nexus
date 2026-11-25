-- process/block.lua - blocking on I/O and waking, suspending and
-- resuming, kernel-side threads of a process.

-- from the sources before this one
local run_queue = proci.run_queue
local wait_queue = proci.wait_queue
local suspend_queue = proci.suspend_queue
local io_waiters = proci.io_waiters
local enqueue = proci.enqueue
local dequeue = proci.dequeue
local enqueue_run = proci.enqueue_run
local get_pid = proci.get_pid
local getCurrentExecutionEntry = proci.getCurrentExecutionEntry

-- Kernel-only targeted IO wait. A channel is an opaque kernel-owned identity;
-- this API is removed from user process environments in env.lua (kernel modules such as the tty input queue use it).
function process.blockIO(channel)
    if channel == nil then error("Invalid IO wait channel", 2) end
    local proc = getCurrentExecutionEntry()
    if not proc then error("IO wait requires a process", 2) end
    proc.io_wait_channel = channel
    coroutine.yield("__process_io_wait__")
end

function process.wakeIO(channel)
    local waiters = io_waiters[channel]
    if not waiters then return 0 end
    io_waiters[channel] = nil
    local count = 0
    for _, waiter in ipairs(waiters) do
        if waiter.io_wait_channel == channel then
            waiter.io_wait_channel = nil
            if waiter.status == "suspended" then
                waiter.io_ready = true
            elseif waiter.status == "waiting" then
                waiter.status = "running"
                enqueue_run(waiter)
            end
            count = count + 1
        end
    end
    return count
end

function process.suspend(pid)
    local proc = process.get(pid)
    if not proc then return false, "No such process" end

    dequeue(run_queue, pid)
    dequeue(wait_queue, pid)
    proc.status = "suspended"
    enqueue(suspend_queue, proc)
    return true
end

function process.resume_handle(pid)
    local proc = process.get(pid)
    if not proc then return false, "No such process" end
    if proc.status ~= "suspended" then
        return false, "Process is not suspended"
    end

    dequeue(suspend_queue, pid)
    if proc.wait_target then
        -- A suspended process waiter still waits for its original target.
        proc.status = "waiting"
        enqueue(wait_queue, proc)
        return true
    end
    if proc.io_wait_channel and not proc.io_ready then
        proc.status = "waiting"
        return true
    end
    if proc.io_ready then
        proc.io_ready = nil
        proc.io_wait_channel = nil
    end
    proc.status = "running"
    enqueue_run(proc)
    return true
end

function process.createThread(func, name, ...)
    local parent = process.getCurrent()
    if not parent then return -1, "No parent process" end

    local tid = get_pid()

    ---@type process_entry
    local thread_entry = {
        thread = wrap_with_traceback(func),
        pid = parent.pid,
        instance = parent.instance,
        tid = tid,
        pgid = parent.pgid,
        path = parent.path .. " [thread:" .. (name or tid) .. "]",
        env = parent.env,
        nice = parent.nice,
        parent = parent.pid,
        arguments = { ... },
        cwd = parent.cwd,
        uid = parent.uid,
        gid = parent.gid,
        euid = parent.euid,
        suid = parent.suid,
        egid = parent.egid,
        sgid = parent.sgid,
        signals = {},
        fd = parent.fd,
        sig_handlers = parent.sig_handlers,
        tty = parent.tty,
        status = "running",
        environ = util.copyTable(parent.environ)
    }

    table.insert(processes, thread_entry)
    enqueue_run(thread_entry)
    return tid
end
