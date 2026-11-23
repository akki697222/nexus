-- logger - add messages to the system log
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local system = require("system")

local tag, level = nil, "notice"
local words = {}
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "-t" then
        i = i + 1; tag = args[i]
    elseif a == "-p" then
        i = i + 1; level = (args[i] or ""):match("([^.]+)$") -- accepts facility.level
    elseif a == "-h" or a == "--help" then
        print("usage: logger [-t tag] [-p level] [message...]")
        print("  without a message, each line of standard input is logged")
        return 0
    else
        words[#words + 1] = a
    end
    i = i + 1
end
tag = tag or os.getenv("USER") or "logger"

local function send(message)
    local ok, err = system.log(message, tag, level)
    if not ok then
        io.stderr:write("logger: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

if #words > 0 then
    send(table.concat(words, " "))
else
    while true do
        local line = io.read("*l")
        if not line then break end
        send(line)
    end
end
return 0
