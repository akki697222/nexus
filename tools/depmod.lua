-- tools/depmod.lua - build the module index (modules.idx) on the host
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Lua 5.3+, run from the nexus root:
--   lua tools/depmod.lua [modules dir] [output]
--       defaults: root/usr/lib/modules  root/usr/lib/modules/modules.idx
--
-- The logic is root/usr/lib/libdepmod.lua, the file the target loads as
-- require("depmod"); this file adds the host file access and the command
-- line. Exits 1 on errors; the index is written without the broken modules.

local here = debug.getinfo(1, "S").source:match("^@(.*)$") or ""
local dir = here:match("^(.*)[/\\]") or "."
package.path = dir .. "/../root/usr/lib/lib?.lua;" .. package.path
local depmod = require("depmod")

local windows = package.config:sub(1, 1) == "\\"

local host = {}

local function succeeded(r) return r == true or r == 0 end

function host.isDir(path)
    if windows then
        return succeeded(os.execute('cd /d "' .. path:gsub("/", "\\") .. '" 2>nul'))
    end
    return succeeded(os.execute('test -d "' .. path .. '"'))
end

-- directories come back with a trailing "/"
function host.list(path)
    local names = {}
    local function each(cmd, suffix)
        local p = io.popen(cmd, "r")
        if not p then return false end
        for line in p:lines() do
            line = line:gsub("\r$", "")
            if line ~= "" then names[#names + 1] = line .. suffix end
        end
        p:close()
        return true
    end
    if windows then
        local d = path:gsub("/", "\\")
        if not each('dir /b /ad "' .. d .. '" 2>nul', "/") then return nil end
        each('dir /b /a-d "' .. d .. '" 2>nul', "")
    elseif not each('ls -1p "' .. path .. '" 2>/dev/null', "") then
        return nil
    end
    return names
end

function host.read(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local s = f:read("a")
    f:close()
    return s
end

function host.size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

-- Writes the index of dir (default root/usr/lib/modules) to out (default
-- dir/modules.idx). Prints warnings and errors; returns false on errors.
function depmod.run(dir, out, quiet)
    dir = dir or "root/usr/lib/modules"
    out = out or (dir .. "/modules.idx")
    if not host.isDir(dir) then
        if not quiet then print("depmod: no modules in " .. dir) end
        return true
    end
    local idx, errors, warn = depmod.build(host, dir, depmod.MOUNT)
    for _, w in ipairs(warn) do io.stderr:write("depmod: warning: " .. w .. "\n") end
    for _, e in ipairs(errors) do io.stderr:write("depmod: error: " .. e .. "\n") end
    local f, err = io.open(out, "wb")
    if not f then
        io.stderr:write("depmod: cannot write " .. out .. ": " .. tostring(err) .. "\n")
        return false
    end
    f:write(depmod.serialize(idx))
    f:close()
    local count = 0
    for _ in pairs(idx.modules) do count = count + 1 end
    if not quiet then print("depmod: " .. out .. " (" .. count .. " modules)") end
    return #errors == 0
end

if arg and arg[0] and arg[0]:match("^tools[/\\]depmod%.lua$") then
    os.exit(depmod.run(arg[1], arg[2]) and 0 or 1)
end

return depmod
