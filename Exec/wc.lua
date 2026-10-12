-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local args = process_manager.current_proc().args
local function count(text)
    local lines = select(2, text:gsub("\n", ""))
    local words = select(2, text:gsub("%S+", ""))
    return lines, words, #text
end
if #args == 0 then
    print(string.format("%d %d %d", count(stdin:read("a") or "")))
else
    for _, path in ipairs(args) do
        local data, err = fs.read_file(path)
        if data then
            local l, w, b = count(data)
            print(string.format("%d %d %d %s", l, w, b, path))
        else
            stderr:write("wc: " .. tostring(err) .. "\n")
        end
    end
end
