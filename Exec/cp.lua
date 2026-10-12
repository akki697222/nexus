-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local args = process_manager.current_proc().args
if #args ~= 2 then
    stderr:write("usage: cp <src> <dst>\n")
    process_manager.exit(1)
end
local data, err = fs.read_file(args[1])
if not data then
    stderr:write("cp: " .. tostring(err) .. "\n")
    process_manager.exit(1)
end
local ok, e = fs.write_file(args[2], data)
if not ok then
    stderr:write("cp: " .. tostring(e) .. "\n")
    process_manager.exit(1)
end
