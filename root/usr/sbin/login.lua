---@type process
local process = require("process")
---@type user
local user = require("user")

process.listenSignal(2, function() end)

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

        local shell_pid, err = process.exec(usr.shell)
        if shell_pid == -1 then
            io.stderr:write("login: " .. usr.shell .. ": " .. tostring(err) .. "\n")
        else
            user.switchprocuser(username, password, shell_pid)
            process.wait(shell_pid)
        end
    else
        print("Login failed.\n")
    end
end
