-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local code = 0
for _, a in ipairs(process_manager.current_proc().args) do
    local pid = tonumber(a)
    if pid and process_manager.get(pid) then
        process_manager.kill(pid)
    else
        stderr:write("kill: no such process: " .. a .. "\n")
        code = 1
    end
end
process_manager.exit(code)
