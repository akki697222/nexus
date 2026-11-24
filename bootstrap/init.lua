-- /init.lua - Nexus image boot (installed systems)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Boots the kernel section of /boot/nexusos (NXIMG, see tools/nximg.lua).
-- Blocks are inflated one at a time and fed to load() as separate pieces,
-- so the kernel source never exists as one string. Compressed images are
-- inflated by a data card when there is one, otherwise in Lua (slower).
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

-- zlib (RFC 1950/1951) inflate in Lua, for machines without a data card.
-- Decoding follows zlib's puff.c: canonical Huffman codes are decoded bit
-- by bit from per-length counts, which keeps the tables tiny. Each image
-- block is a standalone zlib stream of at most one block size, so the
-- whole output stays in memory and doubles as the LZ77 window.
local softInflate
do
    local byte, char, unpack = string.byte, string.char, table.unpack
    local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
    local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
    local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
    local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
    local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

    -- lengths[0..n-1] -> { count[1..15], symbol[0..] }
    local function huffman(lengths, n)
        local count, offs, symbol = {}, {}, {}
        for len = 0, 15 do count[len] = 0 end
        for sym = 0, n - 1 do count[lengths[sym]] = count[lengths[sym]] + 1 end
        local left = 1
        for len = 1, 15 do
            left = left * 2 - count[len]
            if left < 0 then error("over-subscribed code", 0) end
        end
        offs[1] = 0
        for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
        for sym = 0, n - 1 do
            local len = lengths[sym]
            if len ~= 0 then
                symbol[offs[len]] = sym
                offs[len] = offs[len] + 1
            end
        end
        return { count = count, symbol = symbol }
    end

    local fixedL, fixedD
    local function fixed()
        if not fixedL then
            local l = {}
            for i = 0, 143 do l[i] = 8 end
            for i = 144, 255 do l[i] = 9 end
            for i = 256, 279 do l[i] = 7 end
            for i = 280, 287 do l[i] = 8 end
            fixedL = huffman(l, 288)
            local d = {}
            for i = 0, 29 do d[i] = 5 end
            fixedD = huffman(d, 30)
        end
        return fixedL, fixedD
    end

    ---@param data string zlib stream
    ---@return string
    softInflate = function(data)
        local pos, bitbuf, bitcnt = 3, 0, 0
        local cmf, flg = byte(data, 1, 2)
        if not flg or cmf & 15 ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or flg & 32 ~= 0 then
            error("not a zlib stream", 0)
        end
        local function bits(need)
            while bitcnt < need do
                local b = byte(data, pos)
                if not b then error("truncated stream", 0) end
                pos = pos + 1
                bitbuf = bitbuf | (b << bitcnt)
                bitcnt = bitcnt + 8
            end
            local v = bitbuf & ((1 << need) - 1)
            bitbuf = bitbuf >> need
            bitcnt = bitcnt - need
            return v
        end
        local function decode(h)
            local count, code, first, index = h.count, 0, 0, 0
            for len = 1, 15 do
                if bitcnt == 0 then
                    local b = byte(data, pos)
                    if not b then error("truncated stream", 0) end
                    pos = pos + 1
                    bitbuf, bitcnt = b, 8
                end
                code = code | (bitbuf & 1)
                bitbuf = bitbuf >> 1
                bitcnt = bitcnt - 1
                local c = count[len]
                if code - c < first then return h.symbol[index + code - first] end
                index = index + c
                first = (first + c) << 1
                code = code << 1
            end
            error("invalid code", 0)
        end

        -- Output: finished 1 KiB pieces as strings plus the piece being
        -- written as bytes, so a 16 KiB block never needs a 16K-entry table.
        -- The Adler-32 sums are kept as pieces are finished.
        local CH = 1024
        local done, buf, bn, base, n = {}, {}, 0, 0, 0
        local s1, s2 = 1, 0
        local function flush(count)
            for i = 1, count do
                s1 = (s1 + buf[i]) % 65521
                s2 = (s2 + s1) % 65521
            end
            done[#done + 1] = char(unpack(buf, 1, count))
            base = base + count
            bn = 0
        end
        local function put(v)
            bn = bn + 1
            buf[bn] = v
            n = n + 1
            if bn == CH then flush(CH) end
        end
        local function get(k)
            if k > base then return buf[k - base] end
            return byte(done[(k - 1) // CH + 1], (k - 1) % CH + 1)
        end
        repeat
            local last = bits(1)
            local btype = bits(2)
            if btype == 0 then
                bitbuf, bitcnt = 0, 0
                local len, nlen = string.unpack("<I2I2", data, pos)
                if len ~ 0xFFFF ~= nlen then error("bad stored block", 0) end
                pos = pos + 4
                if pos + len - 1 > #data then error("truncated stream", 0) end
                for i = pos, pos + len - 1 do put(byte(data, i)) end
                pos = pos + len
            elseif btype == 3 then
                error("invalid block type", 0)
            else
                local lcode, dcode
                if btype == 1 then
                    lcode, dcode = fixed()
                else
                    local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
                    local lengths = {}
                    for i = 0, 18 do lengths[i] = 0 end
                    for i = 1, ncode do lengths[ORDER[i]] = bits(3) end
                    local lencode = huffman(lengths, 19)
                    local i = 0
                    while i < nlen + ndist do
                        local sym = decode(lencode)
                        if sym < 16 then
                            lengths[i] = sym
                            i = i + 1
                        else
                            local value, rep = 0, 0
                            if sym == 16 then
                                if i == 0 then error("repeat with no first length", 0) end
                                value, rep = lengths[i - 1], 3 + bits(2)
                            elseif sym == 17 then
                                rep = 3 + bits(3)
                            else
                                rep = 11 + bits(7)
                            end
                            if i + rep > nlen + ndist then error("too many lengths", 0) end
                            for _ = 1, rep do
                                lengths[i] = value
                                i = i + 1
                            end
                        end
                    end
                    local dl = {}
                    for k = 0, ndist - 1 do dl[k] = lengths[nlen + k] end
                    lcode, dcode = huffman(lengths, nlen), huffman(dl, ndist)
                end
                while true do
                    local sym = decode(lcode)
                    if sym < 256 then
                        put(sym)
                    elseif sym == 256 then
                        break
                    else
                        sym = sym - 256
                        if sym > 29 then error("bad length symbol", 0) end
                        local len = LBASE[sym] + bits(LEXT[sym])
                        local dsym = decode(dcode) + 1
                        if dsym > 30 then error("bad distance symbol", 0) end
                        local dist = DBASE[dsym] + bits(DEXT[dsym])
                        if dist > n then error("distance too far back", 0) end
                        for _ = 1, len do put(get(n + 1 - dist)) end
                    end
                end
            end
        until last == 1

        if bn > 0 then flush(bn) end
        -- Adler-32 trailer (big endian, after the last whole byte)
        if #data < pos + 3 or string.unpack(">I4", data, pos) ~= s2 * 65536 + s1 then
            error("adler32 mismatch", 0)
        end
        return table.concat(done)
    end
end

local inflate
if compression == 1 then
    local dataCard = component.list("data")()
    if dataCard then
        inflate = function(stored)
            local raw, err = invoke(dataCard, "inflate", stored)
            if not raw then
                fail("inflate failed: " .. tostring(err))
            end
            return raw
        end
    else
        -- Without a data card: inflate in Lua, yielding between blocks so
        -- the machine is not stopped for running too long.
        inflate = function(stored)
            computer.pullSignal(0)
            local ok, raw = pcall(softInflate, stored)
            if not ok then
                fail("inflate failed: " .. tostring(raw))
            end
            return raw
        end
    end
elseif compression ~= 0 then
    fail("unknown compression " .. compression)
end

-- Boot screen: a progress bar while the kernel blocks are read. Nothing is
-- drawn without a GPU and a screen. The kernel clears the screen when its
-- console starts.
local progress
do
    local gpu, screen = component.list("gpu")(), component.list("screen")()
    if gpu and screen then
        invoke(gpu, "bind", screen)
        local w, h = 50, 16
        local width = math.max(10, math.min(w - 8, 48))
        local x = math.floor((w - width - 5) / 2) + 1
        local y = math.floor(h / 2) + 1
        local shown = -1
        invoke(gpu, "setResolution", w, h)
        invoke(gpu, "setForeground", 0xFFFFFF)
        invoke(gpu, "setBackground", 0x000000)
        invoke(gpu, "fill", 1, 1, w, h, " ")
        progress = {}
        function progress.title(text)
            text = text:sub(1, w)
            invoke(gpu, "fill", 1, y - 2, w, 1, " ")
            invoke(gpu, "set", math.max(1, math.floor((w - #text) / 2) + 1), y - 2, text)
        end
        function progress.set(fraction)
            local filled = math.floor(fraction * width + 0.5)
            if filled == shown then return end
            shown = filled
            invoke(gpu, "set", x, y, string.rep("\u{2588}", filled) .. string.rep("\u{2591}", width - filled)
                .. string.format(" %3d%%", math.floor(fraction * 100 + 0.5)))
        end
        progress.title("Loading " .. IMAGE)
        progress.set(0)
    end
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
    if progress then
        progress.set((i - kernel.firstBlock + 1) / kernel.blockCount)
    end
end
invoke(bootAddress, "close", handle)
if total ~= kernel.rawSize then
    fail("kernel section incomplete")
end
if not inflate and crc ~= kernel.crc then
    fail("kernel checksum mismatch")
end
meta = nil
if progress then
    progress.title("Starting kernel...")
end

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

-- imgfs uses this for /usr when there is no data card
NEXUS_INFLATE = softInflate

local ok, err = xpcall(chunk, debug.traceback, table.unpack(KERNEL_ARGS))
if not ok then
    error(err, 0)
end
