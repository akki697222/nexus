-- kill.lua - send a signal to processes or process groups
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   kill [-s SIGNAL | -SIGNAL | -n NUMBER] [--] pid|-pgid ...
--   kill -l [NUMBER | 128+NUMBER | NAME]
--
-- SIGNAL is a name with or without SIG (TERM, SIGTERM) or a number; the
-- default is TERM. A negative pid names a process group; put `--` before
-- it so it is not read as a signal (kill -- -5, kill -INT -- -5).
-- Signal 0 sends nothing and only checks that the process exists.

local process = require("process")

local NAMES = {
    "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1",
    "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP",
    "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS",
}
local NUMBERS = {}
for n, name in ipairs(NAMES) do NUMBERS[name] = n end

local function fail(msg)
    io.stderr:write("kill: " .. msg .. "\n")
    os.exit(1)
end

local function parseSignal(text)
    local n = math.tointeger(tonumber(text))
    if n then
        if n == 0 or NAMES[n] then return n end
        return nil
    end
    return NUMBERS[(text:upper():gsub("^SIG", ""))]
end

local args = { ... }
if #args == 0 then
    fail("usage: kill [-s SIGNAL | -SIGNAL] [--] pid ... | kill -l [SIGNAL]")
end

-- kill -l
if args[1] == "-l" or args[1] == "-L" then
    local what = args[2]
    if what then
        local n = math.tointeger(tonumber(what))
        if n then
            if n > 128 then n = n - 128 end -- an exit status
            if not NAMES[n] then fail(what .. ": invalid signal") end
            print(NAMES[n])
        else
            local sig = parseSignal(what)
            if not sig then fail(what .. ": invalid signal") end
            print(tostring(sig))
        end
        return 0
    end
    local line = {}
    for n, name in ipairs(NAMES) do
        line[#line + 1] = string.format("%2d) SIG%-7s", n, name)
        if #line == 4 then
            print(table.concat(line, " "))
            line = {}
        end
    end
    if #line > 0 then print(table.concat(line, " ")) end
    return 0
end

local sig, i = 15, 1
local first = args[1]
if first == "-s" or first == "-n" then
    if not args[2] then fail(first .. " needs a signal") end
    sig = parseSignal(args[2])
    if not sig then fail(args[2] .. ": invalid signal") end
    i = 3
elseif first ~= "--" and first:sub(1, 1) == "-" then
    sig = parseSignal(first:sub(2))
    if not sig then fail(first:sub(2) .. ": invalid signal") end
    i = 2
end
if args[i] == "--" then i = i + 1 end
if not args[i] then fail("no process given") end

local status = 0
for j = i, #args do
    local pid = math.tointeger(tonumber(args[j]))
    if not pid or pid == 0 then
        io.stderr:write("kill: " .. args[j] .. ": arguments must be process or group IDs\n")
        status = 1
    elseif sig == 0 then
        if pid < 0 or not process.get(pid) then
            if pid > 0 then
                io.stderr:write("kill: (" .. pid .. ") - No such process\n")
                status = 1
            end
        end
    else
        local ok, err = process.kill(pid, sig)
        if not ok then
            io.stderr:write("kill: (" .. pid .. ") - " .. tostring(err) .. "\n")
            status = 1
        end
    end
end
return status
