-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local args = process_manager.current_proc().args
if #args == 0 then
    stdout:write(stdin:read("a") or "")
    return
end
local code = 0
for _, path in ipairs(args) do
    local data, err = fs.read_file(path)
    if data then
        stdout:write(data)
    else
        stderr:write("cat: " .. tostring(err) .. "\n")
        code = 1
    end
end
process_manager.exit(code)
