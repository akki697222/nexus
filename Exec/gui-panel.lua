-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Panel: a "top" layer-shell surface with an exclusive zone. Shows the
-- window list on the left and the clock on the right.
local gui = require("gui")
local conn = gui.connect()
local panel, w = gui.layer(conn, { layer = "top", anchor = "top", size = 1, exclusive = true })

local BG, FG, ACCENT = 0x14161C, 0xB8BECC, 0x3B6EA5

local function draw()
    panel.colors(FG, BG)
    panel.clear(BG)
    panel.set(1, 1, " Nexus ", 0xFFFFFF, ACCENT)
    local x = 10
    for _, t in ipairs(conn.toplevels()) do
        local label = " " .. (t.title ~= "" and t.title or "?") .. " "
        if x + #label < w - 12 then
            if t.focused then
                panel.set(x, 1, label, 0xFFFFFF, 0x2E3440)
            else
                panel.set(x, 1, label)
            end
            x = x + #label + 1
        end
    end
    local clock = os.date("%H:%M:%S")
    panel.set(math.max(1, w - #clock - 1), 1, clock)
    panel.commit()
end

draw()

gui.loop({
    configure = function(ev) w = ev.w; draw() end,
    tick = function() draw() end,
}, 1.0)

panel.destroy()
