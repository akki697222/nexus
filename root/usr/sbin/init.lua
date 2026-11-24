if not (_OSVERSION and _NEXUS) then
    error("Error: This program cannot be run on other operating systems.")
end

_OPENOC_VERSION = "0.0.6-dev"

---@type oc_computer_lib
local computer = require("computer")
---@type vfs
local fs = require("filesystem")
---@type process
local process = require("process")
---@type user
local user = require("user")
---@type system
local system = require("system")
local serviceCatalog = require("openoc.service")

process.listenSignal(2, function() end)

local function status(id, msg)
    local c = "\27[32m * "
    if id == 1 then
        c = "\27[33m"
    elseif id == 2 then
        c = "\27[31m * "
    elseif not id or type(id) ~= "number" then
        -- information message
        c = "\27[37m   "
        msg = id
    end
    print(c .. "\27[37m" .. msg .. "\27[0m")
end

status("\n\t\27[32mOpenOC \27[36m".. _OPENOC_VERSION .. "\27[0m is starting up \27[94m" .. _OSVERSION .. "\27[0m\n")

local function readService(name)
    local path, findErr = serviceCatalog.find(name)
    if not path then return nil, nil, findErr end
    local ok, definition, readErr = pcall(serviceCatalog.read, path, name)
    if not ok then return nil, path, definition end
    if not definition then return nil, path, readErr end
    return definition, path
end

local function processSnapshot(pid, instance)
    if not pid or pid == -1 then return nil end
    local current = process.get(pid)
    if current and current.instance == instance then return current end
    return nil
end

local STARTUP_ONESHOT_TIMEOUT = 30
local function waitSpawned(pid, instance, deadline)
    while processSnapshot(pid, instance) and computer.uptime() < deadline do
        coroutine.yield()
    end
    if processSnapshot(pid, instance) then
        local ok, killResult = pcall(process.kill, pid)
        if not ok or killResult == false then
            return "Unable to stop timed out task: " .. tostring(not ok and killResult or "process kill failed"), nil, true
        end
        local waitOk, waitErr = pcall(process.wait, pid, instance)
        if not waitOk then return waitErr, nil, true end
        return "Timed out", nil, true
    end
    local ok, waitErr, exitStatus = pcall(process.wait, pid, instance)
    if not ok then return waitErr, nil end
    return waitErr, exitStatus
end

-- Services and login run in process groups of their own, so a signal to
-- one group (Ctrl+C at a terminal) never reaches the others or init.
local function ownGroup(pid)
    if process.setpgid then process.setpgid(pid, 0) end
end

local function startService(name)
    local service, path, err = readService(name)
    if not service then return nil, err or path end
    if service.oneshot then
        local pid, spawnErr, instance = process.spawn(service.execpath, service.args or {})
        if not pid or pid == -1 then return nil, spawnErr or "Unable to launch program" end
        ownGroup(pid)
        if not instance then
            local snapshot = process.get(pid)
            instance = snapshot and snapshot.instance
        end
        if not instance then return nil, "Unable to identify spawned process" end
        local waitErr, exitStatus, timedOut = waitSpawned(pid, instance, computer.uptime() + STARTUP_ONESHOT_TIMEOUT)
        if timedOut then return nil, waitErr end
        if waitErr or exitStatus ~= 0 then
            return nil, waitErr or ("Exited with status " .. tostring(exitStatus))
        end
        status(0, "Completed " .. service.title .. " (" .. service.desc .. ")")
        return { name = name, oneshot = true }
    end
    local pid, exec_err = process.exec(service.execpath, service.args or {})
    if not pid or pid == -1 then return nil, exec_err or "Unable to launch program" end
    ownGroup(pid)
    local snapshot = process.get(pid)
    local record = { name = name, pid = pid, instance = snapshot and snapshot.instance }
    status(0, "Started " .. service.title .. " (" .. service.desc .. ", PID " .. pid .. ")")
    return record
end

local startedServices = {}
local startedServiceOrder = {}

local function startRunlevel(runlevel)
    local basePath = fs.concat("/etc/runlevels", runlevel)
    if not fs.exists(basePath) then return end
    if not fs.isDirectory(basePath) then
        status(2, basePath .. ": Not a directory")
        return
    end
    local entries, err = fs.list(basePath)
    if not entries then
        status(2, basePath .. ": " .. tostring(err))
        return
    end
    for name in entries do
        local marker = fs.attributes(fs.concat(basePath, name))
        if marker and marker.type == "VREG" and name:match("^[%w_][%w_%-]*$") and not startedServices[name] then
            local record, service_err = startService(name)
            if record then
                startedServices[name] = true
                if not record.oneshot then startedServiceOrder[#startedServiceOrder + 1] = record end
            else
                status(2, "/etc/init.d/" .. name .. ": " .. tostring(service_err))
            end
        end
    end
end

if fs.exists("/etc/profile.lua") then
    local s, e = pcall(dofile, "/etc/profile.lua")
    if not s then
        io.stderr:write("init: failed to load profile: " .. (e or "Unknown Error") .. "\n")
    end
end

if not os.getenv("HOSTNAME") then
    os.setenv("HOSTNAME", "nexus")
end

for _, runlevel in ipairs({ "sysinit", "boot", "default" }) do
    startRunlevel(runlevel)
end

print("Welcome to " .. _OSDIST .. " (" .. _OSVERSION .. ")")

local function killSnapshot(snapshot)
    if not snapshot or snapshot.pid == 1 then return end
    local current = processSnapshot(snapshot.pid, snapshot.instance)
    if current then
        local ok, result, err = pcall(process.kill, snapshot.pid)
        if not ok or result == false then status(2, "Failed to stop PID " .. snapshot.pid .. ": " .. tostring(ok and err or result)) end
    end
end

local function stopStartedServices()
    for i = #startedServiceOrder, 1, -1 do
        local service = startedServiceOrder[i]
        local current = processSnapshot(service.pid, service.instance)
        if current then
            local ok, result, err = pcall(process.kill, service.pid)
            if not ok or result == false then status(2, "Failed to stop service " .. service.name .. ": " .. tostring(ok and err or result)) end
        end
    end
end

local function stopRemainingProcesses()
    local ok, snapshots = pcall(process.list)
    if not ok or type(snapshots) ~= "table" then
        status(2, "Unable to list processes during shutdown: " .. tostring(snapshots))
        return
    end
    for _, snapshot in ipairs(snapshots) do killSnapshot(snapshot) end
end

local SHUTDOWN_HOOK_TIMEOUT = 10

local function runShutdownHooks()
    local basePath = fs.concat("/etc/runlevels", "shutdown")
    if not fs.exists(basePath) then return end
    if not fs.isDirectory(basePath) then
        status(2, basePath .. ": Not a directory")
        return
    end
    local entries, err = fs.list(basePath)
    if not entries then
        status(2, basePath .. ": " .. tostring(err))
        return
    end

    for name in entries do
        local marker = fs.attributes(fs.concat(basePath, name))
        if marker and marker.type == "VREG" and name:match("^[%w_][%w_%-]*$") then
            local service, path, service_err = readService(name)
            if not service then
                status(2, (path or ("/etc/init.d/" .. name)) .. ": " .. tostring(service_err))
            else
                local launch = service.oneshot and process.spawn or process.exec
                local pid, exec_err, instance = launch(service.execpath, service.args or {})
                if not pid or pid == -1 then
                    status(2, path .. ": " .. tostring(exec_err or "Unable to launch program"))
                else
                    ownGroup(pid)
                    local snapshot = process.get(pid)
                    instance = instance or (snapshot and snapshot.instance)
                    if service.oneshot then
                        local waitErr, exitStatus, timedOut = waitSpawned(pid, instance, computer.uptime() + SHUTDOWN_HOOK_TIMEOUT)
                        if timedOut then
                            status(2, "Shutdown hook timed out: " .. name)
                        elseif waitErr or exitStatus ~= 0 then
                            status(2, path .. ": " .. tostring(waitErr or ("Exited with status " .. tostring(exitStatus))))
                        end
                    else
                        local deadline = computer.uptime() + SHUTDOWN_HOOK_TIMEOUT
                        while processSnapshot(pid, instance) and computer.uptime() < deadline do
                            coroutine.yield()
                        end
                        if processSnapshot(pid, instance) then
                            status(2, "Shutdown hook timed out: " .. name)
                            killSnapshot({ pid = pid, instance = instance })
                        end
                    end
                end
            end
        end
    end
end

local function performShutdown()
    stopStartedServices()
    stopRemainingProcesses()
    -- Let the scheduler retire killed process entries before hooks can reuse PIDs.
    coroutine.yield()
    runShutdownHooks()
    -- Hooks are children too; ensure no hook or process they started survives.
    stopRemainingProcesses()

    local ok, result, err = pcall(system.finishShutdown)
    if not ok then return nil, result end
    if result == true then return true end
    return nil, err or result or "Shutdown backend failed"
end

local shutdownRetryAt = 0
local function pollShutdownRequest()
    if computer.uptime() < shutdownRetryAt then return nil end
    local ok, requested = pcall(system.shutdownRequested)
    if not ok then
        status(2, "Unable to read shutdown request: " .. tostring(requested))
        shutdownRetryAt = computer.uptime() + 1
        return nil
    end
    if requested == nil then return nil end
    local finished, err = performShutdown()
    if finished then return true end
    status(2, "Shutdown failed: " .. tostring(err))
    shutdownRetryAt = computer.uptime() + 1
    return false
end

local loginPid, loginInstance
local retryAt = 0
while true do
    local finished = pollShutdownRequest()
    if finished then
        -- Keep PID1 alive if a successful backend unexpectedly returns.
        while true do coroutine.yield() end
    end

    if loginPid and not processSnapshot(loginPid, loginInstance) then
        loginPid, loginInstance = nil, nil
        retryAt = computer.uptime() + 1
    end

    if not loginPid and computer.uptime() >= retryAt then
        local pid, err = process.exec("/sbin/login.lua")
        if not pid or pid == -1 then
            status(2, "Failed to start login: " .. tostring(err))
            retryAt = computer.uptime() + 1
        else
            ownGroup(pid)
            local login = process.get(pid)
            loginPid, loginInstance = pid, login and login.instance
        end
    end

    coroutine.yield()
end
