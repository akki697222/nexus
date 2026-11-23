-- File timestamps: whole Unix seconds, real time.
-- Run from nexus/: lua tests/vfs_times.lua
-- (VFS harness shared with tests/vfs_fileops.lua)
local f = assert(io.open("src/vfs.lua", "r"))
local source = f:read("*a")
f:close()
source = assert(source:gsub("local vfsk = {}", "vfsk = {}", 1))

local saved = {}
for _, name in ipairs({ "vfs", "vfsk", "process", "config", "fnv1a_hash", "devfs",
    "permission", "unicode", "getRealTime", "component" }) do
    saved[name] = _G[name]
end

local function hash(value)
    local result = 2166136261
    for i = 1, #value do result = (result * 16777619 + value:byte(i)) % 2147483647 end
    return result
end

local current = { uid = 0, euid = 0, gid = 0, egid = 0, fd = {} }
process = {
    getCurrent = function() return current end,
    getCurrentPID = function() return 1 end,
    list = function() return { { pid = 1 } } end,
    get = function(pid) if pid == 1 then return current end end,
    cwd = function() return vfs.realPath(current.cwd) or "/" end,
}
config = { filesystem_read_bytes = 128 }
fnv1a_hash = hash
unicode = { sub = string.sub }
getRealTime = os.time
local pf = assert(io.open("src/permission.lua", "r"))
local permissionSource = pf:read("*a")
pf:close()
permissionSource = assert(permissionSource:gsub("local permission = {}", "permission = {}", 1))
assert(load(permissionSource, "src/permission.lua"))()
devfs = { close = function() end }

local function fakeFs(address)
    local entries = { ["/"] = { directory = true, children = {} } }
    local handles, nextHandle = {}, 1
    local fs = { address = address, readOnly = false }
    local function parent(path)
        path = path:gsub("/$", "")
        local dir, name = path:match("^(.*)/([^/]+)$")
        if dir == "" then dir = "/" end
        return dir, name
    end
    local function add(path, entry)
        local dir, name = parent(path)
        entries[path] = entry
        entries[dir].children[name] = true
    end
    function fs.exists(path) return entries[path] ~= nil end
    function fs.isDirectory(path) return entries[path] and entries[path].directory or false end
    function fs.list(path)
        local entry = entries[path]
        if not entry or not entry.directory then return nil end
        local names = {}
        for name in pairs(entry.children) do names[#names + 1] = name end
        table.sort(names)
        return names
    end
    function fs.makeDirectory(path)
        if entries[path] then return false, "File exists" end
        local dir = parent(path)
        if not entries[dir] or not entries[dir].directory then return false, "No such directory" end
        add(path, { directory = true, children = {} })
        return true
    end
    function fs.remove(path)
        if fs.failRemove then return false, "injected remove failure" end
        local entry = entries[path]
        if not entry then return false, "No such file" end
        if entry.directory and next(entry.children) then return false, "Directory not empty" end
        local dir, name = parent(path)
        entries[dir].children[name] = nil
        entries[path] = nil
        return true
    end
    function fs.rename(old, new)
        if fs.failRename then return false, "injected rename failure" end
        if not entries[old] then return false, "No such source" end
        if entries[new] then return false, "File exists" end
        local newDir = parent(new)
        if not entries[newDir] or not entries[newDir].directory then return false, "No such destination" end
        local oldDir, oldName = parent(old)
        local _, newName = parent(new)
        entries[oldDir].children[oldName] = nil
        entries[newDir].children[newName] = true
        local moving = entries[old]
        entries[old] = nil
        entries[new] = moving
        if moving.directory then
            local prefix, suffixes = old .. "/", {}
            for path, entry in pairs(entries) do
                if path:sub(1, #prefix) == prefix then
                    suffixes[#suffixes + 1] = { path:sub(#prefix + 1), entry }
                end
            end
            for _, item in ipairs(suffixes) do entries[old .. "/" .. item[1]] = nil end
            for _, item in ipairs(suffixes) do entries[new .. "/" .. item[1]] = item[2] end
        end
        return true
    end
    function fs.open(path, mode)
        if fs.failMetaOpen and path:match("/%.meta$") and mode:find("w") then
            return nil, "injected metadata write failure"
        end
        if mode:find("w") then
            if not entries[path] then
                local dir = parent(path)
                if not entries[dir] then return nil, "No such directory" end
                add(path, { directory = false, data = "" })
            elseif entries[path].directory then return nil, "Is a directory" end
            entries[path].data = ""
        elseif not entries[path] then return nil, "No such file" end
        local id = nextHandle
        nextHandle = nextHandle + 1
        handles[id] = { path = path, position = 1 }
        return id
    end
    function fs.read(handle, amount)
        local opened = handles[handle]
        if not opened then return nil, "Bad handle" end
        local data = entries[opened.path].data or ""
        if opened.position > #data then return nil end
        local chunk = data:sub(opened.position, opened.position + amount - 1)
        opened.position = opened.position + #chunk
        return chunk
    end
    function fs.write(handle, data)
        local opened = handles[handle]
        if not opened then return nil, "Bad handle" end
        local entry = entries[opened.path]
        local before = entry.data or ""
        entry.data = before:sub(1, opened.position - 1) .. data .. before:sub(opened.position + #data)
        opened.position = opened.position + #data
        return #data
    end
    function fs.seek(handle, whence, offset)
        local opened = handles[handle]
        if not opened then return nil, "Bad handle" end
        local base = whence == "set" and 1 or whence == "end" and #(entries[opened.path].data or "") + 1 or opened.position
        opened.position = base + (offset or 0)
        return opened.position - 1
    end
    function fs.close(handle) handles[handle] = nil; return true end
    function fs.size(path) return #(entries[path] and entries[path].data or "") end
    function fs.lastModified() return 0 end
    function fs.isReadOnly() return fs.readOnly end
    function fs.getLabel() return address end
    function fs.spaceTotal() return fs.totalCapacity end
    function fs.spaceUsed() return fs.usedCapacity end
    function fs.content(path) return entries[path] and entries[path].data end
    return fs
end

assert(load(source, "src/vfs.lua"))()
local now = 1800000000
getRealTime = function() return now end

local fsA = fakeFs("disk-a")
-- files that exist on disk before Nexus sees them (no .meta entry)
assert(fsA.makeDirectory("/pre"))
local h = assert(fsA.open("/pre/old.txt", "w"))
fsA.write(h, "old")
fsA.close(h)
local lastModifiedCalls = 0
fsA.lastModified = function(path)
    lastModifiedCalls = lastModifiedCalls + 1
    if path == "/pre/old.txt" then return 1700000000123 end -- milliseconds, as OC returns
    return 0
end
assert(vfs.mount(fsA, "/"))

-- 1. Listing does not query times; attributes take the disk time in seconds.
for _ in vfs.list("/pre") do end
assert(lastModifiedCalls == 0, "listing must not fetch modification times")
local old = assert(vfs.attributes("/pre/old.txt"))
assert(old.mtime == 1700000000, "expected disk mtime in seconds, got " .. tostring(old.mtime))

-- 2. New files and directories get the real time.
local f = assert(vfs.open("/new.txt", "w"))
f:write("x")
f:close()
assert(vfs.attributes("/new.txt").mtime == now)
assert(vfs.makeDirectory("/dir"))
assert(vfs.attributes("/dir").mtime == now)

-- 3. Writing updates mtime; btime stays.
now = now + 60
f = assert(vfs.open("/pre/old.txt", "a"))
f:write("more")
f:close()
local updated = vfs.attributes("/pre/old.txt")
assert(updated.mtime == now and updated.btime == 1700000000, updated.mtime .. " " .. updated.btime)

-- 4. touch uses the real time too.
now = now + 60
assert(vfs.touch("/new.txt"))
assert(vfs.attributes("/new.txt").mtime == now)

-- 5. .meta persists whole seconds, including disk-derived times.
assert(vfs.saveMetadata())
local meta = fsA.content("/pre/.meta")
assert(meta and meta:find("^old%.txt:VREG:%d+:" .. (now - 60) .. ":1700000000:"), meta)

for name, value in pairs(saved) do _G[name] = value end
io.write("vfs time tests passed\n")
