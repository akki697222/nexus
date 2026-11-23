-- /init.lua - Nexus image boot (installed systems)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Boots the kernel section of /boot/nexusos (NXIMG, see tools/nximg.lua).
-- Blocks are inflated one at a time and fed to load() as separate pieces,
-- so the kernel source never exists as one string. Compressed images need a
-- data card; store images boot without one.
--
-- Development setups keep using root/init.lua, which loads a plain
-- /boot/kernel.lua.

---@type oc_env
_ENV = _ENV

local IMAGE = "/boot/nexusos"
local KERNEL_ARGS = { "init=/usr/sbin/init.lua", "image=" .. IMAGE }

local invoke = component.invoke
local bootAddress = computer.getBootAddress()

-- The kernel (base.lua) expects a boot-filesystem loadfile.
---@param env? table
loadfile = function(file, env)
    local handle, reason = invoke(bootAddress, "open", file)
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
    return load(table.concat(parts), "=" .. file, "bt", env or _ENV)
end

local function fail(message)
    error("nexusos: " .. message, 0)
end

local handle, openErr = invoke(bootAddress, "open", IMAGE)
if not handle then
    fail("cannot open " .. IMAGE .. ": " .. tostring(openErr))
end

-- Filesystem reads return at most a few KiB per call.
local function readAt(offset, length)
    invoke(bootAddress, "seek", handle, "set", offset)
    local parts, got = {}, 0
    while got < length do
        local data = invoke(bootAddress, "read", handle, length - got)
        if not data then
            fail("truncated image")
        end
        parts[#parts + 1] = data
        got = got + #data
    end
    return table.concat(parts)
end

local crcTable = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if crc & 1 == 1 then crc = (crc >> 1) ~ 0xEDB88320 else crc = crc >> 1 end
    end
    crcTable[i] = crc
end
local function crc32(data, crc)
    crc = (crc or 0) ~ 0xFFFFFFFF
    for i = 1, #data do
        crc = crcTable[(crc ~ data:byte(i)) & 0xFF] ~ (crc >> 8)
    end
    return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

-- Header, section table and block index.
local header = readAt(0, 32)
if header:sub(1, 6) ~= "NXIMG\0" then
    fail(IMAGE .. " is not a Nexus boot image")
end
local version, compression, blockSize, sectionCount, _, blockCount, dataOffset, metaCrc, headCrc =
    string.unpack("<BBI4I2I2I4I4I4I4", header, 7)
if version ~= 1 then
    fail("unsupported image version " .. version)
end
if crc32(header:sub(1, 28)) ~= headCrc then
    fail("header checksum mismatch")
end
local meta = readAt(32, dataOffset - 32)
if crc32(meta) ~= metaCrc then
    fail("index checksum mismatch")
end

local kernel
for i = 0, sectionCount - 1 do
    local typ, _, _, rawSize, firstBlock, nblocks, crc = string.unpack("<BBI2I4I4I4I4", meta, i * 24 + 1)
    if typ == 1 then
        kernel = { rawSize = rawSize, firstBlock = firstBlock, blockCount = nblocks, crc = crc }
        break
    end
end
if not kernel or kernel.blockCount == 0 then
    fail("image has no kernel section")
end
local indexBase = sectionCount * 24 + 1
local function blockOffset(i)
    return (string.unpack("<I4", meta, indexBase + i * 4))
end

local inflate
if compression == 1 then
    local dataCard = component.list("data")()
    if not dataCard then
        fail("compressed image needs a data card")
    end
    inflate = function(stored)
        local raw, err = invoke(dataCard, "inflate", stored)
        if not raw then
            fail("inflate failed: " .. tostring(err))
        end
        return raw
    end
elseif compression ~= 0 then
    fail("unknown compression " .. compression)
end

-- Read and inflate every kernel block first, then hand the pieces to
-- load(). The reader must not touch components: load() calls it from C,
-- and component.invoke may yield once the per-tick call budget is spent
-- ("attempt to yield across a C-call boundary"). The kernel source is
-- still never concatenated into one string, and each piece is released as
-- soon as the compiler has consumed it.
local pieces = {}
local lastBlock = kernel.firstBlock + kernel.blockCount - 1
local total, crc = 0, 0
for i = kernel.firstBlock, lastBlock do
    local a, b = blockOffset(i), blockOffset(i + 1)
    local stored = readAt(dataOffset + a, b - a)
    local raw = inflate and inflate(stored) or stored
    stored = nil
    local want = i == lastBlock and (kernel.rawSize - (kernel.blockCount - 1) * blockSize) or blockSize
    if #raw ~= want then
        fail("kernel block " .. i .. " has wrong size")
    end
    total = total + #raw
    if not inflate then
        crc = crc32(raw, crc)
    end
    pieces[#pieces + 1] = raw
end
invoke(bootAddress, "close", handle)
if total ~= kernel.rawSize then
    fail("kernel section incomplete")
end
if not inflate and crc ~= kernel.crc then
    fail("kernel checksum mismatch")
end
meta = nil

local nextPiece = 0
local chunk, loadErr = load(function()
    nextPiece = nextPiece + 1
    local piece = pieces[nextPiece]
    pieces[nextPiece] = nil
    return piece
end, "=kernel", "t", _ENV)
pieces = nil
if not chunk then
    fail("cannot load kernel: " .. tostring(loadErr))
end

local ok, err = xpcall(chunk, debug.traceback, table.unpack(KERNEL_ARGS))
if not ok then
    error(err, 0)
end
