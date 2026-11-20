-- Standalone regression tests for spawn/wait identity and stdio inheritance.
-- Run with: lua tests/process_spawn.lua
local file = assert(io.open("src/process.lua", "r"))
local source = file:read("*a")
file:close()

local programs, inherited = {}, nil
local old_loadfile, old = loadfile, {}
for _, key in ipairs({ "util", "vfs", "vfsk", "permission", "event", "printk", "process", "processes", "signals" }) do
    old[key] = _G[key]
end
util = {
    createEnv = function() return {} end,
    copyTable = function(t) local r = {}; for k, v in pairs(t or {}) do r[k] = v end; return r end,
}
vfs = {
    resolve = function(path) return path end,
    attributes = function() return { mode = 0, uid = 0, gid = 0 } end,
    exists = function(path) return programs[path] ~= nil end,
    can = function() return true end,
    realPath = function() return "/" end,
}
vfsk = {
    root = function() return {} end,
    consoleFds = function() return { "console-in", "console-out", "console-err" } end,
    inheritFds = function(parent, stdio)
        if stdio == nil then return parent end
        inherited = { parent = parent, stdio = stdio }
        local child = {}
        for dest = 0, 2 do
            local src = stdio[dest]
            if src == nil then src = dest end
            if parent[src + 1] ~= nil then child[dest + 1] = parent[src + 1] end
        end
        return child
    end,
    closeAllFds = function() end,
}
permission = { canSetUID = function() return false end, canSetGID = function() return false end }
event = { removeQueue = function() end }
printk = function() end
loadfile = function(path) return programs[path], programs[path] and nil or "missing program" end
assert(load(source .. "\nevent = _G.event", "process.lua"))()
local api = process

local function tick()
    local snapshot, dead = {}, {}
    for _, p in ipairs(api.getRunQueue()) do
        snapshot[#snapshot + 1] = { entry = p, owner = api.get(p.pid) }
    end
    for _, item in ipairs(snapshot) do
        local p = item.entry
        if item.owner and api.get(p.pid) == item.owner and item.owner.instance == p.instance then
            if api.resume(p) then dead[#dead + 1] = item end
        end
    end
    for _, item in ipairs(dead) do
        if api.get(item.entry.pid) == item.owner then api.kill(item.entry.pid) end
    end
    api.current = -1
end

local parent_pid, child_pid, child_instance, replacement_pid, waited
programs["/parent"] = function()
    local err
    child_pid, err, child_instance = api.spawn("/child", { "arg" }, { [0] = 2, [1] = 0 })
    assert(child_pid > 0 and not err and child_instance)
    local child = api.get(child_pid)
    assert(child.fd[1] == "console-err" and child.fd[2] == "console-in" and child.fd[3] == "console-err")
    assert(inherited.parent == api.get(parent_pid).fd and inherited.stdio[0] == 2)
    local wait_err, status = api.wait(child_pid, child_instance)
    waited = { wait_err, status }
end
programs["/child"] = function() return 23 end
programs["/replacement"] = function() return 4 end

local pid, err = api.exec("/parent", {})
assert(pid > 0, err)
parent_pid = pid
tick() -- parent starts child and waits
assert(not waited)
tick() -- child finishes before parent resumes
assert(api.get(child_pid) == nil)
-- Reuse the child's PID before the parent consumes the old completion record.
api.current = parent_pid
replacement_pid, err = api.exec("/replacement", {}, 3, nil, child_pid)
api.current = -1
assert(replacement_pid == child_pid, err or "child PID should have been reused")
tick() -- parent consumes the original instance's result
assert(waited and waited[1] == nil and waited[2] == 23)

-- Numeric normal return, explicit exit, and exceptions produce exit statuses.
local outcomes = {}
programs["/exit-parent"] = function()
    local p, _, instance = api.spawn("/exit")
    local e, s = api.wait(p, instance); outcomes.exit = { e, s }
    p, _, instance = api.spawn("/throw")
    e, s = api.wait(p, instance); outcomes.throw = { e, s }
end
programs["/exit"] = function() api.exit(7) end
programs["/throw"] = function() error("child failure") end
local exit_parent = assert(api.exec("/exit-parent", {}))
api.current = exit_parent
tick(); tick(); tick(); tick(); tick()
assert(outcomes.exit and outcomes.exit[1] == nil and outcomes.exit[2] == 7)
assert(outcomes.throw and type(outcomes.throw[1]) == "string" and outcomes.throw[2] == 1)

-- IO waits are targeted, are not released by ordinary events, and preserve a
-- wake that arrives while their process is suspended.
local channel, io_resumed = {}, false
programs["/io-waiter"] = function()
    api.blockIO(channel)
    io_resumed = true
end
local io_pid = assert(api.exec("/io-waiter", {}))
tick()
assert(api.get(io_pid).status == "waiting" and not io_resumed)
api.dispatchWaiting({ n = 1, "unrelated event" })
tick()
assert(not io_resumed, "events must not wake an IO waiter")
assert(api.suspend(io_pid))
assert(api.wakeIO(channel) == 1)
assert(api.get(io_pid).status == "suspended" and not io_resumed)
assert(api.resume_handle(io_pid))
tick()
assert(io_resumed, "resume should deliver a wake received while suspended")

loadfile = old_loadfile
for k, v in pairs(old) do _G[k] = v end
print("all process.spawn tests passed")
