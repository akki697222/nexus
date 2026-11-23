-- tools/pack_kernel.lua - build a gzip-compressed kernel image (kernel.lua.gz)
-- Run from the nexus root with: lua tools/pack_kernel.lua [input] [output]
-- Defaults: build/kernel.lua -> build/kernel.lua.gz
--
-- The payload is raw DEFLATE produced by LibDeflate (the same library shipped
-- in root/usr/lib), wrapped in a standard gzip container so any external tool
-- (gzip, 7-Zip, python, ...) can produce or inspect the image as well.
-- At boot the loader strips the gzip header/trailer and inflates the payload
-- with LibDeflate:DecompressDeflate.

local input = arg[1] or "build/kernel.lua"
local output = arg[2] or (input .. ".gz")

local libdeflate = assert(loadfile("root/usr/lib/libdeflate.lua"))()

local function readAll(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end

-- CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as required by gzip.
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

local function le32(n)
    return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
end

local source = readAll(input)
local payload = assert(libdeflate:CompressDeflate(source, { level = 8 }))

-- gzip header: magic, CM=deflate, FLG=0, MTIME=0, XFL=2 (max compression), OS=unknown
local header = "\31\139\8\0\0\0\0\0\2\255"
local image = header .. payload .. le32(crc32(source)) .. le32(#source % 2^32)

local out = assert(io.open(output, "wb"))
out:write(image)
out:close()

print(string.format("Packed %s (%d bytes) -> %s (%d bytes, %.1f%%)",
    input, #source, output, #image, #image / #source * 100))
