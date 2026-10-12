-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

function panic(reason)
    reason = tostring(reason)

    if log and log.panic then
        pcall(log.panic, "PANIC: %s", reason)
        pcall(log.flush)
    end

    local addr = component.list("gpu")()
    local gpu  = addr and component.proxy(addr)
    if gpu then
        gpu.setBackground(0xFF0000)
        gpu.setForeground(0xFFFFFF)
        local w, h = gpu.getResolution()
        gpu.fill(1, 1, w, h, " ")
        gpu.set(1, 1, "Panic!")
        local l = 1
        for text in reason:gsub("\t", "    "):gsub("\r", ""):gmatch("[^\n]+") do
            while #text > 0 do
                local line = text:sub(1, w)

                text = text:sub(#line + 1)
                l = l + 1
                if l > h then break end

                gpu.set(1, l, line)
            end
        end
    end
    for _ = 0, 2 do
        computer.beep()
    end
    if gpu then
        local _, h = gpu.getResolution()
        gpu.set(1, h, "Press any key to reboot")
    end
    -- stay visible until a key press (debuggable); pullSignal keeps the VM
    -- from tripping "too long without yielding".
    while true do
        local sig = computer.pullSignal(1)
        if sig == "key_down" then
            computer.shutdown(true)
        end
    end
end
