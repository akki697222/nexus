-- installer/src/source.lua - where the release files come from
--
-- A release is a directory with manifest.lua (tools/nximg.lua dist) and
-- the files it lists. Offline it is a directory on a disk (the bundle in
-- /.nexus-install); online it is a URL, by default the release that
-- dist/channel.lua names, and the files are downloaded first.

source = {}

source.ROLES = { "kernel", "rootfs", "boot", "config" }

-- Returns the manifest, or nil and why.
function source.parseManifest(text)
    local m, err = util.loadData(text, "manifest.lua")
    if not m then return nil, err end
    if type(m) ~= "table" or math.type(m.format) ~= "integer" or math.type(m.installer) ~= "integer"
        or type(m.files) ~= "table" then
        return nil, "manifest.lua is not a Nexus manifest"
    end
    return m
end

-- Whether this installer can install from the manifest; it may still be
-- able to update itself from it (stage1).
function source.check(m)
    if m.format ~= 1 then
        return nil, "this release needs a newer installer (manifest format " .. m.format .. ")"
    end
    local roles = {}
    for _, f in ipairs(m.files) do
        if type(f) ~= "table" or type(f.name) ~= "string" or not f.name:match("^[%w._-]+$")
            or math.type(f.size) ~= "integer" or math.type(f.crc32) ~= "integer" then
            return nil, "manifest.lua has a bad file entry"
        end
        roles[f.role] = f
    end
    for _, role in ipairs(source.ROLES) do
        if not roles[role] then return nil, "manifest.lua has no " .. role .. " file" end
    end
    if type(m.groups) ~= "table" then m.groups = {} end
    m.byRole = roles
    return true
end

-- The release URL of a channel, from dist/channel.lua on GitHub.
function source.channelBase(channel)
    local text, err = net.fetch(CHANNEL_URL)
    if not text then return nil, err end
    local c, cerr = util.loadData(text, "channel.lua")
    if not c then return nil, cerr end
    if type(c) ~= "table" or c.format ~= 1 or type(c.base) ~= "string" or type(c.channels) ~= "table" then
        return nil, "channel.lua: unknown format"
    end
    local tag = c.channels[channel]
    if type(tag) ~= "string" then return nil, "channel.lua has no channel " .. channel end
    return c.base:format(tag)
end

function source.offline(fs, dir)
    local text, err = disk.readAll(fs, dir .. "/manifest.lua")
    if not text then return nil, err end
    local m, merr = source.parseManifest(text)
    if not m then return nil, merr end
    return { kind = "offline", fs = fs, dir = dir, manifest = m }
end

function source.online(base)
    base = base:gsub("/+$", "")
    local text, err = net.fetch(base .. "/manifest.lua")
    if not text then return nil, err end
    local m, merr = source.parseManifest(text)
    if not m then return nil, merr end
    return { kind = "online", base = base, manifest = m }
end

-- Reads one file of the release through fn(chunk) and checks its size and
-- CRC-32. Online, the file is also written to dlFs:dlPath.
local function read(src, f, fn, dlFs, dlPath)
    local crc, size = 0, 0
    local function take(chunk)
        crc = crc32(chunk, crc)
        size = size + #chunk
        fn(chunk)
        util.yield()
    end
    if src.kind == "online" then
        local write, close = disk.writer(dlFs, dlPath)
        local n, err = net.get(src.base .. "/" .. f.name, function(chunk)
            write(chunk)
            take(chunk)
        end)
        close()
        if not n then error(err, 0) end
    else
        local path = src.dir .. "/" .. f.name
        if not src.fs.exists(path) then error(path .. " is missing", 0) end
        disk.eachChunk(src.fs, path, take)
    end
    if size ~= f.size then error(string.format("%s: %d bytes, expected %d", f.name, size, f.size), 0) end
    if crc ~= f.crc32 then error(f.name .. ": checksum mismatch", 0) end
end

-- Makes the files on disk and checks them. Returns role -> { fs, path }.
-- progress(fraction, text) is called as data comes in.
function source.prepare(src, dlFs, dlDir, progress)
    local m = src.manifest
    local total, done = 0, 0
    for _, f in ipairs(m.files) do
        if f.role ~= "installer" then total = total + f.size end
    end
    if src.kind == "online" then disk.mkdir(dlFs, dlDir) end
    local files = {}
    for _, f in ipairs(m.files) do
        if f.role ~= "installer" then
            local verb = src.kind == "online" and "Downloading " or "Checking "
            local got = 0
            read(src, f, function(chunk)
                got = got + #chunk
                progress((done + got) / math.max(total, 1), verb .. f.name)
            end, dlFs, dlDir .. "/" .. f.name)
            done = done + f.size
            if src.kind == "online" then
                files[f.role] = { fs = dlFs, path = dlDir .. "/" .. f.name }
            else
                files[f.role] = { fs = src.fs, path = src.dir .. "/" .. f.name }
            end
        end
    end
    return files
end

-- The installer of the release, checked, or nil and why.
function source.installer(src)
    local f = src.manifest.byRole and src.manifest.byRole.installer
    if not f then
        for _, e in ipairs(src.manifest.files) do
            if e.role == "installer" then f = e end
        end
    end
    if not f then return nil, "the release has no installer" end
    local parts, crc, size = {}, 0, 0
    local function take(chunk)
        parts[#parts + 1] = chunk
        crc = crc32(chunk, crc)
        size = size + #chunk
        util.yield()
    end
    if src.kind == "online" then
        local n, err = net.get(src.base .. "/" .. f.name, take)
        if not n then return nil, err end
    else
        local path = src.dir .. "/" .. f.name
        if not src.fs.exists(path) then return nil, path .. " is missing" end
        disk.eachChunk(src.fs, path, take)
    end
    if size ~= f.size or crc ~= f.crc32 then return nil, f.name .. ": checksum mismatch" end
    return table.concat(parts)
end
