-- process/spawn.lua - pids, the current process, environment and user
-- switching, exec, spawn and wait.

-- from the sources before this one
local process_map = proci.process_map
local used_pids = proci.used_pids
local run_queue = proci.run_queue
local spawn_completions = proci.spawn_completions
local dequeue = proci.dequeue
local enqueue_run = proci.enqueue_run

-- Signal dispositions follow Unix: each signal has a default action
-- (term, core, ign, stop, cont), which a process may replace with a handler
-- function or "ignore" (process.signal). 9 and 19 cannot be
-- caught or ignored. "core" terminates like "term" (there are no dumps).
-- (kept in one table: the kernel is a single chunk with a limit of 200
-- top-level locals)
local sig_impl = {}
sig_impl.DEFAULT = {
    [1] = "term", [2] = "term", [3] = "core", [4] = "core", [5] = "core", [6] = "core",
    [7] = "core", [8] = "core", [9] = "term", [10] = "term", [11] = "core", [12] = "term",
    [13] = "term", [14] = "term", [15] = "term", [16] = "term", [17] = "ign", [18] = "cont",
    [19] = "stop", [20] = "stop", [21] = "stop", [22] = "stop", [23] = "ign", [24] = "core",
    [25] = "core", [26] = "term", [27] = "term", [28] = "ign", [29] = "term", [30] = "term",
    [31] = "core",
}

-- exec keeps ignored signals ignored and resets handlers to the default
function sig_impl.exec_handlers(parent_handlers)
    local handlers = {}
    for sig, disposition in pairs(parent_handlers or {}) do
        if disposition == "ignore" then handlers[sig] = "ignore" end
    end
    return handlers
end

-- instance numbers tell apart processes that reused a pid
local next_instance = 1

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
        -- a process started by the kernel (init) leads its own group
        pgid = current and parent.pgid or pid,
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
        sig_handlers = sig_impl.exec_handlers(parent.sig_handlers),
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

-- for the sources after this one
proci.sig_impl = sig_impl
proci.get_pid = get_pid
proci.getCurrentExecutionEntry = getCurrentExecutionEntry
