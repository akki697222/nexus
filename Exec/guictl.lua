-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- guictl list | policy <floating|tiling|path> | redraw | quit
local args = process_manager.current_proc().args
if not (compositor and compositor.running) then
    stderr:write("guictl: compositor is not running\n")
    process_manager.exit(1)
end

local cmd = args[1]
if cmd == "list" then
    print(string.format("%3s %-8s %-6s %-5s %s", "ID", "KIND", "POS", "SIZE", "TITLE"))
    for _, w in ipairs(compositor.list()) do
        print(string.format("%3d %-8s %3d,%-2d %dx%d %s%s", w.id, w.kind, w.x, w.y, w.w, w.h,
            w.title or "", w.focused and " *" or ""))
    end
elseif cmd == "policy" and args[2] then
    local ok, err = compositor.set_policy(args[2])
    if not ok then
        stderr:write("guictl: " .. tostring(err) .. "\n")
        process_manager.exit(1)
    end
elseif cmd == "redraw" then
    compositor.redraw()
elseif cmd == "quit" then
    compositor.quit()
else
    stderr:write("usage: guictl list | policy <name|path> | redraw | quit\n")
    process_manager.exit(1)
end
