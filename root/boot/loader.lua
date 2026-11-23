-- boot/loader.lua - Nexus compressed-kernel loader
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Loads /boot/kernel.lua.gz (gzip-wrapped raw DEFLATE), inflates it with
-- LibDeflate and boots the kernel. Falls back to an uncompressed
-- /boot/kernel.lua when no image is present, so both layouts keep working.
--
-- Expected to run in the early boot environment (root/init.lua), where
-- `component`, `computer` and a boot-address based `loadfile` are available.

local GZIP_IMAGE = "/boot/kernel.lua.gz"
local PLAIN_KERNEL = "/boot/kernel.lua"
local LIBDEFLATE = "/usr/lib/libdeflate.lua"

local invoke = component.invoke
local bootAddress = computer.getBootAddress()

local function readAll(path)
    local handle, reason = invoke(bootAddress, "open", path)
    if not handle then
        return nil, reason
    end
    local parts = {}
    while true do
        local data, err = invoke(bootAddress, "read", handle, math.huge)
        if not data then
            invoke(bootAddress, "close", handle)
            if err then
                return nil, err
            end
            break
        end
        parts[#parts + 1] = data
    end
    invoke(bootAddress, "close", handle)
    return table.concat(parts)
end

local function loadChunk(source, name, env)
    local chunk, err = load(source, "=" .. name, "bt", env or _ENV)
    if not chunk then
        return nil, err
    end
    return chunk
end

-- Strip a gzip container (RFC 1952) down to its raw DEFLATE payload.
-- Returns the payload plus the expected CRC-32 and size from the trailer.
local function parseGzip(data)
    if #data < 18 or data:byte(1) ~= 31 or data:byte(2) ~= 139 then
        return nil, "not a gzip image"
    end
    if data:byte(3) ~= 8 then
        return nil, "unsupported compression method"
    end
    local flags = data:byte(4)
    if flags & 0xE0 ~= 0 then
        return nil, "unsupported gzip flags"
    end
    local pos = 11
    if flags & 4 ~= 0 then -- FEXTRA
        if #data < pos + 2 then return nil, "truncated gzip header" end
        local xlen = data:byte(pos) + data:byte(pos + 1) * 256
        pos = pos + 2 + xlen
    end
    if flags & 8 ~= 0 then -- FNAME
        while pos <= #data and data:byte(pos) ~= 0 do pos = pos + 1 end
        pos = pos + 1
    end
    if flags & 16 ~= 0 then -- FCOMMENT
        while pos <= #data and data:byte(pos) ~= 0 do pos = pos + 1 end
        pos = pos + 1
    end
    if flags & 2 ~= 0 then -- FHCRC
        pos = pos + 2
    end
    if pos > #data - 8 then
        return nil, "truncated gzip image"
    end
    local payload = data:sub(pos, #data - 8)
    local trailer = data:sub(#data - 7)
    local function le32(s, i)
        local a, b, c, d = s:byte(i, i + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
    return payload, le32(trailer, 1), le32(trailer, 5)
end

-- CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as used by gzip.
local crc_table = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if crc & 1 == 1 then
            crc = (crc >> 1) ~ 0xEDB88320
        else
            crc = crc >> 1
        end
    end
    crc_table[i] = crc
end

local function crc32(data)
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = crc_table[(crc ~ data:byte(i)) & 0xFF] ~ (crc >> 8)
    end
    return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

local function bootKernel(chunk, ...)
    local ok, err = xpcall(chunk, debug.traceback, ...)
    if not ok then
        error(err)
    end
end

-- Compressed image first, plain kernel as fallback.
local image = readAll(GZIP_IMAGE)
if image then
    local libSource, libErr = readAll(LIBDEFLATE)
    if not libSource then
        error("loader: cannot read " .. LIBDEFLATE .. ": " .. tostring(libErr))
    end
    local libChunk, libLoadErr = loadChunk(libSource, LIBDEFLATE)
    if not libChunk then
        error("loader: cannot load LibDeflate: " .. tostring(libLoadErr))
    end
    local libdeflate = libChunk()

    local payload, crc, isize = parseGzip(image)
    if not payload then
        error("loader: " .. GZIP_IMAGE .. ": " .. tostring(crc))
    end
    local source, extra = libdeflate:DecompressDeflate(payload)
    if not source then
        error("loader: inflate failed for " .. GZIP_IMAGE)
    end
    if extra ~= 0 then
        error("loader: trailing data in " .. GZIP_IMAGE)
    end
    if isize and #source % 2^32 ~= isize then
        error("loader: size mismatch for " .. GZIP_IMAGE)
    end
    if crc and crc32(source) ~= crc then
        error("loader: checksum mismatch for " .. GZIP_IMAGE)
    end

    local chunk, err = loadChunk(source, GZIP_IMAGE)
    if not chunk then
        error("loader: cannot load kernel image: " .. tostring(err))
    end
    return bootKernel(chunk, "init=/usr/sbin/init.lua")
end

local chunk, err = loadfile(PLAIN_KERNEL)
if not chunk then
    error("Unable to load kernel: " .. tostring(err))
end
return bootKernel(chunk, "init=/usr/sbin/init.lua")
