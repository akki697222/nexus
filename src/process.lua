---@class process
process = {}
---@type process_entry[]
processes = {}
---@type table<integer, process_entry>
local process_map = setmetatable({}, { __mode = "v" })
---@type table<integer, boolean>
local used_pids = {}
local next_instance = 1
process.current = -1

local run_queue     = {}
local wait_queue    = {}
local suspend_queue = {}
local io_waiters    = {}
-- Spawn completion records belong to the parent process instance. They live
-- until consumed by wait or until that parent exits.
local spawn_completions = {}

local function sort_run_queue()
    table.sort(run_queue, function(a, b)
        return (a.nice or 3) < (b.nice or 3)
    end)
end

local function enqueue(queue, proc)
    for _, queued in ipairs(queue) do
        if queued == proc then return end
    end
    table.insert(queue, proc)
end

local function dequeue(queue, pid)
    for i, p in ipairs(queue) do
        if p.pid == pid then
            table.remove(queue, i)
            return p
        end
    end
    return nil
end

local function dequeue_entry(queue, entry)
    for i, queued in ipairs(queue) do
        if queued == entry then
            table.remove(queue, i)
            return true
        end
    end
    return false
end

local function dequeue_process(queue, proc)
    for i = #queue, 1, -1 do
        local queued = queue[i]
        if queued.pid == proc.pid and queued.instance == proc.instance then
            table.remove(queue, i)
        end
    end
end

local function enqueue_run(proc)
    enqueue(run_queue, proc)
    sort_run_queue()
end

---@type util
util = util

---@type event
local event

---@type signal
signals = {
    SIGHUP    = 1,
    SIGINT    = 2,
    SIGQUIT   = 3,
    SIGILL    = 4,
    SIGTRAP   = 5,
    SIGABRT   = 6,
    SIGBUS    = 7,
    SIGFPE    = 8,
    SIGKILL   = 9,
    SIGUSR1   = 10,
    SIGSEGV   = 11,
    SIGUSR2   = 12,
    SIGPIPE   = 13,
    SIGALRM   = 14,
    SIGTERM   = 15,
    SIGSTKFLT = 16,
    SIGCHLD   = 17,
    SIGCONT   = 18,
    SIGSTOP   = 19,
    SIGTSTP   = 20,
    SIGTTIN   = 21,
    SIGTTOU   = 22,
    SIGURG    = 23,
    SIGXCPU   = 24,
    SIGXFSZ   = 25,
    SIGVTALRM = 26,
    SIGPROF   = 27,
    SIGWINCH  = 28,
    SIGIO     = 29,
    SIGPWR    = 30,
    SIGSYS    = 31,
}

---@class process_entry
---@field thread thread process coroutine thread
---@field pid integer process id
---@field instance integer unique process instance id
---@field tid integer thread id
---@field pgid integer process group id
---@field path string process executable path
---@field env table process lua environment
---@field nice integer nice value(process priority)
---@field parent integer parent process pid
---@field arguments table process arguments
---@field status string process status
---@field uid integer user id
---@field gid integer group id
---@field euid integer effective user id
---@field suid integer saved user id
---@field egid integer effective group id
---@field sgid integer saved group id
---@field cwd vnode current working directory
---@field signals integer[] process signal buffer
---@field fd vfs_descriptor[] process opening descriptors
---@field sig_handlers table<integer, function> process signal handlers
---@field tty integer tty device id
---@field err string?
---@field environ table<string, string>

---@param func function
---@param proc process_entry?
---@return thread
function wrap_with_traceback(func, proc)
    return coroutine.create(function(...)
        local ok, result = xpcall(func, debug.traceback, ...)
        if not ok then
            if proc then
                proc.err = result
            end
            error(result)
        end
        return result
    end)
end

local function get_default_signal_handlers(pid)
    local kernel_sig_handlers = {
        [2] = function()
            process.kill(pid)
        end,
        [15] = function()
            process.kill(pid)
        end
    }
    return kernel_sig_handlers
end

local function get_pid()
    local pid = 1
    while true do
        if not used_pids[pid] then
            used_pids[pid] = true
            return pid
        end
        pid = pid + 1
    end
end

function process.getCurrent()
    if process.current == -1 then return nil end
    for _, value in ipairs(processes) do
        if value.pid == process.current then
            return value
        end
    end
end

local function getCurrentExecutionEntry()
    local running = coroutine.running()
    if running then
        for _, entry in ipairs(processes) do
            if entry.thread == running then return entry end
        end
    end
    return process.getCurrent()
end

function process.getCurrentPID()
    return process.current
end

function process.getParent()
    return process.get(process.getCurrent().parent)
end

function process.getParentPID()
    local p = process.getParent()
    return p and p.pid or -1
end

---@param k string?
---@return string|table|nil
function process.getEnviron(k)
    local proc = process.getCurrent()
    if not proc then return nil end
    if k == nil then
        return proc.environ
    end
    return proc.environ[k]
end

function process.setEnviron(k, v)
    local proc = process.getCurrent()
    if proc then
        proc.environ[k] = v
    end
end

-- setuid(2)/setgid(2) semantics: a privileged process sets real, effective
-- and saved ids; an unprivileged one may only switch its effective ids to
-- its real or saved ones.
---@param usr user_passwd
---@return boolean
---@return string|nil
function process.setuser(usr)
    local proc = process.getCurrent()
    if not proc then return false, "No such process" end
    if proc.euid == 0 then
        proc.uid, proc.euid, proc.suid = usr.uid, usr.uid, usr.uid
        proc.gid, proc.egid, proc.sgid = usr.gid, usr.gid, usr.gid
        return true
    end
    local uidOk = usr.uid == proc.uid or usr.uid == proc.suid
    local gidOk = usr.gid == proc.gid or usr.gid == proc.sgid
    if not (uidOk and gidOk) then return false, "Operation not permitted" end
    proc.euid, proc.egid = usr.uid, usr.gid
    return true
end

---@param path string
---@param args table|nil
---@param nice integer|nil
---@param env table|nil
---@param pid integer|nil
local function exec(path, args, nice, env, pid, uid, gid, stdio, tracked_spawn)
    if nice ~= nil and type(nice) ~= "number" then
        return -1, "Invalid priority"
    end
    local current = process.getCurrent()
    -- choosing the pid or the credentials of the new process is privileged
    if current and current.euid ~= 0 then
        pid, uid, gid = nil, nil, nil
    end
    path = vfs.resolve(path)
    ---@type vnode|nil
    local attr = vfs.attributes(path)
    if not vfs.exists(path) or not attr then
        return -1, "No such file"
    end
    if not vfs.can(path, "x") then
        return -1, "Permission denied"
    end
    if pid and process_map[pid] then
        return -1, "Process exists"
    end
    local cwd = vfsk.root()
    if current then
        cwd = current.cwd
        uid = uid or current.uid
        gid = gid or current.gid
    else
        uid = uid or 0
        gid = gid or 0
    end
    local parent = current or
        { pid = 0, pgid = 0, uid = uid, gid = gid, euid = 0, suid = 0, egid = 0, sgid = 0, environ = {} }
    -- execve(2): set-user/group-ID bits change the effective ids, and the
    -- saved ids take the new effective ones
    local euid, egid = parent.euid, parent.egid
    if permission.canSetUID(attr.mode) then euid = attr.uid end
    if permission.canSetGID(attr.mode) then egid = attr.gid end
    local suid, sgid = euid, egid
    -- a privilege-raising exec never runs in an environment the caller built
    if euid ~= parent.euid or egid ~= parent.egid then
        env = nil
        -- Do not carry caller-owned tables or metatables into a more privileged
        -- process. Inspect raw keys so __len, __index, and __pairs cannot run.
        if args ~= nil and type(args) ~= "table" then
            return -1, "Invalid arguments"
        end
        local copied_args = {}
        local max_arg = 0
        for key, value in next, args or {} do
            if type(key) ~= "number" or key < 1 or key > 65536 or key % 1 ~= 0
                or type(value) ~= "string" then
                return -1, "Invalid arguments"
            end
            if key > max_arg then max_arg = key end
            copied_args[key] = value
        end
        for index = 1, max_arg do
            if rawget(copied_args, index) == nil then
                return -1, "Invalid arguments"
            end
        end
        args = copied_args
    end
    env = env or util.createEnv()
    local func, err = loadfile(path, "bt", env)
    if not func then
        return -1, err
    end
    local allocated_pid = pid == nil
    local pid = pid or get_pid()
    used_pids[pid] = true
    local instance = next_instance
    next_instance = next_instance + 1
    ---@type process_entry
    local inherited_fds, fd_err
    if current and stdio ~= nil then
        inherited_fds, fd_err = vfsk.inheritFds(current.fd, stdio)
        if not inherited_fds then
            if allocated_pid then used_pids[pid] = nil end
            return -1, fd_err or "Failed to inherit file descriptors"
        end
    elseif current then
        inherited_fds = vfsk.inheritFds(current.fd)
    else
        inherited_fds = vfsk.consoleFds()
    end
    local entry = {
        pid = pid,
        instance = instance,
        tid = pid,
        pgid = parent.pgid or 1,
        path = path,
        env = env,
        nice = nice or 3,
        parent = parent.pid,
        arguments = args or {},
        cwd = cwd,
        uid = uid,
        gid = gid,
        euid = euid,
        suid = suid,
        egid = egid,
        sgid = sgid,
        signals = {},
        -- descriptors are inherited across exec; spawn may remap the child stdio
        fd = inherited_fds,
        sig_handlers = get_default_signal_handlers(pid),
        tty = 0,
        status = "running",
        environ = util.copyTable(parent.environ)
    }
    if tracked_spawn then
        entry.spawn_parent_instance = current and current.instance or nil
        entry.spawn_tracked = true
        if current then
            spawn_completions[current.instance] = spawn_completions[current.instance] or {}
        end
    end
    entry.thread = wrap_with_traceback(func, entry)

    table.insert(processes, entry)
    process_map[pid] = entry
    enqueue_run(entry)

    return pid
end

---@param path string
---@param args table|nil
---@param nice integer|nil
---@param env table|nil
---@param pid integer|nil
function process.exec(path, args, nice, env, pid, uid, gid)
    return exec(path, args, nice, env, pid, uid, gid, nil, false)
end

-- A spawn is deliberately a small exec surface: callers can select argv and
-- descriptor mappings, but cannot provide an environment or credentials.
function process.spawn(path, args, stdio)
    if stdio == nil then stdio = {} end
    local pid, err = exec(path, args, nil, nil, nil, nil, nil, stdio, true)
    if pid == -1 then return pid, err end
    local child = process.get(pid)
    if child then return pid, nil, child.instance end
    return pid
end

function process.wait(pid, instance)
    local proc = process.getCurrent()
    local target = process.get(pid)
    local owned = proc and spawn_completions[proc.instance]
    if instance ~= nil then
        if type(instance) ~= "number" or instance % 1 ~= 0 then return "No such process", nil end
        if target and target.instance == instance then
            -- wait below on the exact live entry
        else
            local result = owned and owned[instance]
            if result and result.pid == pid then
                owned[instance] = nil
                return result.err, result.status
            end
            return "No such process", nil
        end
    end
    if not target and owned then
        for child_instance, result in pairs(owned) do
            if result.pid == pid then
                owned[child_instance] = nil
                return result.err, result.status
            end
        end
    end
    if not target then return end
    if target.status == "dead" then
        if owned and target.spawn_parent_instance == proc.instance then owned[target.instance] = nil end
        return target.err, target.exit_status
    end
    if not proc then return end

    -- Keep the target entry itself: its PID may be reused after it exits.
    proc.wait_target = target
    proc.wait_spawn_instance = target.spawn_tracked and target.spawn_parent_instance == proc.instance
        and target.instance or nil
    proc.wait_result = nil
    dequeue(run_queue, proc.pid)
    proc.status = "waiting"
    coroutine.yield("__process_wait__")
    local result = proc.wait_result
    local status = proc.wait_status
    local completed_instance = proc.wait_spawn_instance
    proc.wait_result = nil
    proc.wait_status = nil
    proc.wait_spawn_instance = nil
    local completions = spawn_completions[proc.instance]
    if completed_instance and completions then completions[completed_instance] = nil end
    return result, status
end

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
    process.kill(proc.pid)
    coroutine.yield("__exit__")
end

function process.kill(pid)
    local proc = process.get(pid)
    if not proc then
        return false, "No such process"
    end

    -- Resolve waiters while this exact process entry is still registered and
    -- before its PID can be allocated to another process.
    finish_process(proc, proc.requested_exit_status or 137)

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

-- Kernel-only targeted IO wait. A channel is an opaque kernel-owned identity;
-- this API is removed from user and module process environments in env.lua.
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

---@param proc process_entry
local function process_signals(proc, proc_idx)
    local handlers = {}
    for sig, handler in pairs(proc.sig_handlers) do
        handlers[tostring(sig)] = handler
    end
    for _, value in ipairs(proc.signals) do
        if value == 19 or value == 9 then
            process.kill(proc.pid)
            return
        end
        local handle = handlers[tostring(value)]
        if type(handle) == "function" then
            handle()
        end
    end
    proc.signals = {}
end

---@param signal integer
---@param func fun()
function process.listenSignal(signal, func)
    local proc = process.getCurrent()
    if not proc then return end
    proc.sig_handlers[signal] = func
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
        printk("Process " .. proc.pid .. " Exited on error: " .. tostring(ret))
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
