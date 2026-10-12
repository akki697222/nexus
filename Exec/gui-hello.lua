-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Demo client: a window with a clickable button, key echo and a spinner.
local gui = require("gui")
local conn = gui.connect()
local win, w, h = gui.window(conn, "Hello", 34, 9)

local BG, FG = 0x20242E, 0xE6E6E6
local count, last_key, spin = 0, "-", 1
local SPIN = { "|", "/", "-", "\\" }
local BTN = { x = 3, y = 4, w = 13 }

local function draw()
    win.colors(FG, BG)
    win.clear(BG)
    win.set(3, 2, "Hello from a client!")
    win.set(BTN.x, BTN.y, "[ Click me! ]", 0xFFFFFF, 0x3B6EA5)
    win.set(BTN.x + BTN.w + 2, BTN.y, "count: " .. count)
    win.set(3, 6, "last key: " .. last_key)
    win.set(3, 7, "q = quit   " .. SPIN[spin], 0x808080)
    win.commit()
end

draw()

gui.loop({
    configure = function(ev) w, h = ev.w, ev.h; draw() end,
    pointer = function(ev)
        if ev.action == "down" and ev.y == BTN.y and ev.x >= BTN.x and ev.x < BTN.x + BTN.w then
            count = count + 1
            draw()
        end
    end,
    key = function(ev)
        if not ev.down or not ev.char or ev.char == 0 then return end   -- skip key-up / modifiers
        if ev.char == string.byte("q") then return "quit" end
        last_key = ev.char and ev.char >= 32 and ev.char < 127 and string.char(ev.char) or ("code " .. tostring(ev.code))
        draw()
    end,
    tick = function()
        spin = spin % #SPIN + 1
        draw()
    end,
}, 0.5)

win.destroy()
