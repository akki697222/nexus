-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- lua [file [args...]]: run a script, or start an interactive REPL.
-- The REPL runs inside the kernel's global environment (handy for debugging).
local args = process_manager.current_proc().args

if args[1] then
    local src, err = fs.read_file(args[1])
    if not src then
        stderr:write("lua: " .. tostring(err) .. "\n")
        process_manager.exit(1)
    end
    local fn, lerr = load(src, "@" .. args[1], "t", _ENV)
    if not fn then
        stderr:write("lua: " .. tostring(lerr) .. "\n")
        process_manager.exit(1)
    end
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end
    local ok, e = pcall(fn, table.unpack(rest))
    if not ok then
        if type(e) == "table" and e.nexus_exit then error(e, 0) end
        stderr:write("lua: " .. tostring(e) .. "\n")
        process_manager.exit(1)
    end
    return
end

print(_VERSION .. " REPL (exit with 'exit')")
while true do
    stdout:write("lua> ")
    local line = stdin:read("l")
    if line == nil or line == "exit" or line == "quit" then break end
    if line:match("%S") then
        local fn, err = load("return " .. line, "=repl", "t", _ENV)
        if not fn then fn, err = load(line, "=repl", "t", _ENV) end
        if not fn then
            stderr:write(tostring(err) .. "\n")
        else
            local res = table.pack(pcall(fn))
            if not res[1] then
                stderr:write(tostring(res[2]) .. "\n")
            elseif res.n > 1 then
                local out = {}
                for i = 2, res.n do out[#out + 1] = tostring(res[i]) end
                print(table.concat(out, "\t"))
            end
        end
    end
end
