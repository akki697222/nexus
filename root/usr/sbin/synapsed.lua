-- synapsed: device event daemon (udev-like).
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Mounts filesystems as they are attached (/mnt/<label>, or the address
-- prefix when unlabeled), unmounts them when they are removed, and runs
-- the actions of /etc/synapse.rules for any component. Rules, one per line:
--
--   <match>... <action>...
--   match:  type=<component type>  label=<label>  address=<prefix>
--   action: mount=<absolute path>  nomount  run=<absolute path>
--
--   label=backup                mount=/backup
--   address=1a2b                nomount
--   type=modem                  run=/usr/bin/netup.lua
--
-- A run program is started as `program add|remove <address> <type>`.
-- The first matching rule with a mount action decides where (or whether)
-- a filesystem is mounted; every matching run action is executed.

local fs = require("filesystem")
local system = require("system")
local event = require("event")
local process = require("process")
local component = rawget(_ENV, "component") or require("component")
local computer = rawget(_ENV, "computer") or require("computer")

local RULES = "/etc/synapse.rules"
local MOUNT_ROOT = "/mnt"
local RETRY = 5 -- seconds between attempts to unmount a busy filesystem

local function log(level, message) system.log(message, "synapsed", level) end

-- Rules -------------------------------------------------------------------

local MATCH = { type = true, label = true, address = true }
local function loadRules()
    local rules = {}
    if not fs.exists(RULES) then return rules end
    local f, err = fs.open(RULES, "r")
    if not f then
        log("err", RULES .. ": " .. tostring(err))
        return rules
    end
    local data = f:read("*a") or ""
    f:close()
    local n = 0
    for line in (data:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        line = line:gsub("#.*$", "")
        if line:find("%S") then
            local rule, bad = { match = {} }, nil
            for word in line:gmatch("%S+") do
                local key, value = word:match("^([%a_]+)=(.+)$")
                if word == "nomount" then
                    rule.nomount = true
                elseif key and MATCH[key] then
                    rule.match[key] = value
                elseif key == "mount" and value:sub(1, 1) == "/" then
                    rule.mount = value
                elseif key == "run" and value:sub(1, 1) == "/" then
                    rule.run = value
                else
                    bad = word
                end
            end
            if bad then
                log("warning", string.format("%s:%d: ignoring rule (bad word %q)", RULES, n, bad))
            elseif not (rule.mount or rule.nomount or rule.run) then
                log("warning", string.format("%s:%d: ignoring rule without an action", RULES, n))
            else
                rules[#rules + 1] = rule
            end
        end
    end
    return rules
end

local rules = loadRules()

local function matches(rule, addr, ctype, label)
    local m = rule.match
    if m.type and m.type ~= ctype then return false end
    if m.address and addr:sub(1, #m.address) ~= m.address then return false end
    if m.label and m.label ~= label then return false end
    return true
end

local function labelOf(addr)
    local ok, label = pcall(component.invoke, addr, "getLabel")
    if ok and type(label) == "string" and label ~= "" then return label end
end

local function runActions(action, addr, ctype, label)
    for _, rule in ipairs(rules) do
        if rule.run and matches(rule, addr, ctype, label) then
            local pid, err = process.exec(rule.run, { action, addr, ctype })
            if not pid or pid == -1 then
                log("err", rule.run .. ": " .. tostring(err))
            end
        end
    end
end

-- Mounting ----------------------------------------------------------------

local ours = {}       -- address -> path we mounted
local busy = {}       -- address -> path still to unmount

local function mountedAddresses()
    local set = {}
    for info, path in fs.mounts() do
        if info.address then set[info.address] = path end
    end
    return set
end

local function defaultTarget(addr, label)
    local name = label and label:gsub("[^%w%._%-]", "_") or ""
    if name == "" or name == "." or name == ".." then name = addr:sub(1, 3) end
    local inUse = {}
    for _, path in fs.mounts() do inUse[path] = true end
    local target = MOUNT_ROOT .. "/" .. name
    if inUse[target] or fs.exists(target) then target = target .. "-" .. addr:sub(1, 3) end
    return target
end

local function attach(addr)
    if mountedAddresses()[addr] then return end
    local label = labelOf(addr)
    local target
    for _, rule in ipairs(rules) do
        if (rule.mount or rule.nomount) and matches(rule, addr, "filesystem", label) then
            if rule.nomount then
                log("info", string.format("%s (%s): not mounted (rule)", addr:sub(1, 8), label or "no label"))
                return
            end
            target = rule.mount
            break
        end
    end
    if not target then
        if not fs.isDirectory(MOUNT_ROOT) then fs.makeDirectory(MOUNT_ROOT) end
        target = defaultTarget(addr, label)
    end
    local ok, err = fs.mount(addr, target)
    if ok then
        ours[addr] = target
        log("info", string.format("mounted %s (%s) on %s", addr:sub(1, 8), label or "no label", target))
    else
        log("err", string.format("cannot mount %s on %s: %s", addr:sub(1, 8), target, tostring(err)))
    end
end

local function detach(addr)
    local path = ours[addr] or busy[addr]
    if not path then return end
    local ok, err = fs.umount(path)
    if ok then
        ours[addr], busy[addr] = nil, nil
        log("info", string.format("unmounted %s from %s", addr:sub(1, 8), path))
    elseif not busy[addr] then
        ours[addr], busy[addr] = nil, path
        log("warning", string.format("%s removed but %s is %s; will retry", addr:sub(1, 8), path, tostring(err)))
    end
end

-- Main --------------------------------------------------------------------

-- coldplug: what is already attached
for addr, ctype in component.list() do
    local label = ctype == "filesystem" and labelOf(addr) or nil
    if ctype == "filesystem" and addr ~= computer.tmpAddress() then attach(addr) end
    runActions("add", addr, ctype, label)
end
log("info", string.format("started (%d rule%s)", #rules, #rules == 1 and "" or "s"))

while true do
    local name, addr, ctype = event.pull(next(busy) and RETRY or math.huge)
    if name == "component_added" and type(addr) == "string" then
        log("info", string.format("added %s %s", tostring(ctype), addr:sub(1, 8)))
        local label = ctype == "filesystem" and labelOf(addr) or nil
        if ctype == "filesystem" then attach(addr) end
        runActions("add", addr, ctype, label)
    elseif name == "component_removed" and type(addr) == "string" then
        log("info", string.format("removed %s %s", tostring(ctype), addr:sub(1, 8)))
        if ctype == "filesystem" then detach(addr) end
        runActions("remove", addr, ctype, nil)
    end
    for pending in pairs(busy) do detach(pending) end
end
