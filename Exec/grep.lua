-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local args = process_manager.current_proc().args
local pattern = args[1]
if not pattern then
    stderr:write("usage: grep <lua-pattern> [files]\n")
    process_manager.exit(2)
end
if not pcall(string.find, "", pattern) then
    stderr:write("grep: invalid pattern\n")
    process_manager.exit(2)
end

local found = false
local function scan(text, label)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:find(pattern) then
            found = true
            print((label and (label .. ":") or "") .. line)
        end
    end
end

if #args == 1 then
    scan(stdin:read("a") or "")
else
    for i = 2, #args do
        local data, err = fs.read_file(args[i])
        if data then
            scan(data, #args > 2 and args[i] or nil)
        else
            stderr:write("grep: " .. tostring(err) .. "\n")
        end
    end
end
process_manager.exit(found and 0 or 1)
