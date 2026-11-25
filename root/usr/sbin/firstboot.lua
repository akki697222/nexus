-- firstboot.lua - first boot setup
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- login runs this as root while no account can log in yet (a fresh install
-- has only root, with a locked password). It asks for the hostname, sets the
-- root password and can create a first user with sudo rights.

local user = require("user")

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns the answer, the default for an empty answer, or nil at end of input.
local function ask(prompt, default)
    io.write(prompt)
    if default then io.write(" [" .. default .. "]") end
    io.write(": ")
    local answer = io.read()
    if answer == nil then return nil end
    answer = trim(answer)
    if answer == "" then return default or "" end
    return answer
end

local function askYes(prompt, default)
    while true do
        local answer = ask(prompt .. (default and " [Y/n]" or " [y/N]"))
        if answer == nil then return nil end
        answer = answer:lower()
        if answer == "" then return default end
        if answer == "y" or answer == "yes" then return true end
        if answer == "n" or answer == "no" then return false end
    end
end

local function askPassword(label)
    while true do
        io.write(label .. ": ")
        local first = io.read("l", "*")
        print()
        if first == nil then return nil end
        if first == "" then
            print("The password must not be empty.")
        else
            io.write("Retype " .. label:sub(1, 1):lower() .. label:sub(2) .. ": ")
            local second = io.read("l", "*")
            print()
            if second == nil then return nil end
            if first == second then return first end
            print("The passwords do not match, try again.")
        end
    end
end

-- next free uid from 100 on, as user.create also uses it for the group
local function nextUid()
    local used = {}
    local file = io.open("/etc/passwd", "r")
    if file then
        local content = file:read("a") or ""
        file:close()
        for line in content:gmatch("[^\r\n]+") do
            local uid = tonumber(line:match("^[^:]*:[^:]*:(%d+):"))
            if uid then used[uid] = true end
        end
    end
    local uid = 100
    while used[uid] do uid = uid + 1 end
    return uid
end

local function appendLine(path, line)
    local file, err = io.open(path, "a")
    if not file then return nil, err end
    file:write(line .. "\n")
    file:close()
    return true
end

local function aborted()
    print("\nSetup aborted; it starts again at the next login prompt.")
    return 1
end

print("")
print("Nexus first boot setup")
print("No account can log in yet. Set the root password, and create a user for everyday use if you like.")
print("")

-- hostname
local current = os.getenv("HOSTNAME") or "nexus"
local hostname
while true do
    hostname = ask("Hostname", current)
    if hostname == nil then return aborted() end
    if #hostname <= 63 and hostname:match("^[%w][%w%-]*$") then break end
    print("Use letters, digits and '-', at most 63 characters.")
end
local file, err = io.open("/etc/hostname", "w")
if file then
    file:write(hostname .. "\n")
    file:close()
else
    print("Cannot write /etc/hostname: " .. tostring(err))
end

-- root password
print("")
local rootPassword = askPassword("New root password")
if rootPassword == nil then return aborted() end
local ok, setErr = user.setPassword("root", rootPassword)
if not ok then
    print("Cannot set the root password: " .. tostring(setErr))
    return 1
end
print("Root password set.")

-- first user
print("")
while true do
    local name = ask("Create a user (empty to skip)")
    if name == nil then return aborted() end
    if name == "" then break end
    if not name:match("^[%l_][%l%d_%-]*$") or #name > 32 then
        print("Use lowercase letters, digits, '_' and '-', starting with a letter or '_'.")
    elseif user.getUser(name) then
        print("User " .. name .. " already exists.")
    else
        local password = askPassword("Password for " .. name)
        if password == nil then return aborted() end
        local sudo = askYes("Allow " .. name .. " to use sudo", true)
        if sudo == nil then return aborted() end
        local uid = nextUid()
        user.create(name, password, uid, uid)
        if not user.getUser(name) then
            print("Cannot create user " .. name .. ".")
        else
            if sudo then
                local added, sudoErr = appendLine("/etc/sudoers", name .. " ALL=(root) ALL")
                if not added then print("Cannot update /etc/sudoers: " .. tostring(sudoErr)) end
            end
            print("User " .. name .. " created" .. (sudo and " (sudo allowed)." or "."))
        end
        break
    end
end

print("")
print("Setup complete. Log in below.")
print("")
return 0
