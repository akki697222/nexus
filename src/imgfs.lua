-- imgfs: read-only filesystem over a section of the NXIMG boot image
-- (/boot/nexusos, built by tools/nximg.lua). The usr section is mounted at
-- /usr; the etc section is read once to seed /etc on first boot.
--
-- Mode, owner and group come from the image TOC and are exposed to the VFS
-- as a synthesized .meta per directory, so they cannot be changed on disk.
-- Data is inflated per block (data card for zlib images, or the loader's
-- Lua inflater without one) through a small
-- block cache; the TOC is the only per-file state kept in memory.

---@class imgfs
local imgfs = {}

imgfs.SECTION = { kernel = 1, usr = 2, etc = 3 }
imgfs.CACHE_BLOCKS = 2

local META = ".meta"

-- The image loader (/init.lua) leaves its Lua inflater here for machines
-- without a data card; take it out of the global table.
local softInflate = NEXUS_INFLATE
NEXUS_INFLATE = nil

local function normalize(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
    if path == "." then return "" end
    return path
end

local function readOnly()
    return nil, "filesystem is read-only"
end

---@param address string address of the filesystem holding the image
---@param imagePath string path of the image on that filesystem
---@param sectionType integer imgfs.SECTION.*
---@return table|nil proxy
---@return string|nil err
function imgfs.open(address, imagePath, sectionType)
    local disk = component.proxy(address)
    if not disk then return nil, "no filesystem " .. tostring(address) end
    local fh, openErr = disk.open(imagePath, "rb")
    if not fh then return nil, "cannot open " .. imagePath .. ": " .. tostring(openErr) end

    local function readAt(offset, length)
        disk.seek(fh, "set", offset)
        local parts, got = {}, 0
        while got < length do
            local data = disk.read(fh, length - got)
            if not data then error("imgfs: truncated image", 0) end
            parts[#parts + 1] = data
            got = got + #data
        end
        return table.concat(parts)
    end

    local ok, result = pcall(function()
        local header = readAt(0, 32)
        if header:sub(1, 6) ~= "NXIMG\0" then error("not a Nexus boot image", 0) end
        local version, compression, blockSize, sectionCount, _, _, dataOffset =
            string.unpack("<BBI4I2I2I4I4", header, 7)
        if version ~= 1 then error("unsupported image version " .. version, 0) end
        local meta = readAt(32, dataOffset - 32)
        local section
        for i = 0, sectionCount - 1 do
            local typ, _, _, rawSize, firstBlock, nblocks = string.unpack("<BBI2I4I4I4", meta, i * 24 + 1)
            if typ == sectionType then
                section = { rawSize = rawSize, firstBlock = firstBlock, blockCount = nblocks }
            end
        end
        if not section then error("image has no section " .. tostring(sectionType), 0) end
        local inflate
        if compression == 1 then
            local card = component.list("data")()
            if card then
                local data = component.proxy(card)
                inflate = function(stored)
                    local raw, err = data.inflate(stored)
                    if not raw then error("imgfs: inflate failed: " .. tostring(err), 0) end
                    return raw
                end
            elseif softInflate then
                inflate = function(stored)
                    local okInflate, raw = pcall(softInflate, stored)
                    if not okInflate then error("imgfs: inflate failed: " .. tostring(raw), 0) end
                    return raw
                end
            else
                error("compressed image needs a data card", 0)
            end
        elseif compression ~= 0 then
            error("unknown compression " .. compression, 0)
        end
        return { blockSize = blockSize, dataOffset = dataOffset, section = section,
            indexBase = sectionCount * 24, meta = meta, inflate = inflate }
    end)
    if not ok then
        disk.close(fh)
        return nil, result
    end
    local img = result
    local section, blockSize = img.section, img.blockSize

    -- Section-relative block cache (most recently used first).
    local cache = {}
    local function block(n)
        for i, entry in ipairs(cache) do
            if entry.n == n then
                if i > 1 then table.remove(cache, i); table.insert(cache, 1, entry) end
                return entry.raw
            end
        end
        local i = section.firstBlock + n
        local a = string.unpack("<I4", img.meta, img.indexBase + i * 4 + 1)
        local b = string.unpack("<I4", img.meta, img.indexBase + (i + 1) * 4 + 1)
        local stored = readAt(img.dataOffset + a, b - a)
        local raw = img.inflate and img.inflate(stored) or stored
        local want = n == section.blockCount - 1
            and section.rawSize - (section.blockCount - 1) * blockSize or blockSize
        if #raw ~= want then error("imgfs: block " .. i .. " has wrong size", 0) end
        table.insert(cache, 1, { n = n, raw = raw })
        if #cache > imgfs.CACHE_BLOCKS then cache[#cache] = nil end
        return raw
    end

    -- Bytes [offset, offset + length) of the section.
    local function readRange(offset, length)
        local parts = {}
        while length > 0 do
            local n = offset // blockSize
            local raw = block(n)
            local start = offset - n * blockSize + 1
            local piece = raw:sub(start, start + length - 1)
            if #piece == 0 then error("imgfs: read past end of section", 0) end
            parts[#parts + 1] = piece
            offset = offset + #piece
            length = length - #piece
        end
        return table.concat(parts)
    end

    -- TOC -> tree.
    -- Nexus stores modes as decimal digits (755, 4755); the image keeps
    -- real octal bits.
    local function nexusMode(bits) return tonumber(string.format("%o", bits)) end
    local nodes = { [""] = { kind = 2, mode = 755, uid = 0, gid = 0, size = 0, children = {} } }
    local okToc, tocErr = pcall(function()
        local head = readRange(0, 16)
        if head:sub(1, 4) ~= "NXFS" or head:byte(5) ~= 1 then error("bad NXFS section", 0) end
        local count, tocSize = string.unpack("<I4I4", head, 9)
        local toc = readRange(16, tocSize - 16)
        local pos = 1
        for _ = 1, count do
            local pathlen, kind, _, mode, uid, gid, _, offset, size =
                string.unpack("<I2BBI2I2I2I2I4I4", toc, pos)
            pos = pos + 20
            local path = toc:sub(pos, pos + pathlen - 1)
            pos = pos + pathlen
            local parentPath, name = path:match("^(.*)/([^/]+)$")
            if not parentPath then parentPath, name = "", path end
            local parent = nodes[parentPath]
            if not parent or parent.kind ~= 2 or name == META then
                error("bad NXFS entry " .. path, 0)
            end
            local node = { kind = kind, mode = nexusMode(mode), uid = uid, gid = gid,
                offset = offset, size = size, children = kind == 2 and {} or nil }
            nodes[path] = node
            parent.children[#parent.children + 1] = name
        end
    end)
    if not okToc then
        disk.close(fh)
        return nil, tocErr
    end

    local mtime = disk.lastModified(imagePath) or 0
    local imageSize = disk.size(imagePath) or 0

    local function metaFor(dirPath)
        local dir = nodes[dirPath]
        local lines = {}
        for _, name in ipairs(dir.children) do
            local node = nodes[dirPath == "" and name or (dirPath .. "/" .. name)]
            lines[#lines + 1] = string.format("%s:%s:%d:%d:%d:%d:1:%d:%d:\n", name,
                node.kind == 2 and "VDIR" or "VREG", fnv1a_hash(name),
                mtime // 1000, mtime // 1000, node.mode, node.uid, node.gid)
        end
        return table.concat(lines)
    end

    -- Returns the node, or the parent directory path when `path` is its .meta.
    local function lookup(path)
        path = normalize(path)
        local node = nodes[path]
        if node then return node, path end
        local dirPath, name = path:match("^(.*)/([^/]+)$")
        if not dirPath then dirPath, name = "", path end
        if name == META and nodes[dirPath] and nodes[dirPath].kind == 2 then
            return nil, path, dirPath
        end
    end

    local handles, nextHandle = {}, 1
    local proxy = { readOnlyImage = true }

    function proxy.getLabel() return "nexusos" end
    function proxy.setLabel() return "nexusos" end
    function proxy.isReadOnly() return true end
    function proxy.spaceTotal() return imageSize end
    function proxy.spaceUsed() return imageSize end

    function proxy.exists(path)
        local node, _, metaDir = lookup(path)
        return node ~= nil or metaDir ~= nil
    end

    function proxy.isDirectory(path)
        local node = lookup(path)
        return node ~= nil and node.kind == 2
    end

    function proxy.size(path)
        local node, _, metaDir = lookup(path)
        if metaDir then return #metaFor(metaDir) end
        return node and node.size or 0
    end

    function proxy.lastModified(path)
        return proxy.exists(path) and mtime or 0
    end

    function proxy.list(path)
        local node, p = lookup(path)
        if not node or node.kind ~= 2 then return nil, "no such directory" end
        local result = {}
        for i, name in ipairs(node.children) do
            local child = nodes[p == "" and name or (p .. "/" .. name)]
            result[i] = child.kind == 2 and (name .. "/") or name
        end
        return result
    end

    function proxy.open(path, mode)
        mode = mode or "r"
        if mode ~= "r" and mode ~= "rb" then return readOnly() end
        local node, _, metaDir = lookup(path)
        local handle
        if metaDir then
            handle = { data = metaFor(metaDir), pos = 0 }
        elseif node and node.kind == 1 then
            handle = { node = node, pos = 0 }
        else
            return nil, path
        end
        local id = nextHandle
        nextHandle = nextHandle + 1
        handles[id] = handle
        return id
    end

    function proxy.read(id, count)
        local h = handles[id]
        if not h then return nil, "bad file descriptor" end
        local size = h.data and #h.data or h.node.size
        if h.pos >= size then return nil end
        count = math.min(type(count) == "number" and count or math.huge, size - h.pos)
        local data
        if h.data then
            data = h.data:sub(h.pos + 1, h.pos + count)
        else
            -- at most to the end of the current block, so one read never
            -- materializes more than a block of a large file
            local absolute = h.node.offset + h.pos
            local untilBlockEnd = blockSize - absolute % blockSize
            data = readRange(absolute, math.min(count, untilBlockEnd))
        end
        h.pos = h.pos + #data
        return data
    end

    function proxy.seek(id, whence, offset)
        local h = handles[id]
        if not h then return nil, "bad file descriptor" end
        local size = h.data and #h.data or h.node.size
        local base = (whence == "set" and 0) or (whence == "end" and size) or h.pos
        h.pos = math.max(0, math.min(size, base + (offset or 0)))
        return h.pos
    end

    function proxy.close(id)
        handles[id] = nil
    end

    proxy.write = readOnly
    proxy.makeDirectory = readOnly
    proxy.remove = readOnly
    proxy.rename = readOnly

    -- Iterates the tree depth-first: fn(path, node) with paths relative to
    -- the section root; files carry a read() returning their content.
    function proxy.walk(fn)
        local function visit(dirPath)
            for _, name in ipairs(nodes[dirPath].children) do
                local path = dirPath == "" and name or (dirPath .. "/" .. name)
                local node = nodes[path]
                fn(path, { kind = node.kind == 2 and "dir" or "file", mode = node.mode,
                    uid = node.uid, gid = node.gid, size = node.size,
                    read = node.kind == 1 and function() return readRange(node.offset, node.size) end or nil })
                if node.kind == 2 then visit(path) end
            end
        end
        visit("")
    end

    function proxy.unmount()
        disk.close(fh)
        cache = {}
    end

    return proxy
end

-- Seeds /etc from the image's etc section. The stamp is written last, so an
-- interrupted first boot completes on the next one; existing files are
-- never overwritten.
---@param address string
---@param imagePath string
function imgfs.seedEtc(address, imagePath)
    local stamp = "/etc/.nexusos-seeded"
    if vfs.exists(stamp) then return true end
    local etc, err = imgfs.open(address, imagePath, imgfs.SECTION.etc)
    if not etc then return nil, err end
    if not vfs.isDirectory("/etc") then
        local made, e = vfs.makeDirectory("/etc")
        if not made then
            etc.unmount()
            return nil, "/etc: " .. tostring(e)
        end
    end
    local okWalk, walkErr = pcall(etc.walk, function(path, entry)
        local target = "/etc/" .. path
        if entry.kind == "dir" then
            if not vfs.exists(target) then
                local made, e = vfs.makeDirectory(target)
                if not made and not vfs.isDirectory(target) then error(target .. ": " .. tostring(e), 0) end
            end
        elseif not vfs.exists(target) then
            local f, e = vfs.open(target, "w")
            if not f then error(target .. ": " .. tostring(e), 0) end
            f:write(entry.read())
            f:close()
        else
            return
        end
        vfs.chown(target, entry.uid, entry.gid)
        vfs.chmod(target, entry.mode)
    end)
    etc.unmount()
    if not okWalk then return nil, walkErr end
    local f, e = vfs.open(stamp, "w")
    if not f then return nil, e end
    f:write("1\n")
    f:close()
    return true
end
