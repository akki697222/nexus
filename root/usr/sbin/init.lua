if not (_OSVERSION and _NEXUS) then
    error("Error: This program cannot be run on other operating systems.")
end

_OPENOC_VERSION = "0.1.0"

---@type oc_computer_lib
local computer = require("computer")
local colors = require("colors")
---@type vfs
local fs = require("filesystem")
---@type process
local process = require("process")
---@type user
local user = require("user")
---@type system
local system = require("system")

process.listenSignal(2, function() end)

local function status(id, msg)
    local c = colors.green .. " * "
    if id == 1 then
        c = colors.yellow
    elseif id == 2 then
        c = colors.red .. " * "
    elseif not id or type(id) ~= "number" then
        -- information message
        c = colors.white .. "   "
        msg = id
    end
    print(c .. colors.white .. msg .. colors.reset)
end

print()
status(colors.green ..
    "OpenOC " ..
    colors.cyan ..
    _OPENOC_VERSION .. colors.reset .. " is starting up " .. colors.bright_blue .. _OSVERSION .. colors.reset)
print()

local function readService(path)
    local chunk, err = loadfile(path, "t")
    if not chunk then return nil, err end

    local ok, service = pcall(chunk, path)
    if not ok then return nil, service end
    if type(service) ~= "table" or service.service ~= "program"
        or type(service.title) ~= "string" or type(service.desc) ~= "string"
        or type(service.execpath) ~= "string" or service.execpath:sub(1, 1) ~= "/"
        or (service.args ~= nil and type(service.args) ~= "table") then
        return nil, "Invalid program service definition"
    end

    return service
end

local function processSnapshot(pid, instance)
    if not pid or pid == -1 then return nil end
    local current = process.get(pid)
    if current and current.instance == instance then return current end
    return nil
end

local function startService(path, name)
    local service, err = readService(path)
    if not service then return nil, err end
    local pid, exec_err = process.exec(service.execpath, service.args or {})
    if not pid or pid == -1 then return nil, exec_err or "Unable to launch program" end
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
            local path = fs.concat("/etc/init.d", name .. ".lua")
            local record, service_err = startService(path, name)
            if record then
                startedServices[name] = true
                startedServiceOrder[#startedServiceOrder + 1] = record
            else
                status(2, path .. ": " .. tostring(service_err))
            end
        end
    end
end

if system.config.debug then
    if not user.getUser("debug") then
        user.create("debug", "debug", 100, 100)
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
            local path = fs.concat("/etc/init.d", name .. ".lua")
            local service, service_err = readService(path)
            if not service then
                status(2, path .. ": " .. tostring(service_err))
            else
                local pid, exec_err = process.exec(service.execpath, service.args or {})
                if not pid or pid == -1 then
                    status(2, path .. ": " .. tostring(exec_err or "Unable to launch program"))
                else
                    local snapshot = process.get(pid)
                    local instance = snapshot and snapshot.instance
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
            local login = process.get(pid)
            loginPid, loginInstance = pid, login and login.instance
        end
    end

    coroutine.yield()
end
