-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local args = process_manager.current_proc().args
if #args ~= 2 then
    stderr:write("usage: mv <src> <dst>\n")
    process_manager.exit(1)
end
local ok, err = fs.rename(args[1], args[2])
if not ok then
    stderr:write("mv: " .. tostring(err) .. "\n")
    process_manager.exit(1)
end
