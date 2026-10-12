-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Client helpers for the Nexus compositor (see service/compositor).
--
--   local gui  = require("gui")
--   local conn = gui.connect()
--   local win, w, h = gui.window(conn, "Title", 40, 10)
--   win.set(2, 2, "hello")            -- draw into the surface buffer
--   win.commit()                      -- show it (damage-tracked)
--   gui.loop({ key = function(ev) ... end, pointer = ..., close = ... })

local gui = {}

gui.colors = {
    black = 0x000000, white = 0xFFFFFF, grey = 0x808080, red = 0xCC4444,
    green = 0x55AA55, blue = 0x3B6EA5, yellow = 0xD8B24A, cyan = 0x4AA8B8,
}

function gui.connect()
    return compositor.connect()
end

---Create a decorated top-level window and wait for its first configure.
---@return table surface, integer width, integer height
function gui.window(conn, title, w, h, opts)
    local surf = conn.create_surface()
    local o = { title = title, w = w, h = h }
    if opts then for k, v in pairs(opts) do o[k] = v end end
    surf.role("toplevel", o)
    local id = surf.id()
    local ev = event.pull("gui", 2, function(e) return e.kind == "configure" and e.surface == id end)
    if ev then w, h = ev.w, ev.h end
    return surf, w, h
end

---Create a layer-shell surface (panel / background / overlay).
function gui.layer(conn, opts)
    local surf = conn.create_surface()
    surf.role("layer", opts)
    local id = surf.id()
    local ev = event.pull("gui", 2, function(e) return e.kind == "configure" and e.surface == id end)
    return surf, ev and ev.w or 0, ev and ev.h or 0
end

---Dispatch compositor events to handlers[kind](ev). A handler returning
---"quit" ends the loop; so does an unhandled "close". `tick` runs when
---`timeout` seconds pass without events.
function gui.loop(handlers, timeout)
    while true do
        local ev = event.pull("gui", timeout)
        if not ev then
            if handlers.tick and handlers.tick() == "quit" then return end
        else
            local h = handlers[ev.kind]
            if h then
                if h(ev) == "quit" then return end
            elseif ev.kind == "close" then
                return
            end
        end
    end
end

return gui
