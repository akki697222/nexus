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
local proc = require("process")
---@type process
local process = require("process")
---@type devfs
local devfs = require("devfs")
---@type user
local user = require("user")
---@type system
local system = require("system")

process.listenSignal(2, function() end)

print("Total Memory: " .. computer.totalMemory() .. " bytes")

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

if not fs.exists("/etc/services") then
    fs.makeDirectory("/etc/services")
end

local function searchAndStartServices(basePath)
    for sp in fs.list(basePath) do
        --print(sp)
        local path = fs.concat(basePath, sp)
        if fs.isDirectory(path) then
            searchAndStartServices(path)
        else
            local f = loadfile(path, "bt") or function() end
            local ok, s = pcall(f, path)
            if ok and s and type(s) == "table" then
                if s.title
                    and s.desc
                    and s.service then
                    status(0, "Starting " .. s.title .. " (" .. s.desc .. ")")
                    if s.service == "program" then
                        if s.execpath and type(s.execpath) == "string" then
                            proc.exec(s.execpath, s.args or {})
                        else
                            status(2, "Invalid exec path '" .. tostring(s.execpath) .. "'")
                        end
                    else
                        status(2, "Invalid service type '" .. s.service .. "'")
                    end
                end
            elseif not ok then
                status(2, "Failed to start service: " .. s)
            else
                print("not a module")
            end
        end
    end
end

searchAndStartServices("/etc/services")

-- Init end
print("Welcome to " .. _OSDIST .. " (" .. _OSVERSION .. ")")

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

while true do
    local pid, err = process.exec("/sbin/login.lua")
    if pid == -1 and err then
        io.stderr:write("init: failed to start login: " .. err .. "\n")
        break
    end
    process.wait(pid)
end
