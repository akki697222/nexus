-- devctl.lua - inspect and control driver bindings
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   devctl [list]                 devices and the drivers bound to them
--   devctl drivers                drivers in the index
--   devctl bind <addr> [driver]   bind a device (root)
--   devctl unbind <addr>          unbind a device (root)
--   devctl rescan                 reload drivers.idx and probe again (root)
--
-- <addr> may be any unique prefix of a component address.

local device = require("device")

local args = { ... }
local command = args[1] or "list"

local function fail(msg)
    io.stderr:write("devctl: " .. tostring(msg) .. "\n")
    os.exit(1)
end

local function pad(s, n)
    s = tostring(s or "-")
    if #s >= n then return s end
    return s .. string.rep(" ", n - #s)
end

local function resolve(prefix)
    if not prefix or prefix == "" then fail("missing device address") end
    local found
    for _, b in ipairs(device.bindings()) do
        if b.address:sub(1, #prefix) == prefix then
            if found then fail(prefix .. ": ambiguous address") end
            found = b.address
        end
    end
    -- devices that were never probed (core types) are not listed; allow the
    -- full address so bind can still report why it refuses
    return found or prefix
end

if command == "list" then
    local rows = device.bindings()
    print(pad("ADDRESS", 10) .. pad("TYPE", 14) .. pad("DRIVER", 14) .. pad("NODE", 12) .. "STATE")
    for _, b in ipairs(rows) do
        local state = b.state
        if b.error then state = state .. ": " .. tostring(b.error):match("^[^\n]*") end
        print(pad(b.address:sub(1, 8), 10) .. pad(b.type, 14) .. pad(b.driver, 14)
            .. pad(b.node and ("/dev/" .. b.node), 12) .. state)
    end
elseif command == "drivers" then
    print(pad("DRIVER", 14) .. pad("MATCH", 20) .. pad("USED", 6) .. "DESCRIPTION")
    for _, d in ipairs(device.drivers()) do
        print(pad(d.name, 14) .. pad(table.concat(d.match, ","), 20)
            .. pad(d.loaded and tostring(d.refs) or "-", 6) .. (d.desc or ""))
    end
elseif command == "bind" then
    local ok, err = device.bind(resolve(args[2]), args[3])
    if not ok then fail(err) end
elseif command == "unbind" then
    local ok, err = device.unbind(resolve(args[2]))
    if not ok then fail(err) end
elseif command == "rescan" then
    local ok, err = device.rescan()
    if not ok then fail(err) end
elseif command == "-h" or command == "--help" or command == "help" then
    print("usage: devctl [list | drivers | bind <addr> [driver] | unbind <addr> | rescan]")
else
    fail("unknown command '" .. command .. "' (try devctl help)")
end
