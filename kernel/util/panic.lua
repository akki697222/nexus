-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

function panic(reason)
    local gpu = component.proxy(component.list("gpu")())
    if gpu then
        gpu.setBackground(0xFF0000)
        gpu.setForeground(0xFFFFFF)
        local w, h = gpu.getResolution()
        gpu.fill(1, 1, w, h, " ")
        gpu.set(1, 1, "Panic!")
        local l = 1
        for text in tostring(reason):gsub("\t", "    "):gsub("\r", ""):gmatch("[^\n]+") do
            while #text > 0 do
                local line = text:sub(1, w)

                text = text:sub(#line + 1)
                l = l + 1

                gpu.set(1, l, line)
            end
        end
    end
    for _ = 0, 2 do
        computer.beep()
    end
    while true do
        coroutine.yield()
    end
end
