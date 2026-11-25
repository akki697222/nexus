-- installer/src/disk.lua - filesystem components
--
-- Functions take a component proxy (fs) and absolute paths. Failures that
-- leave the install unfinished are raised (stage1 shows them and offers a
-- retry); the message names the path.

disk = {}

-- Writable filesystems, without the tmpfs: { address, label, total, used,
-- readOnly, boot }.
function disk.list()
    local out = {}
    local tmp = computer.tmpAddress and computer.tmpAddress()
    local boot = computer.getBootAddress and computer.getBootAddress()
    for address in component.list("filesystem") do
        if address ~= tmp then
            local fs = component.proxy(address)
            out[#out + 1] = {
                address = address,
                label = fs.getLabel() or "",
                total = fs.spaceTotal() or 0,
                used = fs.spaceUsed() or 0,
                readOnly = fs.isReadOnly(),
                boot = address == boot,
            }
        end
    end
    -- other disks first, the one the installer runs from last
    table.sort(out, function(a, b)
        if a.boot ~= b.boot then return b.boot end
        return a.address < b.address
    end)
    return out
end

-- "1a2b3c4d  label  120 KB free of 2 MB"
function disk.describe(info)
    return string.format("%s  %-12s %s free of %s%s", info.address:sub(1, 8), info.label:sub(1, 12),
        util.size(info.total - info.used), util.size(info.total), info.readOnly and "  read-only" or "")
end

function disk.readAll(fs, path)
    local handle, err = fs.open(path, "rb")
    if not handle then return nil, path .. ": " .. tostring(err) end
    local parts = {}
    while true do
        local data = fs.read(handle, math.huge)
        if not data then break end
        parts[#parts + 1] = data
    end
    fs.close(handle)
    return table.concat(parts)
end

-- Calls fn(chunk) for each piece of a file.
function disk.eachChunk(fs, path, fn)
    local handle, err = fs.open(path, "rb")
    if not handle then error(path .. ": " .. tostring(err), 0) end
    while true do
        local data = fs.read(handle, 16384)
        if not data then break end
        fn(data)
    end
    fs.close(handle)
end

-- Opens path for writing; returns write(chunk) and close().
function disk.writer(fs, path)
    local handle, err = fs.open(path, "wb")
    if not handle then error("cannot create " .. path .. ": " .. tostring(err), 0) end
    local function write(chunk)
        local ok, werr = fs.write(handle, chunk)
        if not ok then
            fs.close(handle)
            error("cannot write " .. path .. ": " .. tostring(werr), 0)
        end
    end
    local function close() fs.close(handle) end
    return write, close
end

function disk.writeAll(fs, path, data)
    local write, close = disk.writer(fs, path)
    if #data > 0 then write(data) end
    close()
end

-- Writes path through path.new, so an interrupted write leaves the old file.
function disk.replace(fs, path, data)
    disk.writeAll(fs, path .. ".new", data)
    if fs.exists(path) and not fs.remove(path) then error("cannot remove " .. path, 0) end
    if not fs.rename(path .. ".new", path) then error("cannot rename " .. path .. ".new", 0) end
end

function disk.copy(fromFs, fromPath, toFs, toPath)
    local write, close = disk.writer(toFs, toPath)
    disk.eachChunk(fromFs, fromPath, write)
    close()
end

function disk.mkdir(fs, path)
    if fs.isDirectory(path) then return end
    if not fs.makeDirectory(path) then error("cannot create " .. path, 0) end
end

-- Removes everything below dir (a directory path ending in "/") except the
-- paths in keep, deepest first.
function disk.wipe(fs, dir, keep)
    local removed = 0
    local function walk(d)
        for _, name in ipairs(fs.list(d) or {}) do
            local isDir = name:sub(-1) == "/"
            local full = d .. (isDir and name:sub(1, -2) or name)
            if not keep[full] then
                if isDir then walk(full .. "/") end
                if not fs.remove(full) then error("cannot remove " .. full, 0) end
                removed = removed + 1
                if removed % 64 == 0 then util.yield() end
            end
        end
    end
    walk(dir)
end

function disk.removeTree(fs, path)
    if not fs.exists(path) then return end
    if fs.isDirectory(path) then disk.wipe(fs, path .. "/", {}) end
    fs.remove(path)
end

-- Total size of the files below path.
function disk.treeSize(fs, path)
    if not fs.exists(path) then return 0 end
    if not fs.isDirectory(path) then return fs.size(path) or 0 end
    local total = 0
    for _, name in ipairs(fs.list(path) or {}) do
        total = total + disk.treeSize(fs, path .. "/" .. name:gsub("/$", ""))
    end
    return total
end
