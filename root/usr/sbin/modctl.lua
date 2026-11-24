-- modctl.lua - list, load and unload kernel modules
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   modctl [list]          loaded modules
--   modctl load <path>     load a module under /usr/lib/modules (root)
--   modctl unload <name>   unload a module (root)

local module = require("module")

local args = { ... }
local command = args[1] or "list"

local function fail(msg)
    io.stderr:write("modctl: " .. tostring(msg) .. "\n")
    os.exit(1)
end

local function pad(s, n)
    s = tostring(s or "-")
    if #s >= n then return s end
    return s .. string.rep(" ", n - #s)
end

if command == "list" then
    print(pad("MODULE", 14) .. pad("VERSION", 16) .. "DESCRIPTION")
    for _, m in ipairs(module.list()) do
        print(pad(m.name, 14) .. pad(m.version, 16) .. (m.desc or ""))
    end
elseif command == "load" then
    if not args[2] then fail("missing module path") end
    local ok, name = module.load(args[2])
    if not ok then fail(name) end
    print("loaded " .. tostring(name))
elseif command == "unload" then
    if not args[2] then fail("missing module name") end
    local ok, err = module.unload(args[2])
    if not ok then fail(err) end
elseif command == "-h" or command == "--help" or command == "help" then
    print("usage: modctl [list | load <path> | unload <name>]")
else
    fail("unknown command '" .. command .. "' (try modctl help)")
end
