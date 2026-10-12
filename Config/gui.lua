-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Compositor configuration (read when the compositor starts: `gui`).
-- Everything here is optional; unspecified values use the built-in defaults.
return {
    -- "floating" | "tiling" | path to your own policy file, e.g. "System://Config/mywm.lua"
    -- A policy is a table: { place = fn, arrange = fn, key = fn, pointer = fn, floating = bool }
    policy = "floating",
    fps = 20,

    autostart = { "System://Exec/gui-panel.lua" },

    -- theme = { desktop = 0x1B1F2A, title_bg = 0x3B6EA5, ... },

    -- Modifier used by "mod+..." binds. Plain Alt+<key> collides with host /
    -- game system keys, so the default is Alt+Shift. Any of ctrl, alt, shift.
    -- mod = "alt+shift",

    -- Binds are handled by the compositor before clients see the key.
    -- Key names: a-z, 0-9, f1-f10, tab, enter, space, escape, backspace, arrows.
    -- Value: "focus_next" | "focus_prev" | "close" | "maximize" | "quit"
    --        | { spawn = path } | { policy = name } | function(ctx) end
    -- Defaults: mod+enter terminal, mod+d demo window, mod+j / mod+k focus,
    --           mod+q close, mod+m maximize, mod+e quit, mod+t tiling, mod+f floating.
    -- binds = {
    --     ["mod+p"] = { spawn = "System://Exec/gui-hello.lua" },
    -- },
}
