-- Run from the Nexus directory: lua tests/user_lookup.lua
local sourceFile = assert(io.open("src/user.lua", "r"))
local source = sourceFile:read("*a")
sourceFile:close()

local current = { uid = 100, euid = 100 }
local modes = { ["/etc/passwd"] = 644, ["/etc/shadow"] = 400 }
local createdRootHome = 0
local env = setmetatable({
    process = { getCurrent = function() return current end },
    util = {
        copyTable = function(entry)
            local copy = {}
            for key, value in pairs(entry) do copy[key] = value end
            return copy
        end,
    },
    vfs = {
        exists = function(path) return modes[path] ~= nil end,
        makeDirectory = function(path)
            assert(path == "/root" and modes[path] == nil)
            createdRootHome = createdRootHome + 1
            modes[path] = 755
            return true
        end,
        chmod = function(path, mode) modes[path] = mode end,
        open = function(path, mode)
            assert(path == "/etc/passwd" and mode == "r")
            return {
                readAll = function()
                    return "root:x:0:0:root:/root:/bin/sh.lua\n"
                        .. "debug:x:100:100::/home/debug:/bin/sh.lua\n"
                end,
                close = function() end,
            }
        end,
    },
}, { __index = _G })

assert(load(source, "@src/user.lua", "t", env))()
local user = env.user
user.updateUsers()

local byName = assert(user.getUser("debug"))
local byUID = assert(user.getUserByUID(100))
local caller = assert(user.getCurrent())
assert(caller.uid == 100 and caller.username == "debug")

byName.username = "changed"
byUID.home = "/different"
caller.uid = 200
assert(user.getUser("debug").username == "debug")
assert(user.getUserByUID(100).home == "/home/debug")
assert(user.getCurrent().uid == 100 and current.uid == 100)
assert(user.getUserByUID(200) == nil)

current.uid = 200
assert(user.getCurrent() == nil)
assert(not user.checkRoot())
current.uid, current.euid = 100, 0
assert(user.getCurrent().uid == 100 and user.checkRoot())
current = nil
assert(user.getCurrent() == nil and not user.checkRoot())

user.init()
assert(createdRootHome == 1 and modes["/root"] == 700)
modes["/root"] = 750
user.init()
assert(createdRootHome == 1 and modes["/root"] == 750)

print("user lookup tests passed")
