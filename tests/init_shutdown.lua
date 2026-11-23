-- Run with: lua tests/init_shutdown.lua
local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local source = read("root/usr/sbin/init.lua")

local function fresh(options)
    options = options or {}
    local events, logs = {}, {}
    local now, nextInstance, requested = 0, 1, nil
    local procs = {}
    local hooks = options.hooks or { "cleanup", "uname" }
    local startup = options.startup or { "alpha", "beta" }
    local serviceKinds = options.serviceKinds or {}
    local exitStatuses = options.exitStatuses or {}
    local hangingSpawns = options.hangingSpawns or {}

    local function allocatePid()
        local pid = 2
        while procs[pid] and procs[pid].alive do pid = pid + 1 end
        return pid
    end
    local function addProcess(path)
        local pid = allocatePid()
        local proc = { pid = pid, instance = nextInstance, path = path, alive = true, startedAfterRequest = requested ~= nil }
        nextInstance = nextInstance + 1
        procs[pid] = proc
        events[#events + 1] = { "exec", path, pid, proc.instance }
        return pid
    end

    local process = {
        listenSignal = function() end,
        exec = function(path)
            return addProcess(path)
        end,
        spawn = function(path)
            local pid = addProcess(path)
            local name = path:match("^/service/(.*)$")
            if not hangingSpawns[name] then procs[pid].alive = false end
            return pid, nil, procs[pid].instance
        end,
        wait = function(pid, instance)
            local proc = procs[pid]
            if not proc or proc.instance ~= instance then return "No such process", nil end
            proc.alive = false
            local exitStatus = exitStatuses[proc.path:match("^/service/(.*)$")] or 0
            events[#events + 1] = { "wait", proc.path, pid, instance, exitStatus }
            return nil, exitStatus
        end,
        get = function(pid)
            local proc = procs[pid]
            if proc and proc.alive then return proc end
        end,
        list = function()
            local result = {}
            for pid, proc in pairs(procs) do
                if proc.alive then
                    result[#result + 1] = { pid = pid, instance = proc.instance, path = proc.path }
                end
            end
            table.sort(result, function(a, b) return a.pid < b.pid end)
            return result
        end,
        kill = function(pid)
            local proc = procs[pid]
            if not proc or not proc.alive then return false, "No such process" end
            proc.alive = false
            events[#events + 1] = { "kill", proc.path, pid, proc.instance }
            return true
        end
    }

    local filesystem = {
        concat = function(a, b) return a .. "/" .. b end,
        exists = function(path) return path == "/etc/runlevels/default" or path == "/etc/runlevels/shutdown" end,
        isDirectory = function() return true end,
        list = function(path)
            local entries = path == "/etc/runlevels/default" and startup or
                (path == "/etc/runlevels/shutdown" and hooks or {})
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end
        end,
        attributes = function(path)
            if path:find("/runlevels/", 1, true) then return { type = "VREG" } end
            return { type = "VREG" }
        end
    }
    local serviceCatalog = {
        find = function(name)
            if not name:match("^[%w_][%w_%-]*$") then return nil, "Invalid service name" end
            return "/etc/init.d/" .. name
        end,
        read = function(path, name)
            if path ~= "/etc/init.d/" .. name then return nil, "missing " .. path end
            return {
                title = name, desc = "test service", execpath = "/service/" .. name,
                args = {}, oneshot = serviceKinds[name] == "oneshot"
            }
        end
    }
    local system = {
        config = { debug = false },
        shutdownRequested = function() return requested end,
        finishShutdown = function()
            events[#events + 1] = { "finish", requested }
            if options.finishFails and not options.finishFailed then
                options.finishFailed = true
                requested = nil
                return nil, "backend unavailable"
            end
            return true
        end
    }
    local colors = {
        green = "<green>", yellow = "<yellow>", red = "<red>", white = "<white>",
        reset = "</>", cyan = "<cyan>", bright_blue = "<blue>"
    }
    local user = { getUser = function() return true end }
    local computer = { uptime = function() return now end }
    local env = {
        _OSVERSION = "test", _NEXUS = true, _OSDIST = "test distro",
        require = function(name)
            local modules = {
                computer = computer, colors = colors, filesystem = filesystem,
                process = process, user = user, system = system,
                ["openoc.service"] = serviceCatalog
            }
            assert(modules[name], "unexpected require: " .. name)
            return modules[name]
        end,
        dofile = dofile,
        os = { getenv = function() return "test-host" end, setenv = function() end },
        io = { stderr = { write = function(_, message) logs[#logs + 1] = message end } },
        print = function(message) if message then logs[#logs + 1] = tostring(message) end end,
        tostring = tostring, type = type, pairs = pairs, ipairs = ipairs,
        pcall = pcall, error = error, assert = assert, string = string,
        table = table, math = math, coroutine = coroutine
    }
    local co = coroutine.create(assert(load(source, "init.lua", "t", env)))
    local function tick(completeHooks)
        now = now + 1
        if completeHooks then
            for _, proc in pairs(procs) do
                if proc.alive and proc.startedAfterRequest and proc.path:match("^/service/") then proc.alive = false end
            end
        end
        local ok, err = coroutine.resume(co)
        assert(ok, err)
        return coroutine.status(co)
    end
    local function request(mode) requested = mode end
    local function addBackground(path) return addProcess(path) end
    return {
        events = events, logs = logs, process = process, procs = procs,
        tick = tick, request = request, addBackground = addBackground,
        state = function() return coroutine.status(co) end
    }
end

local ordered = fresh({
    startup = { "prepare", "broken", "after" }, hooks = {},
    serviceKinds = { prepare = "oneshot", broken = "oneshot" },
    exitStatuses = { broken = 7 }
})
ordered.tick(false)
local prepareWait, brokenWait, afterExec
for i, event in ipairs(ordered.events) do
    if event[1] == "wait" and event[2] == "/service/prepare" then prepareWait = i end
    if event[1] == "wait" and event[2] == "/service/broken" then brokenWait = i end
    if event[1] == "exec" and event[2] == "/service/after" then afterExec = i end
end
assert(prepareWait and brokenWait and afterExec, "oneshot tasks wait and startup continues after failure")
assert(prepareWait < brokenWait and brokenWait < afterExec, "oneshot startup tasks run in registration order")
local killedOneShot = false
for _, event in ipairs(ordered.events) do
    if event[1] == "kill" and (event[2] == "/service/prepare" or event[2] == "/service/broken") then
        killedOneShot = true
    end
end
assert(not killedOneShot, "completed oneshot tasks are not stopped as running services")
assert(table.concat(ordered.logs, "\n"):find("Exited with status 7", 1, true), "nonzero oneshot status is reported")

local startupTimeout = fresh({
    startup = { "hang", "after" }, hooks = {}, serviceKinds = { hang = "oneshot" },
    hangingSpawns = { hang = true }
})
for _ = 1, 35 do startupTimeout.tick(false) end
local hangKill, timeoutAfterExec
for i, event in ipairs(startupTimeout.events) do
    if event[1] == "kill" and event[2] == "/service/hang" then hangKill = i end
    if event[1] == "exec" and event[2] == "/service/after" then timeoutAfterExec = i end
end
assert(hangKill and timeoutAfterExec and hangKill < timeoutAfterExec, "startup timeout kills a stuck oneshot and continues")
assert(table.concat(startupTimeout.logs, "\n"):find("Timed out", 1, true), "startup timeout is reported")

local shutdownOneshots = fresh({
    startup = {}, hooks = { "prepare-stop", "bad-stop", "after-stop" },
    serviceKinds = { ["prepare-stop"] = "oneshot", ["bad-stop"] = "oneshot" },
    exitStatuses = { ["bad-stop"] = 9 }
})
shutdownOneshots.tick(false)
shutdownOneshots.request(false)
for _ = 1, 30 do
    shutdownOneshots.tick(true)
    if shutdownOneshots.events[#shutdownOneshots.events][1] == "finish" then break end
end
local prepareStopWait, badStopWait, afterStopWait, stopFinish
for i, event in ipairs(shutdownOneshots.events) do
    if event[1] == "wait" and event[2] == "/service/prepare-stop" then prepareStopWait = i end
    if event[1] == "wait" and event[2] == "/service/bad-stop" then badStopWait = i end
    if event[1] == "exec" and event[2] == "/service/after-stop" then afterStopWait = i end
    if event[1] == "finish" then stopFinish = i end
end
assert(prepareStopWait and badStopWait and afterStopWait and stopFinish,
    "shutdown oneshots run and finish despite a nonzero exit")
assert(prepareStopWait < badStopWait and badStopWait < afterStopWait and afterStopWait < stopFinish,
    "shutdown hooks preserve runlevel order and wait for each oneshot")
assert(table.concat(shutdownOneshots.logs, "\n"):find("Exited with status 9", 1, true),
    "nonzero shutdown oneshot status is reported")

local function findEvent(events, kind, path)
    for index, event in ipairs(events) do
        if event[1] == kind and (not path or event[2] == path) then return index, event end
    end
end

for _, reboot in ipairs({ false, true }) do
    local run = fresh({ startup = { "alpha", "beta" }, hooks = { "alpha", "cleanup" } })
    run.tick(false) -- start runlevels and login
    local loginPid
    for pid, proc in pairs(run.procs) do if proc.path == "/sbin/login.lua" then loginPid = pid end end
    assert(loginPid, "login must start")
    local backgroundPid = run.addBackground("/session/background")
    run.request(reboot)

    for _ = 1, 30 do
        run.tick(true)
        if findEvent(run.events, "finish") then break end
    end
    local finishIndex = assert(findEvent(run.events, "finish"), "shutdown backend should be called")
    local kills = {}
    for i, event in ipairs(run.events) do if event[1] == "kill" then kills[#kills + 1] = { i = i, event = event } end end
    assert(#kills >= 4, "services, login and background process should be stopped")
    assert(kills[1].event[2] == "/service/beta", "services stop in reverse start order")
    assert(kills[2].event[2] == "/service/alpha", "remaining service stops next")
    assert(kills[3].event[2] == "/sbin/login.lua", "login stops before shutdown hooks")
    assert(kills[3].event[3] == loginPid)
    assert(kills[4].event[3] == backgroundPid)
    local alphaExecs = {}
    for i, event in ipairs(run.events) do
        if event[1] == "exec" and event[2] == "/service/alpha" then alphaExecs[#alphaExecs + 1] = i end
    end
    assert(#alphaExecs == 2, "startup service also runs when registered for shutdown")
    local shutdownHook = alphaExecs[2]
    assert(shutdownHook > kills[4].i, "shutdown hooks run after existing processes stop")
    assert(finishIndex > shutdownHook, "shutdown waits for hooks")
    assert(run.events[finishIndex][2] == reboot)
    assert(run.state() == "suspended", "PID1 remains alive after successful finish")
end

local timeout = fresh({ hooks = { "hang" } })
timeout.tick(false)
timeout.request(false)
for _ = 1, 25 do
    timeout.tick(false)
    if findEvent(timeout.events, "finish") then break end
end
assert(findEvent(timeout.events, "finish"), "hook timeout must not block shutdown")
assert(table.concat(timeout.logs, "\n"):find("Shutdown hook timed out: hang", 1, true))

local failed = fresh({ hooks = { "cleanup" }, finishFails = true })
failed.tick(false)
failed.request(false)
for _ = 1, 15 do
    failed.tick(true)
    if failed.events[#failed.events][1] == "exec" and failed.events[#failed.events][2] == "/sbin/login.lua"
        and failed.events[#failed.events][4] ~= 1 then break end
end
assert(table.concat(failed.logs, "\n"):find("Shutdown failed: backend unavailable", 1, true))
local logins = 0
for _, event in ipairs(failed.events) do if event[1] == "exec" and event[2] == "/sbin/login.lua" then logins = logins + 1 end end
assert(logins >= 2, "PID1 should recover by restarting login after finish failure")

local reuse = fresh({ startup = { "alpha", "beta" }, hooks = {} })
reuse.tick(false)
local oldAlphaPid, oldAlphaInstance
for pid, proc in pairs(reuse.procs) do
    if proc.path == "/service/alpha" then oldAlphaPid, oldAlphaInstance = pid, proc.instance end
end
assert(oldAlphaPid, "startup service should be running")
assert(reuse.process.kill(oldAlphaPid))
local recycledPid = reuse.addBackground("/session/recycled-pid")
assert(recycledPid == oldAlphaPid, "test should recycle the service PID")
reuse.request(false)
for _ = 1, 15 do
    reuse.tick(false)
    if findEvent(reuse.events, "finish") then break end
end
local recycledKill
for i, event in ipairs(reuse.events) do
    if event[1] == "kill" and event[3] == recycledPid and event[4] ~= oldAlphaInstance then recycledKill = i end
end
local betaKill = assert(findEvent(reuse.events, "kill", "/service/beta"))
assert(recycledKill and recycledKill > betaKill,
    "stale service PID must not kill a recycled process before normal child cleanup")

print("init shutdown tests passed")
