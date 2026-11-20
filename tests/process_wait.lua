-- Standalone regression tests for process.wait. Run with: lua tests/process_wait.lua
local source_file = "src/process.lua"
local file = assert(io.open(source_file, "r"))
local process_source = file:read("*a")
file:close()

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

test("wait resumes parent after normal child return without event", function()
    local api, add, spawn, tick, cleanup = fresh()
    local child_pid, prompted = nil, false
    add("/parent", function()
        assert(api.wait(child_pid) == nil)
        prompted = true -- shell's next-prompt equivalent
    end)
    add("/child", function() return "done" end)
    local parent = spawn("/parent")
    api.current = parent
    child_pid = spawn("/child")
    tick()
    assert(not prompted)
    tick() -- no event: child death itself schedules its waiter
    assert(prompted)
    cleanup()
end)

test("wait handles os.exit, explicit kill, and errors", function()
    local api, add, spawn, tick, cleanup = fresh()
    local pid, outcome, completed
    add("/parent", function() outcome = api.wait(pid); completed = true end)
    add("/exit", function() api.exit(7) end)
    local parent = spawn("/parent")
    api.current = parent
    pid = spawn("/exit")
    tick(); tick()
    assert(completed and outcome == nil)
    cleanup()

    api, add, spawn, tick, cleanup = fresh()
    local killed, result, completed
    add("/parent", function() result = api.wait(killed); completed = true end)
    add("/child", function() coroutine.yield() end)
    parent = spawn("/parent")
    api.current = parent
    killed = spawn("/child")
    tick()
    assert(api.kill(killed))
    tick()
    assert(completed and result == nil)
    cleanup()

    api, add, spawn, tick, cleanup = fresh()
    local failed, failure
    add("/parent", function() failure = api.wait(failed) end)
    add("/child", function() error("child boom") end)
    parent = spawn("/parent")
    api.current = parent
    failed = spawn("/child")
    tick(); tick()
    assert(type(failure) == "string" and failure:find("child boom", 1, true))
    cleanup()
end)

test("already dead target and multiple waiters resolve once", function()
    local api, add, spawn, tick, cleanup = fresh()
    local target, a, b, results = nil, nil, nil, 0
    add("/waiter-a", function() api.wait(target); results = results + 1 end)
    add("/waiter-b", function() api.wait(target); results = results + 1 end)
    add("/child", function() end)
    a = spawn("/waiter-a")
    api.current = a; target = spawn("/child")
    b = spawn("/waiter-b")
    tick(); tick()
    assert(results == 2)
    assert(api.get(target) == nil)
    assert(api.wait(target) == nil)
    cleanup()
end)

test("PID reuse and suspended waiters keep their original target", function()
    local api, add, spawn, tick, cleanup = fresh()
    local target, completed = nil, false
    add("/parent", function() api.wait(target); completed = true end)
    add("/child", function() coroutine.yield() end)
    add("/replacement", function() end)
    local parent = spawn("/parent")
    api.current = parent
    target = spawn("/child")
    tick()
    assert(api.suspend(parent))
    assert(api.resume_handle(parent))
    assert(api.get(parent).status == "waiting", "resumed waiter must still wait for live target")
    assert(api.kill(target))
    api.current = -1
    local replacement = spawn("/replacement")
    assert(replacement == target, "test expects the PID to be reused")
    tick()
    assert(completed, "waiter must be released by original target exit")
    cleanup()
end)

test("scheduler snapshot skips a killed process after its PID is reused", function()
    local api, add, spawn, tick, cleanup = fresh()
    local victim_pid, stale_ran, replacement_ran
    add("/init", function()
        assert(api.kill(victim_pid))
        local replacement, err = api.exec("/replacement", {}, 3, nil, victim_pid)
        assert(replacement == victim_pid, err or "expected victim PID reuse")
    end)
    add("/victim", function() stale_ran = true end)
    add("/replacement", function() replacement_ran = true end)

    local init_pid = spawn("/init")
    assert(init_pid == 1)
    api.current = init_pid
    victim_pid = spawn("/victim")
    local victim_instance = api.get(victim_pid).instance

    tick()
    local replacement = api.get(victim_pid)
    assert(replacement and replacement.instance > victim_instance)
    assert(not stale_ran, "stale snapshot entry must not resume after PID reuse")
    tick()
    assert(replacement_ran, "replacement should run on the next scheduler tick")
    cleanup()
end)

test("event waiters stay asleep without events; duplicate enqueue is prevented", function()
    local api, add, spawn, tick, cleanup = fresh()
    local target, event_resumed, waiter_resumed = nil, false, false
    add("/event", function() coroutine.yield("__event_wait__"); event_resumed = true end)
    add("/parent", function() api.wait(target); waiter_resumed = true end)
    add("/child", function() end)
    local event_pid = spawn("/event")
    local parent = spawn("/parent")
    api.current = parent; target = spawn("/child")
    tick()
    assert(not event_resumed and not waiter_resumed)
    local ready_waiters = 0
    for _, proc in ipairs(api.getRunQueue()) do if proc.pid == parent then ready_waiters = ready_waiters + 1 end end
    assert(ready_waiters == 1, "resolved process waiter should be queued exactly once")
    tick()
    assert(waiter_resumed and not event_resumed)
    local run_queue = api.getRunQueue()
    for i = 1, #run_queue do
        for j = i + 1, #run_queue do assert(run_queue[i] ~= run_queue[j]) end
    end
    api.dispatchWaiting({ n = 1, "signal" })
    tick({ n = 1, "signal" })
    assert(event_resumed)
    assert(api.get(event_pid) == nil)
    cleanup()
end)

test("real shell prints the next prompt after ls exits without an event", function()
    local api, add, spawn, tick, cleanup = fresh()
    local shell_file = assert(io.open("root/usr/bin/sh.lua", "r"))
    local shell_source = shell_file:read("*a")
    shell_file:close()
    local output, reads = {}, 0
    local shell_env = setmetatable({}, { __index = _G })
    local shell_os = {
        getenv = function(key) return ({ HOME = "/root", PATH = "/usr/bin", USER = "test", HOSTNAME = "nexus", UID = "0", PS1 = "PROMPT> " })[key] end,
        setenv = function() end,
        exit = function(code) api.exit(code) end
    }
    local shell_io = {
        write = function(value) output[#output + 1] = tostring(value) end,
        stderr = { write = function() end },
        read = function()
            reads = reads + 1
            if reads == 1 then return "ls -al" end
            return coroutine.yield("__event_wait__")
        end
    }
    shell_env.os, shell_env.io = shell_os, shell_io
    shell_env.print = function(value) output[#output + 1] = tostring(value) .. "\n" end
    shell_env.require = function(name)
        if name == "colors" then return { green = "", bright_blue = "", reset = "", bold = "" } end
        if name == "filesystem" then
            return {
                exists = function(path) return path == "/usr/bin/ls" end,
                isDirectory = function() return false end,
                concat = function(...) return table.concat({...}, "/") end
            }
        end
        if name == "process" then return api end
        error("unexpected module " .. name)
    end
    add("/shell", function()
        return assert(load(shell_source, "sh.lua", "t", shell_env))()
    end)
    add("/usr/bin/ls", function() end)
    local shell_pid = spawn("/shell")
    tick()
    assert(reads == 1)
    tick() -- ls exits; process.wait releases the shell without an event
    tick() -- shell resumes from wait and yields at the end of its command loop
    tick() -- shell emits the next prompt, then waits for input
    assert(reads == 2)
    local prompts = 0
    for _, item in ipairs(output) do if item == "PROMPT> " then prompts = prompts + 1 end end
    assert(prompts == 2, "expected initial and post-command prompts")
    assert(api.get(shell_pid).status == "waiting", "shell should now wait for input event")
    cleanup()
end)

print("all process.wait tests passed")
