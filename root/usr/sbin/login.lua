---@type process
local process = require("process")
---@type user
local user = require("user")

---@type filesystem
local fs = require("filesystem")
local group = require("group")

process.listenSignal(2, function() end)

-- Like login(1) on Unix: the terminal belongs to the logged-in user (mode 620,
-- group tty) for the lifetime of the session and goes back to root afterwards.
local function ttyNode()
    local cur = process.getCurrent()
    local id = cur and cur.tty
    if type(id) ~= "number" or id < 0 then return nil end
    local path = "/dev/tty" .. tostring(id)
    if fs.exists(path) then return path end
end

local function setTtyOwner(path, uid, gid)
    if not path then return end
    local ok, err = pcall(fs.chown, path, uid, gid)
    if not ok then
        io.stderr:write("login: " .. path .. ": " .. tostring(err) .. "\n")
    end
end

while true do
    io.write("Login: ")
    local username = io.read()

    io.write("Password: ")
    local password = io.read("l", "*")

    print()
    if user.checkPasswordCorrect(username, password) then
        local usr = user.getUser(username)

        process.setEnviron("HOME", usr.home)
        process.setEnviron("USER", usr.username)
        process.setEnviron("USERNAME", usr.username)
        process.setEnviron("SHELL", usr.shell)
        process.setEnviron("PWD", usr.home)

        local tty = ttyNode()
        local ttyGroup = group.getGroup and group.getGroup("tty")
        setTtyOwner(tty, usr.uid, ttyGroup and ttyGroup.gid or usr.gid)

        local shell_pid, err = process.exec(usr.shell, { "-l" })
        if shell_pid == -1 then
            io.stderr:write("login: " .. usr.shell .. ": " .. tostring(err) .. "\n")
        else
            user.switchprocuser(username, password, shell_pid)
            process.wait(shell_pid)
        end
        setTtyOwner(tty, 0, ttyGroup and ttyGroup.gid or 0)
    else
        print("Login failed.\n")
    end
end
