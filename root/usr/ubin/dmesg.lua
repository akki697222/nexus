-- dmesg - print the system log held by the kernel
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local system = require("system")

local kernelOnly, levelFilter = false, nil
local args = { ... }
local i = 1
while i <= #args do
    local a = args[i]
    if a == "-k" then
        kernelOnly = true
    elseif a == "-l" then
        i = i + 1
        levelFilter = args[i]
    elseif a == "-h" or a == "--help" then
        print("usage: dmesg [-k] [-l level]")
        print("  -k        kernel messages only")
        print("  -l level  messages of this level or more severe")
        return 0
    else
        io.stderr:write("dmesg: unknown option " .. tostring(a) .. "\n")
        return 1
    end
    i = i + 1
end

local LEVELS = { emerg = 0, alert = 1, crit = 2, err = 3, warning = 4, notice = 5, info = 6, debug = 7 }
local maxLevel = levelFilter and LEVELS[levelFilter]
if levelFilter and not maxLevel then
    io.stderr:write("dmesg: unknown level " .. levelFilter .. "\n")
    return 1
end

local entries = system.readLog(0)
local out = {}
for _, e in ipairs(entries) do
    if (not kernelOnly or e.tag == "kernel") and (not maxLevel or (LEVELS[e.level] or 6) <= maxLevel) then
        if e.tag == "kernel" and not e.pid then
            out[#out + 1] = string.format("[%8.2f] %s\n", e.uptime, e.msg)
        else
            local ident = e.pid and string.format("%s[%d]", e.tag, e.pid) or e.tag
            out[#out + 1] = string.format("[%8.2f] %s: %s\n", e.uptime, ident, e.msg)
        end
    end
end
io.write(table.concat(out))
return 0
