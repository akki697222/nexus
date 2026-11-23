-- installer/nexus-install.lua - install Nexus from a boot image (OpenOS)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   nexus-install <base> <address|label> [reboot] [--force]
--
-- <base> is an HTTP(S) URL prefix or a local directory holding the
-- distribution built by `lua tools/nximg.lua dist <dir>`:
--   nexusos     -> /boot/nexusos   (NXIMG: kernel, /usr, initial /etc)
--   init.lua    -> /init.lua       (image boot loader)
--   config.lua  -> /boot/config.lua (only if the target has none yet)
--
-- Files are copied as they are, chunk by chunk: nothing is decompressed
-- here, so no data card is needed and memory use stays at one chunk. Each
-- file is written to "<name>.new" and renamed into place once complete.

local argv = { ... }

local base, target
local reboot, force = false, false
for _, token in ipairs(argv) do
    if token == "reboot" or token == "--reboot" then
        reboot = true
    elseif token == "force" or token == "--force" then
        force = true
    elseif not base then
        base = token
    elseif not target then
        target = token
    end
end

local component = require("component")
local computer = require("computer")

local function fail(message)
    io.stderr:write("nexus-install: " .. tostring(message) .. "\n")
    return 1
end

local function describe(address)
    local label = component.invoke(address, "getLabel")
    local readOnly = component.invoke(address, "isReadOnly")
    local total = component.invoke(address, "spaceTotal") or 0
    local used = component.invoke(address, "spaceUsed") or 0
    return string.format("%s  %-16s %6d/%6d KB %s", address, label or "",
        math.floor((total - used) / 1024), math.floor(total / 1024),
        readOnly and "ro" or "rw")
end

if not base or not target then
    print("usage: nexus-install <url|dir> <address|label> [reboot] [--force]")
    print("targets:")
    for address in component.list("filesystem") do
        print("  " .. describe(address))
    end
    return 1
end

local targetAddress
for address in component.list("filesystem") do
    if address == target then
        targetAddress = address
        break
    end
end
if not targetAddress then
    for address in component.list("filesystem") do
        if component.invoke(address, "getLabel") == target then
            targetAddress = address
            break
        end
    end
end
if not targetAddress then
    return fail("no filesystem matches '" .. tostring(target) .. "'")
end
if component.invoke(targetAddress, "isReadOnly") then
    return fail("target is read-only: " .. targetAddress)
end
local bootAddress = computer.getBootAddress and computer.getBootAddress()
if targetAddress == bootAddress and not force then
    return fail("refusing to install over the running boot disk; pass --force if that is intended")
end

local disk = component.proxy(targetAddress)
local remote = base:match("^%a[%w+.-]*://") ~= nil
base = base:gsub("/+$", "")

-- Returns a chunk iterator for one distribution file.
local function source(name)
    if remote then
        local internet = require("internet")
        local ok, request = pcall(internet.request, base .. "/" .. name)
        if not ok then return nil, request end
        return function()
            local ok2, chunk = pcall(request)
            if not ok2 then error(chunk, 0) end
            return chunk
        end
    end
    local file, err = io.open(base .. "/" .. name, "rb")
    if not file then return nil, err end
    return function()
        local chunk = file:read(8192)
        if not chunk then file:close() end
        return chunk
    end
end

local crcTable = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if crc & 1 == 1 then crc = (crc >> 1) ~ 0xEDB88320 else crc = crc >> 1 end
    end
    crcTable[i] = crc
end
local function crc32(data)
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = crcTable[(crc ~ data:byte(i)) & 0xFF] ~ (crc >> 8)
    end
    return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

-- Validates an NXIMG from its first bytes and returns its expected size.
-- Returns nil while more bytes are needed.
local function imageSize(head)
    if #head < 32 then return nil end
    if head:sub(1, 6) ~= "NXIMG\0" then error("not a Nexus boot image", 0) end
    local version, _, _, sectionCount, _, blockCount, dataOffset, metaCrc, headCrc =
        string.unpack("<BBI4I2I2I4I4I4I4", head, 7)
    if version ~= 1 then error("unsupported image version " .. version, 0) end
    if crc32(head:sub(1, 28)) ~= headCrc then error("image header checksum mismatch", 0) end
    if #head < dataOffset then return nil end
    if crc32(head:sub(33, dataOffset)) ~= metaCrc then error("image index checksum mismatch", 0) end
    local last = string.unpack("<I4", head, 33 + sectionCount * 24 + blockCount * 4)
    return dataOffset + last
end

-- Streams one file to path.new on the target, then renames it into place.
local function install(name, path, validateImage)
    local nextChunk, err = source(name)
    if not nextChunk then error(name .. ": " .. tostring(err), 0) end
    local temp = path .. ".new"
    local handle, openErr = disk.open(temp, "wb")
    if not handle then error("cannot create " .. temp .. ": " .. tostring(openErr), 0) end
    local written, head, expected = 0, "", nil
    local ok, result = pcall(function()
        while true do
            local chunk = nextChunk()
            if not chunk then break end
            if #chunk > 0 then
                if validateImage and not expected then
                    head = head .. chunk
                    expected = imageSize(head)
                    if expected then head = nil end
                end
                local wrote, writeErr = disk.write(handle, chunk)
                if not wrote then error("write failed for " .. temp .. ": " .. tostring(writeErr), 0) end
                written = written + #chunk
                io.write(".")
            end
        end
        if validateImage then
            if not expected then error(name .. ": truncated image header", 0) end
            if written ~= expected then
                error(string.format("%s: size %d, expected %d", name, written, expected), 0)
            end
        elseif written == 0 then
            error(name .. ": empty file", 0)
        end
    end)
    disk.close(handle)
    if not ok then
        disk.remove(temp)
        error(result, 0)
    end
    if disk.exists(path) then disk.remove(path) end
    if not disk.rename(temp, path) then
        error("cannot move " .. temp .. " to " .. path, 0)
    end
    return written
end

print("Installing Nexus to " .. describe(targetAddress))
local ok, err = pcall(function()
    if not disk.isDirectory("/boot") then
        assert(disk.makeDirectory("/boot"), "cannot create /boot")
    end
    local size = install("nexusos", "/boot/nexusos", true)
    install("init.lua", "/init.lua")
    local keptConfig = disk.exists("/boot/config.lua")
    if not keptConfig then
        install("config.lua", "/boot/config.lua")
    end
    io.write("\n")
    print(string.format("Installed boot image (%d bytes)%s.", size,
        keptConfig and ", kept existing /boot/config.lua" or ""))
end)
if not ok then
    io.write("\n")
    return fail(err)
end

pcall(disk.setLabel, "Nexus")
if computer.setBootAddress then
    pcall(computer.setBootAddress, targetAddress)
end
print("Boot device is now " .. targetAddress .. ".")

if reboot then
    computer.shutdown(true)
end

return 0
