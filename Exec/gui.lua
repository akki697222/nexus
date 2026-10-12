-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- gui: start the compositor and wait until it exits (Alt+Shift+E quits; binds: System://Config/gui.lua).
if compositor and compositor.running then
    stderr:write("gui: compositor is already running\n")
    process_manager.exit(1)
end

local ok, pid = pcall(process_manager.spawn, { path = "System://Services/compositor.lua", detached = true })
if not ok then
    stderr:write("gui: " .. tostring(pid) .. "\n")
    process_manager.exit(1)
end

process_manager.wait(pid)
-- the compositor restores the console itself; this covers a hard kill
term.resume()
