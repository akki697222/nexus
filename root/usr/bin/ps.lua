local process = require("process")
local user = require("user")
local shell = require("shell")

local args = shell.parse(...)
local processes = process.list()

print(string.format("%-8s %5s %4s %-6s %s", "USER", "PID", "STAT", "TTY", "COMMAND"))

for _, proc in ipairs(processes) do
    local username = "unknown"
    local u = user.getUserByUID(proc.uid)
    if u then
        username = u.username
    end

    local stat = "?"
    if proc.status == "running" then
        stat = "R"
    elseif proc.status == "waiting" then
        stat = "S"
    elseif proc.status == "suspended" then
        stat = "T"
    elseif proc.status == "dead" then
        stat = "Z"
    end

    local tty = "tty" .. tostring(proc.tty)
    if proc.tty == -1 then tty = "?" end

    local cmd = proc.path
    if proc.arguments and #proc.arguments > 0 then
        local arg_strs = {}
        for i = 1, #proc.arguments do
            table.insert(arg_strs, tostring(proc.arguments[i]))
        end
        cmd = cmd .. " " .. table.concat(arg_strs, " ")
    end

    print(string.format("%-8s %5s %4s %-6s %s",
        username:sub(1, 8),
        tostring(proc.pid),
        stat,
        tty,
        cmd
    ))
end
