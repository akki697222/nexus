-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local args = process_manager.current_proc().args
local long, paths = false, {}
for _, a in ipairs(args) do
    if a == "-l" then long = true else paths[#paths + 1] = a end
end
if #paths == 0 then paths[1] = "." end

local code = 0
for _, path in ipairs(paths) do
    local names, err = fs.list(path)
    if not names then
        stderr:write("ls: " .. tostring(err) .. "\n")
        code = 1
    else
        if #paths > 1 then print(path .. ":") end
        for _, name in ipairs(names) do
            local full = path:gsub("/$", "") .. "/" .. name
            local st = fs.stat(full)
            local is_dir = st and st.is_dir
            if long then
                print(string.format("%s %8d %s", is_dir and "d" or "-", st and st.size or 0, name))
            else
                print(name .. (is_dir and "/" or ""))
            end
        end
    end
end
process_manager.exit(code)
