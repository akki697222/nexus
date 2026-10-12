-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local list = process_manager.list()
local pids = {}
for pid in pairs(list) do pids[#pids + 1] = pid end
table.sort(pids)
print(string.format("%4s %4s %-8s %s", "PID", "PPID", "STATE", "PATH"))
for _, pid in ipairs(pids) do
    local p = list[pid]
    print(string.format("%4d %4d %-8s %s", pid, p.parent, p.state, tostring(p.path)))
end
