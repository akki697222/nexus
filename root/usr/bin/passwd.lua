-- passwd.lua - change a user's password
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   passwd [user]
--
-- Root only (other users run it through sudo). Without a user, changes the
-- password of the calling user, which is root under sudo.

local user = require("user")

local argv = { ... }
if argv[1] == "-h" or argv[1] == "--help" then
    print("usage: passwd [user]")
    return 0
end

if not user.checkRoot() then
    io.stderr:write("passwd: only root can change passwords (try: sudo passwd [user])\n")
    return 1
end

local name = argv[1]
if not name then
    local current = user.getCurrent()
    name = current and current.username
end
if not name or not user.getUser(name) then
    io.stderr:write("passwd: user '" .. tostring(name) .. "' does not exist\n")
    return 1
end

io.write("New password for " .. name .. ": ")
local first = io.read("l", "*")
print()
if not first or first == "" then
    io.stderr:write("passwd: password unchanged\n")
    return 1
end
io.write("Retype new password: ")
local second = io.read("l", "*")
print()
if first ~= second then
    io.stderr:write("passwd: passwords do not match, password unchanged\n")
    return 1
end

local ok, err = user.setPassword(name, first)
if not ok then
    io.stderr:write("passwd: " .. tostring(err) .. "\n")
    return 1
end
print("passwd: password updated for " .. name)
return 0
