-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type process_manager
process_manager = {}

---@type table<integer, process>
local processes = {}

---@type integer
local next_pid = 1

local function alloc_pid()
    local pid = next_pid
    next_pid = next_pid + 1
    return pid
end

local function load_file(path)
    -- "Boot://" is the boot device itself: always readable without the VFS
    local boot_rel = path:match("^Boot://(.*)$")
    local display_path = path
    if boot_rel then
        path = "/" .. boot_rel
    end
    -- other "Alias://..." paths go through the VFS once it is up
    if not boot_rel and fs and path:match("^[%w_%-]+://") then
        local data, err = fs.read_file(path)
        if not data then
            error("failed to open '" .. path .. "': " .. tostring(err))
        end
        return data
    end
    -- Phase 1: use OC raw fs component directly (VFS not yet available)
    -- TODO: replace with fs.open() after filesystem_service is up
    local addr = computer.getBootAddress()
    local handle, err = component.invoke(addr, "open", path, "r")
    if not handle then
        error("failed to open '" .. display_path .. "': " .. tostring(err))
    end
    local buf = {}
    while true do
        local chunk = component.invoke(addr, "read", handle, math.huge)
        if not chunk then break end
        buf[#buf + 1] = chunk
    end
    component.invoke(addr, "close", handle)
    return table.concat(buf)
end

function process_manager.spawn(opts)
    arg(1, opts, "table")

    local src = load_file(opts.path)
    local fn, err = load(src, "@" .. opts.path, "t", _ENV)
    if not fn then
        error("failed to load '" .. opts.path .. "': " .. tostring(err))
    end

    local parent_pid = scheduler.current()
    local parent     = processes[parent_pid]

    local pid = alloc_pid()

    -- inherit parent capability set (shared mt references)
    local caps = {}
    if parent then
        for k, v in pairs(parent.caps) do
            caps[k] = v
        end
    end

    ---@type process
    local proc = {
        pid         = pid,
        path        = opts.path,
        parent      = parent_pid,
        children    = {},
        coroutine   = coroutine.create(fn),
        state       = "running",
        caps        = caps,
        owned       = {},
        event_queue = {},
        env         = opts.env or (parent and parent.env or {}),
        cwd         = opts.cwd or (parent and parent.cwd) or "System://",
        stdin       = opts.stdin  or (parent and parent.stdin),
        stdout      = opts.stdout or (parent and parent.stdout),
        stderr      = opts.stderr or (parent and parent.stderr),
        detached    = opts.detached or false,
        args        = opts.args or {},
    }

    processes[pid] = proc

    if parent then
        parent.children[#parent.children + 1] = pid
    end

    scheduler.register(proc)
    router.subscribe(pid)

    log.info("Process %d spawned (parent=%d, path=%s)", pid, parent_pid, opts.path)

    return pid
end

function process_manager.kill(pid, reason, code)
    arg(1, pid,    "number")
    arg(2, reason, "string", true)
    arg(3, code,   "number", true)
    reason = reason or "killed"

    local proc = processes[pid]
    if not proc then return end

    -- recursively kill or re-parent children
    for _, child_pid in ipairs({ table.unpack(proc.children) }) do
        local child = processes[child_pid]
        if child then
            if child.detached then
                process_manager.adopt(child_pid)
            else
                process_manager.kill(child_pid, "killed")
            end
        end
    end

    local parent_proc = processes[proc.parent]
    if parent_proc then
        for i, c in ipairs(parent_proc.children) do
            if c == pid then table.remove(parent_proc.children, i) break end
        end
    end

    proc.state = "dead"
    scheduler.unregister(pid)
    router.unsubscribe(pid)

    -- revoke capabilities created by this process (inherited ones stay valid)
    local owned = {}
    for mt in pairs(proc.owned) do owned[#owned + 1] = mt end
    for _, mt in ipairs(owned) do
        capability.revoke(mt)
    end

    processes[pid] = nil

    router.broadcast({
        type   = "process_died",
        pid    = pid,
        reason = reason,
        code   = code,
    })

    log.info("Process %d terminated (%s%s)", pid, reason, code and (", code=" .. code) or "")
end

function process_manager.reap(pid, reason, code)
    arg(1, pid,    "number")
    arg(2, reason, "string")
    arg(3, code,   "number", true)
    process_manager.kill(pid, reason, code)
end

---Terminate the calling process with an exit code (does not return).
function process_manager.exit(code)
    arg(1, code, "number", true)
    error({ nexus_exit = code or 0 }, 0)
end

---Block the calling process until `pid` dies. Returns its exit code,
---or nil, "timeout" / "gone".
function process_manager.wait(pid, timeout)
    arg(1, pid,     "number")
    arg(2, timeout, "number", true)
    if not processes[pid] then return nil, "gone" end
    local ev = event.pull("process_died", timeout, function(e) return e.pid == pid end)
    if not ev then return nil, "timeout" end
    return ev.code or (ev.reason == "exit" and 0 or nil), ev.reason
end

function process_manager.get(pid)
    arg(1, pid, "number")
    return processes[pid]
end

function process_manager.self()
    return scheduler.current()
end

function process_manager.current_proc()
    return processes[scheduler.current()]
end

function process_manager.children(pid)
    arg(1, pid, "number")
    local proc = processes[pid]
    if not proc then return {} end
    return proc.children
end

function process_manager.adopt(pid)
    arg(1, pid, "number")
    local proc = processes[pid]
    if not proc then return end
    local init = processes[0]
    if init then
        init.children[#init.children + 1] = pid
    end
    proc.parent = 0
end

function process_manager.list()
    return processes
end
