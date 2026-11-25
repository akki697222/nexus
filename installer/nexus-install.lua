-- installer/nexus-install.lua - install Nexus from a boot image (OpenOS)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- One command from OpenOS (internet card required):
--
--   wget -f https://github.com/akki697222/nexus/releases/download/v0.0.6/nexus-install.lua /tmp/nexus-install.lua && /tmp/nexus-install.lua
--
--   nexus-install [<address|label>] [-y] [--upgrade] [--from <url|dir>] [--reboot]
--
-- The target defaults to the boot disk, the disk OpenOS is running from.
-- A clean install ERASES the whole target after a confirmation (-y skips
-- it) and then writes the distribution built by `lua tools/nximg.lua dist`:
--   nexusos     -> /boot/nexusos    (NXIMG: kernel, /usr, initial /etc)
--   init.lua    -> /init.lua        (image boot loader)
--   config.lua  -> /boot/config.lua
-- --upgrade replaces only /boot/nexusos and /init.lua and keeps the rest of
-- the disk, including an existing /boot/config.lua.
--
-- Everything is downloaded and checked before anything is erased: into
-- /.nexus-install on the target, or into memory when the target has too
-- little free space. Nothing is decompressed here, so no data card is
-- needed. Installing to the boot disk always reboots into Nexus.

local RELEASE = "v0.0.6"
local DEFAULT_BASE = "https://github.com/akki697222/nexus/releases/download/" .. RELEASE
local STAGE = "/.nexus-install"
local STAGE_SPACE = 320 * 1024 -- free space needed to stage on the target
local MEMORY_NEEDED = 640 * 1024 -- free memory needed to stage in memory

local argv = { ... }

local target, base
local assumeYes, upgrade, reboot = false, false, false
local i = 1
while i <= #argv do
    local token = argv[i]
    if token == "-y" or token == "--yes" then
        assumeYes = true
    elseif token == "--upgrade" then
        upgrade = true
    elseif token == "reboot" or token == "--reboot" then
        reboot = true
    elseif token == "--from" then
        i = i + 1
        base = argv[i]
    elseif token == "-h" or token == "--help" then
        target = false
    elseif target == nil then
        target = token
    end
    i = i + 1
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

local bootAddress = computer.getBootAddress and computer.getBootAddress()

if target == false then
    print("usage: nexus-install [<address|label>] [-y] [--upgrade] [--from <url|dir>] [--reboot]")
    print("  without a target, installs to the boot disk (marked *)")
    print("targets:")
    for address in component.list("filesystem") do
        print((address == bootAddress and "* " or "  ") .. describe(address))
    end
    return 0
end

local targetAddress
if target == nil then
    targetAddress = bootAddress
else
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
end
if not targetAddress then
    return fail("no filesystem matches '" .. tostring(target or "boot disk") .. "'")
end
if component.invoke(targetAddress, "isReadOnly") then
    return fail("target is read-only: " .. targetAddress)
end
local onBootDisk = targetAddress == bootAddress
if onBootDisk then reboot = true end

local disk = component.proxy(targetAddress)
base = (base or DEFAULT_BASE):gsub("/+$", "")
local remote = base:match("^%a[%w+.-]*://") ~= nil
-- loaded up front: a clean install of the boot disk erases OpenOS's libraries
local internet = remote and require("internet")

print("Nexus " .. RELEASE .. " installer")
print("  from:   " .. base)
print("  target: " .. describe(targetAddress) .. (onBootDisk and "  (boot disk)" or ""))
if upgrade then
    print("Upgrade: /boot/nexusos and /init.lua are replaced, everything else is kept.")
else
    print("")
    print("WARNING: ALL DATA ON THIS DISK WILL BE ERASED.")
    if onBootDisk then
        print("This is the disk OpenOS is running from: OpenOS and every file on it")
        print("(/home included) are deleted, and the computer reboots into Nexus.")
    end
    if not assumeYes then
        io.write("Type 'yes' to continue: ")
        local answer = io.read()
        if answer ~= "yes" then
            print("Aborted, nothing was changed.")
            return 1
        end
    end
end

-- Returns a chunk iterator for one distribution file.
local function source(name)
    if remote then
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
for n = 0, 255 do
    local crc = n
    for _ = 1, 8 do
        if crc & 1 == 1 then crc = (crc >> 1) ~ 0xEDB88320 else crc = crc >> 1 end
    end
    crcTable[n] = crc
end
local function crc32(data)
    local crc = 0xFFFFFFFF
    for n = 1, #data do
        crc = crcTable[(crc ~ data:byte(n)) & 0xFF] ~ (crc >> 8)
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

local function writeFile(path, chunks)
    local handle, openErr = disk.open(path, "wb")
    if not handle then error("cannot create " .. path .. ": " .. tostring(openErr), 0) end
    for _, chunk in ipairs(chunks) do
        local wrote, writeErr = disk.write(handle, chunk)
        if not wrote then
            disk.close(handle)
            error("write failed for " .. path .. ": " .. tostring(writeErr), 0)
        end
    end
    disk.close(handle)
end

local function moveInto(from, path)
    if disk.exists(path) then disk.remove(path) end
    if not disk.rename(from, path) then
        error("cannot move " .. from .. " to " .. path, 0)
    end
end

-- Downloads one file into the stage: a file under STAGE, or a list of
-- chunks in memory. Returns the staged entry and its size.
local function fetch(name, toMemory, validateImage)
    local nextChunk, err = source(name)
    if not nextChunk then error(name .. ": " .. tostring(err), 0) end
    local staged = { name = name }
    local handle
    if toMemory then
        staged.chunks = {}
    else
        staged.path = STAGE .. "/" .. name
        local openErr
        handle, openErr = disk.open(staged.path, "wb")
        if not handle then error("cannot create " .. staged.path .. ": " .. tostring(openErr), 0) end
    end
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
                if handle then
                    local wrote, writeErr = disk.write(handle, chunk)
                    if not wrote then error("write failed for " .. staged.path .. ": " .. tostring(writeErr), 0) end
                else
                    staged.chunks[#staged.chunks + 1] = chunk
                end
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
    if handle then disk.close(handle) end
    if not ok then error(result, 0) end
    return staged, written
end

-- Places a staged file at path.
local function place(staged, path)
    if staged.path then
        moveInto(staged.path, path)
    else
        writeFile(path .. ".new", staged.chunks)
        moveInto(path .. ".new", path)
    end
end

-- Deletes everything on the target except the stage, deepest first.
local function wipe(dir)
    local entries = disk.list(dir) or {}
    for _, name in ipairs(entries) do
        local full = dir .. name
        local isDir = name:sub(-1) == "/"
        if isDir then full = full:sub(1, -2) end
        if full ~= STAGE then
            if isDir then wipe(full .. "/") end
            disk.remove(full)
        end
    end
end

local function removeStage()
    if disk.exists(STAGE) then
        wipe(STAGE .. "/")
        disk.remove(STAGE)
    end
end

local free = (disk.spaceTotal() or 0) - (disk.spaceUsed() or 0)
local toMemory = false
if free < STAGE_SPACE then
    if computer.freeMemory() < MEMORY_NEEDED then
        return fail(string.format("not enough space to download: %d KB free on the target, %d KB of memory free",
            math.floor(free / 1024), math.floor(computer.freeMemory() / 1024)))
    end
    toMemory = true
end

io.write("Downloading")
local erased = false
local ok, err = pcall(function()
    removeStage()
    if not toMemory then
        if not disk.makeDirectory(STAGE) then error("cannot create " .. STAGE, 0) end
    end
    local files = {}
    local size
    files.image, size = fetch("nexusos", toMemory, true)
    files.init = fetch("init.lua", toMemory)
    local keepConfig = upgrade and disk.exists("/boot/config.lua")
    if not keepConfig then files.config = fetch("config.lua", toMemory) end
    io.write("\n")

    if not upgrade then
        print("Erasing " .. targetAddress .. "...")
        erased = true
        wipe("/")
    end
    if not disk.isDirectory("/boot") then
        if not disk.makeDirectory("/boot") then error("cannot create /boot", 0) end
    end
    place(files.image, "/boot/nexusos")
    place(files.init, "/init.lua")
    if files.config then place(files.config, "/boot/config.lua") end
    removeStage()
    print(string.format("Installed boot image (%d bytes)%s.", size,
        keepConfig and ", kept existing /boot/config.lua" or ""))
end)
if not ok then
    io.write("\n")
    if erased then
        -- the disk is already erased: keep the downloaded files for a retry
        if not toMemory then
            io.stderr:write("nexus-install: the downloaded files are kept in " .. STAGE .. "\n")
        end
    else
        removeStage()
    end
    return fail(err)
end

disk.setLabel("Nexus")
if computer.setBootAddress then
    computer.setBootAddress(targetAddress)
end
print("Boot device is now " .. targetAddress .. ".")

if reboot then
    print("Rebooting into Nexus...")
    computer.shutdown(true)
end

return 0
