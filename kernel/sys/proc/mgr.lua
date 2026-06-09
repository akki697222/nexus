-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type process_manager
local process_manager = {}

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
    -- Phase 1: use OC raw fs component directly (VFS not yet available)
    -- TODO: replace with fs.open() after filesystem_service is up
    local addr = computer.getBootAddress()
    local handle, err = component.invoke(addr, "open", path, "r")
    if not handle then
        error("failed to open '" .. path .. "': " .. tostring(err))
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
        parent      = parent_pid,
        children    = {},
        coroutine   = coroutine.create(fn),
        state       = "running",
        caps        = caps,
        event_queue = {},
        env         = opts.env or (parent and parent.env or {}),
        cwd         = parent and parent.cwd or "SYS://",
        detached    = opts.detached or false,
    }

    processes[pid] = proc

    if parent then
        parent.children[#parent.children + 1] = pid
    end

    scheduler.register(proc)
    router.subscribe(pid)

    -- push a bootstrap event so the process gets resumed on the first tick
    router.push_to(pid, { type = "process_spawned", pid = pid })

    log.info("Process %d spawned (parent=%d, path=%s)", pid, parent_pid, opts.path)

    return pid
end

function process_manager.kill(pid, reason)
    arg(1, pid,    "number")
    arg(2, reason, "string", true)
    reason = reason or "killed"

    local proc = processes[pid]
    if not proc then return end

    -- recursively kill or re-parent children
    for _, child_pid in ipairs(proc.children) do
        local child = processes[child_pid]
        if child then
            if child.detached then
                process_manager.adopt(child_pid)
            else
                process_manager.kill(child_pid, "killed")
            end
        end
    end

    proc.state = "dead"
    scheduler.unregister(pid)
    router.unsubscribe(pid)

    -- revoke all owned capabilities
    for _, mt in pairs(proc.caps) do
        capability.revoke(mt)
    end

    processes[pid] = nil

    router.broadcast({
        type   = "process_died",
        pid    = pid,
        reason = reason,
    })

    log.info("Process %d terminated (%s)", pid, reason)
end

function process_manager.reap(pid, reason, code)
    arg(1, pid,    "number")
    arg(2, reason, "string")
    arg(3, code,   "number", true)
    process_manager.kill(pid, reason)
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
