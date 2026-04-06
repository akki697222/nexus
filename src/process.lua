---@class process
process = {}
---@type process_entry[]
processes = {}
---@type table<integer, boolean>
local used_pids = {}
process.current = -1

---@type util
util = util

---@type event
local event

---@type signal
signals = {
    SIGHUP    = 1,  -- Hangup detected on controlling terminal or death of controlling process
    SIGINT    = 2,  -- Interrupt from keyboard (Ctrl+C)
    SIGQUIT   = 3,  -- Quit from keyboard
    SIGILL    = 4,  -- Illegal Instruction
    SIGTRAP   = 5,  -- Trace/breakpoint trap
    SIGABRT   = 6,  -- Abort signal from abort(3)
    SIGBUS    = 7,  -- Bus error (bad memory access)
    SIGFPE    = 8,  -- Floating point exception
    SIGKILL   = 9,  -- Kill signal (cannot be caught or ignored)
    SIGUSR1   = 10, -- User-defined signal 1
    SIGSEGV   = 11, -- Invalid memory reference
    SIGUSR2   = 12, -- User-defined signal 2
    SIGPIPE   = 13, -- Broken pipe: write to pipe with no readers
    SIGALRM   = 14, -- Timer signal from alarm(2)
    SIGTERM   = 15, -- Termination signal
    SIGSTKFLT = 16, -- Stack fault on coprocessor (obsolete)
    SIGCHLD   = 17, -- Child stopped or terminated
    SIGCONT   = 18, -- Continue if stopped
    SIGSTOP   = 19, -- Stop process (cannot be caught or ignored)
    SIGTSTP   = 20, -- Stop typed at tty (Ctrl+Z)
    SIGTTIN   = 21, -- tty input for background process
    SIGTTOU   = 22, -- tty output for background process
    SIGURG    = 23, -- Urgent condition on socket
    SIGXCPU   = 24, -- CPU time limit exceeded
    SIGXFSZ   = 25, -- File size limit exceeded
    SIGVTALRM = 26, -- Virtual alarm clock
    SIGPROF   = 27, -- Profiling timer expired
    SIGWINCH  = 28, -- Window resize signal
    SIGIO     = 29, -- I/O now possible
    SIGPWR    = 30, -- Power failure (System V)
    SIGSYS    = 31, -- Bad system call (SVr4)
}

---@class process_entry
---@field thread thread process coroutine thread
---@field pid integer process id
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
local function wrap_with_traceback(func, proc)
    return coroutine.create(function(...)
        local function err_handler(err)
            return debug.traceback(err, 2)
        end
        local ok, result = xpcall(func, err_handler, ...)
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
    for index, value in ipairs(processes) do
        if value.pid == process.current then
            return value
        end
    end
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
---@return string|table|nil # when k==nil but process exists, returning current environ table
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
        -- printk("setenv: pid " .. proc.pid .. " " .. tostring(k) .. "=" .. tostring(v))
        proc.environ[k] = v
    end
end

---@param usr user_passwd
function process.setuser(usr)
    local proc = process.getCurrent()
    proc.uid = usr.uid
    proc.euid = usr.uid
    proc.suid = usr.uid
    proc.gid = usr.gid
    proc.egid = usr.gid
    proc.sgid = usr.gid
end

---@param path string
---@param args table|nil
---@param nice integer|nil
---@param env table|nil
---@param pid integer|nil
function process.exec(path, args, nice, env, pid, uid, gid)
    env = env or util.createEnv()
    path = vfs.resolve(path)
    ---@type vnode|nil
    local attr = vfs.attributes(path)
    if not vfs.exists(path) or not attr then
        return -1, "No such file"
    end
    if not vfs.can(path, "x") then
        return -1, "Permission Denied"
    end
    local func, err = loadfile(path)
    if not func then
        return -1, err
    end
    local pid = pid or get_pid()
    if not func then return end
    local cwd = vfs.root()
    local current = process.getCurrent()
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
    local euid = parent.euid
    local suid = parent.suid
    if permission.canSetUID(attr.mode) then
        euid = attr.uid
        euid = attr.uid
    end
    ---@type process_entry
    local entry = {
        thread = wrap_with_traceback(func),
        pid = pid,
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
        egid = parent.egid,
        sgid = parent.sgid,
        signals = {},
        fd = {
            {
                vnode = devfs.attributes("stdin") --[[@as vnode]],
                fd = 0,
                flag = "r"
            },
            {
                vnode = devfs.attributes("stdout") --[[@as vnode]],
                fd = 1,
                flag = "w"
            },
            {
                vnode = devfs.attributes("stderr") --[[@as vnode]],
                fd = 2,
                flag = "w"
            }
        },
        sig_handlers = get_default_signal_handlers(pid),
        tty = 0,
        status = "running",
        environ = util.copyTable(parent.environ)
    }

    table.insert(processes, entry)

    return pid
end

function process.wait(pid)
    while true do
        local proc = process.get(pid)
        if proc == nil or proc.status == "dead" then
            break
        elseif proc ~= nil and proc.err then
            return proc.err
        end
        coroutine.yield("__event_wait__")
    end
end

function process.exit(code)
    -- code is ignored for now
    process.kill(process.current)
end

function process.kill(pid)
    local idx = -1
    for index, value in ipairs(processes) do
        if value.pid == pid then
            idx = index
            break
        end
    end
    if idx ~= -1 then
        table.remove(processes, idx)
        event.removeQueue(pid)
        used_pids[pid] = nil
        return true
    else
        return false, "No such process"
    end
end

function process.suspend(pid)
    local proc = process.get(pid)
    if proc then
        proc.status = "suspended"
        return true
    end
    return false, "No such process"
end

function process.resume_handle(pid)
    local proc = process.get(pid)
    if proc then
        if proc.status == "suspended" then
            proc.status = "running"
            return true
        end
        return false, "Process is not suspended"
    end
    return false, "No such process"
end

function process.createThread(func, name, ...)
    local parent = process.getCurrent()
    if not parent then return -1, "No parent process" end

    local tid = get_pid()

    ---@type process_entry
    local thread_entry = {
        thread = wrap_with_traceback(func),
        pid = parent.pid,
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
    return tid
end

---@param proc process_entry
local function process_signals(proc, proc_idx)
    local handlers = {}
    for sig, handler in pairs(proc.sig_handlers) do
        handlers[tostring(sig)] = handler
    end
    for index, value in ipairs(proc.signals) do
        if value == 19 or value == 9 then
            table.remove(processes, proc_idx)
        end
        local handle = handlers[tostring(value)]
        if type(handle) == "function" then
            handle()
        end
    end
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
    --printk("cwd: current: " .. (vfs.realPath(proc.cwd) or "nil"))
    if not path or path == "" then
        return vfs.realPath(proc.cwd)
    end --fallback
    local vnode = vfs.attributes(path)
    proc.cwd = vnode or vfs.root()
    local real = vfs.realPath(proc.cwd)
    proc.environ.PWD = real
    --printk("cwd: updated: " .. (vfs.realPath(proc.cwd) or "nil"))
    return real
end

---@param proc process_entry
function process.resume(proc, ev)
    if proc.status == "suspended" then return false end
    if proc.status == "dead" then return true end

    process.current = proc.pid

    -- Check if process actually needs an event
    if proc.status == "waiting" and (not ev or ev.n == 0) then
        return false
    end

    local index = -1
    for i, value in ipairs(processes) do
        if value.pid == proc.pid then
            index = i
            break
        end
    end

    if coroutine.status(proc.thread) == "dead" then
        proc.status = "dead"
        return true
    end

    process_signals(proc, index)

    -- Prepare resume arguments
    local args = proc.arguments
    if proc.status == "waiting" and ev and ev.n > 0 then
        args = ev
    end

    local ok, ret = coroutine.resume(proc.thread, table.unpack(args))
    if not ok then
        printk("Process " .. proc.pid .. " Exited on error: " .. ret)
        proc.status = "dead"
        return true
    end

    if ret == "__event_wait__" then
        proc.status = "waiting"
    else
        proc.status = "running"
    end

    return false
end

---@return process_entry[]
function process.list()
    local result = {}
    for _, proc in ipairs(processes) do
        table.insert(result, {
            pid = proc.pid,
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
    for index, value in ipairs(processes) do
        if value.pid == pid then
            return value
        end
    end
end

-- OpenOS APIs
