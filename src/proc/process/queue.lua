-- process/queue.lua - the process table, the run, wait, suspend and I/O
-- queues, the signal numbers and the traceback wrapper. First of the
-- proc/process sources (see properties.lua).

---@class process
process = {}
-- Internals the proc/process sources share (queues and helpers); kernel-private.
proci = {}
---@type process_entry[]
processes = {}
---@type table<integer, process_entry>
local process_map = setmetatable({}, { __mode = "v" })
---@type table<integer, boolean>
local used_pids = {}
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

-- for the sources after this one
proci.process_map = process_map
proci.used_pids = used_pids
proci.run_queue = run_queue
proci.spawn_completions = spawn_completions
proci.dequeue = dequeue
proci.enqueue_run = enqueue_run
proci.wait_queue = wait_queue
proci.suspend_queue = suspend_queue
proci.io_waiters = io_waiters
proci.dequeue_entry = dequeue_entry
proci.dequeue_process = dequeue_process
proci.enqueue = enqueue
