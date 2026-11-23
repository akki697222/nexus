-- syslogd: writes the system log (kernel and system.log messages) to
-- /var/log/messages, rotating it into messages.1 .. messages.N.
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local system = require("system")
local event = require("event")

local LOG_DIR = "/var/log"
local LOG_FILE = LOG_DIR .. "/messages"
local MAX_SIZE = 32 * 1024 -- rotate past this many bytes
local KEEP = 3              -- messages.1 .. messages.3
local INTERVAL = 1          -- seconds between reads of the kernel log

local host = os.getenv("HOSTNAME") or "nexus"

local function ensureDir(path)
    if fs.isDirectory(path) then return true end
    local parent = fs.path(path)
    if parent and parent ~= path and not fs.isDirectory(parent) then ensureDir(parent) end
    return fs.makeDirectory(path)
end

local function rotate()
    if not fs.exists(LOG_FILE) or (fs.size(LOG_FILE) or 0) < MAX_SIZE then return end
    local oldest = LOG_FILE .. "." .. KEEP
    if fs.exists(oldest) then fs.remove(oldest) end
    for i = KEEP - 1, 1, -1 do
        local from = LOG_FILE .. "." .. i
        if fs.exists(from) then fs.rename(from, LOG_FILE .. "." .. (i + 1)) end
    end
    fs.rename(LOG_FILE, LOG_FILE .. ".1")
end

local function format(e)
    local ident = e.tag
    if e.pid then ident = string.format("%s[%d]", e.tag, e.pid) end
    local level = (e.level ~= "info" and e.level ~= "notice") and ("<" .. e.level .. "> ") or ""
    return string.format("%s %s %s: %s%s\n", os.date("%b %d %H:%M:%S", e.time), host, ident, level, e.msg)
end

local function append(lines)
    local f, err = fs.open(LOG_FILE, "a")
    if not f then return nil, err end
    f:write(table.concat(lines))
    f:close()
    return true
end

if not ensureDir(LOG_DIR) then
    system.log("cannot create " .. LOG_DIR, "syslogd", "err")
    return 1
end
if not fs.exists(LOG_FILE) then
    local f = fs.open(LOG_FILE, "w")
    if f then f:close() end
    fs.chmod(LOG_FILE, 640)
end

local last = 0
local reported = false
while true do
    local entries, newest, oldest = system.readLog(last)
    if #entries > 0 then
        local lines = {}
        if last > 0 and oldest > last + 1 then
            lines[1] = format({ time = entries[1].time, tag = "syslogd", level = "warning",
                msg = string.format("%d messages lost", oldest - last - 1) })
        end
        for _, e in ipairs(entries) do lines[#lines + 1] = format(e) end
        local ok, err = append(lines)
        if ok then
            last = newest
            reported = false
            rotate()
        elseif not reported then
            system.log("cannot write " .. LOG_FILE .. ": " .. tostring(err), "syslogd", "err")
            reported = true
        end
    end
    event.pullFiltered(INTERVAL, function() return false end)
end
