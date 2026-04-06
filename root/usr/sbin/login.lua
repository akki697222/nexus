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
        local usr = user.getUser(username) --[[@as user]]
        local shell_pid, err = process.exec(usr.shell)
        if not user.switchprocuser(username, password, shell_pid) then
            print("Login failed.\n")
        end
        if shell_pid == -1 then
            print("login: " .. usr.shell .. ": " .. err)
        else
            process.wait(shell_pid)
        end
    else
        print("Login failed.\n")
    end
end
