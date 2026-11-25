-- Unix signals: dispositions, default actions, process groups.
-- Run from the Nexus directory: lua tests/kernel/signals.lua
local process_source = dofile("tests/lib/kernel.lua").source("process")

local function fresh()
    local programs = {}
    local old_loadfile = loadfile
    local old_globals = {}
    local keys = { "util", "vfs", "vfsk", "permission", "event", "printk", "process", "processes", "signals" }
    for _, key in ipairs(keys) do old_globals[key] = _G[key] end

    util = {
        createEnv = function() return {} end,
        copyTable = function(t)
            local result = {}
            for k, v in pairs(t or {}) do result[k] = v end
            return result
        end
    }
    vfs = {
        resolve = function(path) return path end,
        realPath = function() return "/" end,
        attributes = function() return { mode = 0, uid = 0, gid = 0 } end,
        exists = function() return true end,
        can = function() return true end
    }
    vfsk = {
        root = function() return {} end,
        consoleFds = function() return {} end,
        inheritFds = function() return {} end,
        closeAllFds = function() end
    }
    permission = { canSetUID = function() return false end, canSetGID = function() return false end }
    event = { removeQueue = function() end }
    printk = function() end
    loadfile = function(path)
        local program = programs[path]
        if not program then return nil, "missing stub program: " .. path end
        return program
    end

    local chunk = assert(load(process_source .. "\nevent = _G.event", "process.lua"))
    chunk()
    local api = process
    local function add(path, fn) programs[path] = fn end
    local function spawn(path)
        local pid, err = api.exec(path, {})
        assert(pid > 0, err)
        return pid
    end
    local function tick(ev)
        local snapshot = {}
        for _, proc in ipairs(api.getRunQueue()) do
            snapshot[#snapshot + 1] = { entry = proc, owner = api.get(proc.pid) }
        end
        local dead = {}
        for _, item in ipairs(snapshot) do
            local proc = item.entry
            if item.owner and item.owner.instance == proc.instance and api.get(proc.pid) == item.owner then
                if api.resume(proc, ev) then dead[#dead + 1] = item end
            end
        end
        for _, item in ipairs(dead) do
            local proc = item.entry
            if item.owner and item.owner.instance == proc.instance and api.get(proc.pid) == item.owner then
                api.kill(proc.pid)
            end
        end
        api.current = -1
    end
    local function cleanup()
        loadfile = old_loadfile
        for _, key in ipairs(keys) do _G[key] = old_globals[key] end
    end
    return api, add, spawn, tick, cleanup
end

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then io.stderr:write("FAIL ", name, "\n", err, "\n"); os.exit(1) end
    print("ok - " .. name)
end


-- A parent that waits for `child` and records its exit status.
local function waiter(api, add, spawn, child_path)
    local rec = {}
    add("/parent", function() rec.err, rec.status = api.wait(rec.pid); rec.done = true end)
    local parent = spawn("/parent")
    api.current = parent
    rec.pid = spawn(child_path)
    api.current = -1
    return rec, parent
end

test("default actions terminate with 128 + signal", function()
    local api, add, spawn, tick, cleanup = fresh()
    add("/loop", function() while true do coroutine.yield() end end)
    local rec = waiter(api, add, spawn, "/loop")
    tick()
    assert(api.kill(rec.pid, 2))
    assert(api.get(rec.pid) == nil, "SIGINT terminates at once")
    tick()
    assert(rec.done and rec.status == 130, tostring(rec.status))
    rec = waiter(api, add, spawn, "/loop")
    tick(); api.kill(rec.pid, 15); tick()
    assert(rec.status == 143)
    rec = waiter(api, add, spawn, "/loop")
    tick(); api.kill(rec.pid); tick()
    assert(rec.status == 137, "kill without a signal is SIGKILL")
    cleanup()
end)

test("SIGCHLD, SIGURG and SIGWINCH are ignored by default", function()
    local api, add, spawn, tick, cleanup = fresh()
    add("/loop", function() while true do coroutine.yield() end end)
    local pid = spawn("/loop")
    for _, sig in ipairs({ 17, 23, 28 }) do assert(api.kill(pid, sig)) end
    tick()
    assert(api.get(pid))
    cleanup()
end)

test("handlers run in the process; ignore drops; KILL and STOP are not catchable", function()
    local api, add, spawn, tick, cleanup = fresh()
    local got = {}
    add("/handler", function()
        assert(api.signal(2, function(sig) got[#got + 1] = sig end) == "default")
        assert(api.signal(15, "ignore") == "default")
        assert(api.signal(9, function() end) == nil, "SIGKILL")
        assert(api.signal(19, "ignore") == nil, "SIGSTOP")
        while true do coroutine.yield() end
    end)
    local pid = spawn("/handler")
    tick()
    api.kill(pid, 2); api.kill(pid, 15)
    tick()
    assert(got[1] == 2 and #got == 1 and api.get(pid), "handled and ignored")
    api.kill(pid, 9)
    assert(api.get(pid) == nil)
    cleanup()
end)

test("a handled signal wakes a process blocked in an event or IO wait", function()
    local api, add, spawn, tick, cleanup = fresh()
    local got, wakes = 0, 0
    add("/sleeper", function()
        api.signal(10, function() got = got + 1 end)
        while true do
            coroutine.yield("__event_wait__")
            wakes = wakes + 1
        end
    end)
    local pid = spawn("/sleeper")
    tick()
    assert(api.get(pid).status == "waiting")
    tick()
    assert(wakes == 0, "nothing to wake for")
    api.kill(pid, 10)
    tick()
    assert(got == 1 and wakes == 1, "woken to handle it")
    local channel = {}
    add("/reader", function()
        api.signal(10, function() got = got + 1 end)
        while true do api.blockIO(channel) end
    end)
    local reader = spawn("/reader")
    tick()
    api.kill(reader, 10)
    tick()
    assert(got == 2, "IO wait interrupted")
    assert(api.wakeIO(channel) == 1, "and waiting on its channel again")
    cleanup()
end)

test("handlers are reset by exec, ignored signals stay ignored", function()
    local api, add, spawn, tick, cleanup = fresh()
    local childPid
    add("/child", function() while true do coroutine.yield() end end)
    add("/parent", function()
        api.signal(2, function() end)
        api.signal(15, "ignore")
        childPid = api.exec("/child", {})
        while true do coroutine.yield() end
    end)
    spawn("/parent")
    tick()
    api.kill(childPid, 15)
    tick()
    assert(api.get(childPid), "SIGTERM still ignored")
    api.kill(childPid, 2)
    assert(api.get(childPid) == nil, "SIGINT back to the default")
    cleanup()
end)

test("SIGSTOP and SIGTSTP stop, SIGCONT continues", function()
    local api, add, spawn, tick, cleanup = fresh()
    local runs = 0
    add("/loop", function() while true do runs = runs + 1; coroutine.yield() end end)
    local pid = spawn("/loop")
    tick()
    api.kill(pid, 19)
    local before = runs
    tick(); tick()
    assert(runs == before and api.get(pid).status == "suspended")
    api.kill(pid, 18)
    tick()
    assert(runs == before + 1)
    api.kill(pid, 20)
    tick()
    assert(api.get(pid).status == "suspended")
    api.kill(pid, 18)
    cleanup()
end)

test("process groups: init leads one, children inherit, setpgid, kill(-pgid)", function()
    local api, add, spawn, tick, cleanup = fresh()
    local a, b, c
    add("/loop", function() while true do coroutine.yield() end end)
    add("/leader", function()
        assert(api.setpgid(0, 0))
        a = api.exec("/loop", {})
        b = api.exec("/loop", {})
        assert(api.setpgid(b, 0), "own child")
        while true do coroutine.yield() end
    end)
    local leader = spawn("/leader")
    assert(api.getpgid(leader) == leader, "started by the kernel: its own group")
    tick()
    assert(api.getpgid(a) == leader and api.getpgid(b) == b)
    c = spawn("/loop")
    api.current = a
    assert(not api.setpgid(c, 0), "not a child")
    api.current = -1
    assert(api.kill(-leader, 2))
    assert(api.get(leader) == nil and api.get(a) == nil and api.get(b) ~= nil)
    assert(select(2, api.kill(-424242, 2)) == "No such process")
    assert(select(2, api.kill(b, 99)) == "Invalid signal")
    cleanup()
end)

print("signal tests passed")
