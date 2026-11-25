-- installer/src/img.lua - reading NXIMG files (tools/nximg.lua has the format)

img = {}
img.SECTION = { kernel = 1, usr = 2, etc = 3 }

-- A reader over a file: read(offset, length) returns exactly that many bytes.
function img.reader(fs, path)
    local handle, err = fs.open(path, "rb")
    if not handle then error(path .. ": " .. tostring(err), 0) end
    local reader = { size = fs.size(path) or 0 }
    function reader.read(offset, length)
        fs.seek(handle, "set", offset)
        local parts, got = {}, 0
        while got < length do
            local data = fs.read(handle, length - got)
            if not data then error(path .. ": truncated image", 0) end
            parts[#parts + 1] = data
            got = got + #data
        end
        return table.concat(parts)
    end
    function reader.close() fs.close(handle) end
    return reader
end

-- Parses the header, section table and block index.
function img.open(reader, name)
    local head = reader.read(0, 32)
    if head:sub(1, 6) ~= "NXIMG\0" then error(name .. " is not a Nexus image", 0) end
    local version, compression, blockSize, sectionCount, _, blockCount, dataOffset, metaCrc, headCrc =
        string.unpack("<BBI4I2I2I4I4I4I4", head, 7)
    if version ~= 1 then error(name .. ": unsupported image version " .. version, 0) end
    if crc32(head:sub(1, 28)) ~= headCrc then error(name .. ": header checksum mismatch", 0) end
    local metaRaw = reader.read(32, dataOffset - 32)
    if crc32(metaRaw) ~= metaCrc then error(name .. ": index checksum mismatch", 0) end
    local info = { name = name, reader = reader, compression = compression, blockSize = blockSize,
        blockCount = blockCount, dataOffset = dataOffset, sections = {}, index = {} }
    for i = 0, sectionCount - 1 do
        local typ, _, _, rawSize, firstBlock, n, crc = string.unpack("<BBI2I4I4I4I4", metaRaw, i * 24 + 1)
        info.sections[typ] = { type = typ, rawSize = rawSize, firstBlock = firstBlock, blockCount = n, crc = crc }
    end
    local base = sectionCount * 24
    for i = 0, blockCount do
        info.index[i] = string.unpack("<I4", metaRaw, base + i * 4 + 1)
    end
    if dataOffset + info.index[blockCount] ~= reader.size then
        error(name .. ": size does not match its index", 0)
    end
    return info
end

-- Turns a stored block into its data: a data card when there is one,
-- otherwise the Lua inflater of the boot loader.
function img.inflater()
    local card = component.list("data")()
    if card then
        return function(stored)
            local raw, err = component.invoke(card, "inflate", stored)
            if not raw then error("inflate failed: " .. tostring(err), 0) end
            return raw
        end
    end
    return softInflate
end

-- Iterates the data blocks of a section, yielding between blocks so the
-- machine keeps running. Block sizes are checked; for
-- uncompressed images the section CRC-32 too (zlib streams carry their own
-- Adler-32, checked by the inflater).
function img.blocks(info, section, inflate)
    local i, last = section.firstBlock, section.firstBlock + section.blockCount - 1
    local crc, total = 0, 0
    return function()
        if i > last then
            if total ~= section.rawSize then error(info.name .. ": section is incomplete", 0) end
            if info.compression == 0 and crc ~= section.crc then
                error(info.name .. ": section checksum mismatch", 0)
            end
            return nil
        end
        util.yield()
        local a, b = info.index[i], info.index[i + 1]
        local raw = info.reader.read(info.dataOffset + a, b - a)
        if info.compression == 1 then
            raw = inflate(raw)
        elseif info.compression ~= 0 then
            error(info.name .. ": unknown compression " .. info.compression, 0)
        else
            crc = crc32(raw, crc)
        end
        local want = i == last and (section.rawSize - (section.blockCount - 1) * info.blockSize) or info.blockSize
        if #raw ~= want then error(info.name .. ": block " .. i .. " has the wrong size", 0) end
        total = total + #raw
        i = i + 1
        return raw
    end
end

-- Unpacks the NXFS tree of a section. For each entry, in path order,
-- visit(entry) is called with { path, dir, mode, uid, gid, size }; for a
-- file it returns a function that takes the data in pieces, or nil to skip
-- the file.
function img.unpack(info, section, inflate, visit)
    local nextBlock = img.blocks(info, section, inflate)
    local buf, pos = "", 1
    local function fill()
        local block = nextBlock()
        if not block then error(info.name .. ": truncated file tree", 0) end
        buf, pos = buf:sub(pos) .. block, 1
    end
    local function take(n)
        while #buf - pos + 1 < n do fill() end
        local s = buf:sub(pos, pos + n - 1)
        pos = pos + n
        return s
    end
    local head = take(16)
    if head:sub(1, 4) ~= "NXFS" or head:byte(5) ~= 1 then error(info.name .. ": not a file tree", 0) end
    local count, tocSize = string.unpack("<I4I4", head, 9)
    local toc = take(tocSize - 16)
    local entries, at = {}, 1
    for _ = 1, count do
        local pathlen, kind, _, mode, uid, gid, _, offset, size = string.unpack("<I2BBI2I2I2I2I4I4", toc, at)
        at = at + 20
        entries[#entries + 1] = { path = toc:sub(at, at + pathlen - 1), dir = kind == 2, mode = mode,
            uid = uid, gid = gid, offset = offset, size = size }
        at = at + pathlen
    end
    toc = nil
    local consumed = tocSize
    for _, e in ipairs(entries) do
        local sink = visit(e)
        if not e.dir and e.size > 0 then
            if e.offset ~= consumed then error(info.name .. ": file data out of order", 0) end
            local left = e.size
            while left > 0 do
                if pos > #buf then
                    buf, pos = nextBlock() or error(info.name .. ": truncated file tree", 0), 1
                end
                local n = math.min(left, #buf - pos + 1)
                if sink then sink(buf:sub(pos, pos + n - 1)) end
                pos = pos + n
                left = left - n
            end
            consumed = consumed + e.size
        end
        if sink then sink(nil) end
    end
    -- the last block may still be unread; reading on checks the section
    while nextBlock() do end
end
