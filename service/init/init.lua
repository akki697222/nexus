-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- init (System://Services): a semi-user service. Once every service is up it
-- runs the boot self test and keeps a shell alive on the console.
service_manager.ready("init")

local t0 = computer.uptime()
while not service_manager.all_running() and computer.uptime() - t0 < 15 do
    scheduler.sleep(0.1)
end
if not service_manager.all_running() then
    log.warn("[init] starting shell although some services are not running")
end

pcall(process_manager.spawn, { path = "System://Services/selftest.lua" })

while true do
    local ok, pid = pcall(process_manager.spawn, {
        path = "System://Exec/sh.lua",
        env  = { PATH = "System://Exec" },
    })
    if ok then
        local code = process_manager.wait(pid)
        log.warn("[init] shell exited (code=%s), restarting", tostring(code))
    else
        log.error("[init] cannot start shell: %s", tostring(pid))
    end
    scheduler.sleep(1)
end
