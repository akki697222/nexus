-- VFS file mutation regressions. Run from nexus/: lua tests/vfs_fileops.lua
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
local fsA, fsB = fakeFs("disk-a"), fakeFs("disk-b")
fsA.totalCapacity, fsA.usedCapacity = 8192, 2048
fsB.totalCapacity, fsB.usedCapacity = math.huge, 1024
assert(vfs.mount(fsA, "/"))

local rootStats = assert(vfs.statfs("/"))
assert(rootStats.address == "disk-a" and rootStats.label == "disk-a")
assert(rootStats.total == 8192 and rootStats.used == 2048 and rootStats.mountPath == "/")
assert(rootStats.readOnly == false and rootStats.fs == nil, "statfs must return detached plain metadata")

local function write(path, value)
    local file = assert(vfs.open(path, "w"))
    assert(file:write(value) == #value)
    file:close()
end

assert(vfs.makeDirectory("/left"))
assert(vfs.makeDirectory("/right"))
assert(not vfs.remove("/"))
assert(not vfs.rename("/", "/right/root"))
write("/left/file", "keep me")
local fileNode = assert(vfsk.lookup("/left/file"))
fileNode.uid, fileNode.gid, fileNode.mode = 42, 17, 0640
assert(vfs.rename("/left/file", "/right/renamed"))
assert(vfsk.lookup("/right/renamed") == fileNode)
assert(fileNode.uid == 42 and fileNode.gid == 17 and fileNode.mode == 0640)
assert(fsA.content("/right/renamed") == "keep me" and not fsA.exists("/left/file"))

write("/right/existing", "preserve")
local before = vfs._dirty
assert(not vfs.rename("/right/renamed", "/right/existing"))
assert(fsA.content("/right/existing") == "preserve" and vfsk.lookup("/right/renamed") == fileNode)
fsA.failRename = true
vfs._dirty = false
local ok, err = vfs.rename("/right/renamed", "/left/fail")
assert(not ok and err == "injected rename failure")
assert(vfsk.lookup("/right/renamed") == fileNode and not vfsk.lookup("/left/fail"))
assert(not vfs._dirty, "failed backing rename must not dirty metadata")
fsA.failRename = false
write("/right/remove-fail", "keep")
local removalNode = assert(vfsk.lookup("/right/remove-fail"))
fsA.failRemove = true
assert(not vfs.remove("/right/remove-fail"))
assert(vfsk.lookup("/right/remove-fail") == removalNode and fsA.exists("/right/remove-fail"))
fsA.failRemove = false

assert(vfs.makeDirectory("/tree"))
assert(vfs.makeDirectory("/tree/child"))
write("/tree/child/data", "nested")
local tree = assert(vfsk.lookup("/tree"))
assert(not vfs.rename("/tree", "/tree/child/inside"))
assert(vfs.rename("/tree", "/right/tree"))
assert(vfsk.lookup("/right/tree") == tree)
assert(fsA.content("/right/tree/child/data") == "nested")
assert(not vfs.remove("/right/tree"), "nonempty directory removal must fail")

-- Cross-device moves and mounted directory roots are rejected before I/O.
assert(vfs.mount(fsB, "/mnt"))
local nestedStats = assert(vfs.statfs("/mnt"))
assert(nestedStats.address == "disk-b" and nestedStats.mountPath == "/mnt")
assert(nestedStats.total == math.huge and nestedStats.used == 1024)
write("/mnt/other", "other")
assert(not vfs.rename("/right/renamed", "/mnt/moved"))
local mountRoot = assert(vfsk.lookup("/mnt"))
assert(not vfs.remove("/mnt") and not vfs.rename("/mnt", "/right/mnt"))
assert(vfsk.lookup("/mnt") == mountRoot)
assert(vfs.makeDirectory("/holder"))
local fsC = fakeFs("disk-c")
assert(vfs.mount(fsC, "/holder/nested-mount"))
assert(not vfs.rename("/holder", "/right/holder"), "directory containing a mount must not move")

-- Parent write/search and sticky ownership rules apply before mutation.
local right = assert(vfsk.lookup("/right"))
right.mode, right.uid = 01777, 100
local moved = assert(vfsk.lookup("/right/renamed"))
moved.uid = 200
current.uid, current.euid = 300, 300
assert(not vfs.remove("/right/renamed"))
assert(not vfs.rename("/right/renamed", "/right/nope"))
assert(not vfs.rename("/right/renamed", "/right/renamed"), "same-entry rename still checks permissions")
current.uid, current.euid = 0, 0
right.mode = 0755

-- Touch does not truncate, updates mtime, and honors owner/write permission.
local existing = assert(vfs.open("/right/renamed", "r"))
local contents = existing:readAll()
existing:close()
local oldMtime = moved.mtime
local touchNow = oldMtime + 100
getRealTime = function() touchNow = touchNow + 1; return touchNow end
assert(vfs.touch("/right/renamed"))
assert(moved.mtime == oldMtime + 101)
local reread = assert(vfs.open("/right/renamed", "r"))
assert(reread:readAll() == contents)
reread:close()
assert(vfs.touch("/right/new-file"))
assert(fsA.exists("/right/new-file"))
assert(not vfs.touch("/right/.meta"))
assert(not vfs.makeDirectory("/right/.meta"))
fsA.readOnly = true
assert(not vfs.touch("/right/renamed"))
fsA.readOnly = false

-- Final symlinks are renamed/removed as directory entries; targets remain.
assert(vfs.link("/right/renamed", "/right/alias"))
local aliasStats = assert(vfs.statfs("/right/alias"))
assert(aliasStats.address == "disk-a" and aliasStats.mountPath == "/")
local linkNode = assert(vfsk.lookup("/right/alias"))
assert(linkNode.type == "VLNK")
assert(vfs.rename("/right/alias", "/right/alias2"))
assert(vfsk.lookup("/right/alias2") == linkNode)
assert(vfs.remove("/right/alias2"))
assert(not vfsk.lookup("/right/alias2") and fsA.exists("/right/renamed"))

-- Exercise final-parent symlinks and lazy loading through a directory alias.
assert(vfs.link("/right", "/right-link"))
assert(vfs.rename("/right-link/renamed", "/right-link/through-alias"))
assert(fsA.exists("/right/through-alias"))
assert(vfs.link("/right/through-alias", "/right/touch-alias"))
local throughAlias = assert(vfsk.lookup("/right/through-alias"))
local aliasMtime = throughAlias.mtime
assert(vfs.touch("/right/touch-alias"))
assert(throughAlias.mtime ~= aliasMtime, "touch through a symlink must update its target")

-- Mounting an empty directory temporarily covers its vnode and permissions.
assert(vfs.makeDirectory("/attach"))
local covered = assert(vfsk.lookup("/attach"))
covered.mode = 0711
local attachedFs = fakeFs("attach-volume")
local removableFs = fakeFs("attach-child")
function attachedFs.getLabel() return "data disk" end
local volumeByAddress = { [attachedFs.address] = attachedFs, [removableFs.address] = removableFs }
component = {
    list = function(kind)
        assert(kind == "filesystem")
        return next, volumeByAddress, nil
    end,
    proxy = function(address) return assert(volumeByAddress[address]) end,
    type = function(address) return volumeByAddress[address] and "filesystem" or "gpu" end,
    invoke = function(address, method) return volumeByAddress[address][method]() end,
}
assert(not vfs.mount(attachedFs, "/missing-parent/nested"))
assert(not vfs.mount(attachedFs, "/right/existing"))
assert(not vfs.mount(attachedFs, "/right"))
assert(not vfs.mount("attach-", "/ambiguous"))
assert(vfs.mount("data disk", "/attach"))
assert(vfs.statfs("/attach").mountPath == "/attach")
assert(not vfs.mount(attachedFs, "/duplicate-mount"))
write("/attach/file", "mounted data")
assert(attachedFs.content("/file") == "mounted data")

assert(vfs.mount("attach-chi", "/attach/nested"))
assert(not vfs.umount("/attach"), "a mount with a nested mount must stay attached")
assert(not vfs.umount("attach-"), "ambiguous source prefixes must not detach either mount")
assert(vfs.umount("attach-chi"))
assert(not vfs.exists("/attach/nested"), "unmounting a synthetic mount must remove the mountpoint")

local openFile = assert(vfs.open("/attach/file", "r"))
assert(not vfs.umount("/attach"), "an open file descriptor keeps its mount busy")
openFile:close()
local savedCurrent = current
current = nil
local kernelFile = assert(vfs.open("/attach/file", "r"))
assert(not vfs.umount("/attach"), "an open kernel handle keeps its mount busy")
kernelFile:close()
current = savedCurrent
current.cwd = assert(vfsk.lookup("/attach"))
assert(not vfs.umount("/attach"), "a process working directory keeps its mount busy")
current.cwd = nil
assert(vfs.touch("/attach/file"))
local flush = coroutine.create(function() assert(vfs.saveMetadata(coroutine.yield)) end)
assert(coroutine.resume(flush))
assert(coroutine.status(flush) == "suspended")
assert(not vfs.umount("/attach"), "unmount must wait for an in-progress metadata flush")
while coroutine.status(flush) ~= "dead" do assert(coroutine.resume(flush)) end

write("/attach/fresh", "sync on unmount")
attachedFs.failMetaOpen = true
assert(not vfs.umount("/attach"), "metadata errors must leave the filesystem mounted")
assert(vfs.exists("/attach/fresh") and vfs.statfs("/attach").address == "attach-volume")
attachedFs.failMetaOpen = false
assert(vfs.umount("./attach"))
assert(vfsk.lookup("/attach") == covered and covered.mode == 0711)
assert(not vfs.exists("/attach/file") and attachedFs.content("/file") == "mounted data")
assert(attachedFs.content("/.meta"):find("fresh", 1, true), "unmount must flush the mounted filesystem's metadata")
assert(not vfs.umount("/") and not vfs.umount("disk-a"), "the root filesystem must stay mounted")
local rootMetadata = "\n" .. assert(fsA.content("/.meta"))
assert(rootMetadata:find("\nattach:VDIR:[^:]+:[^:]+:[^:]+:711:"), "covered directory permissions must be persisted")
assert(not rootMetadata:find("\nmnt:", 1, true), "synthetic mountpoints must not be persisted as directories")

print("vfs file operation tests passed")

for name, value in pairs(saved) do _G[name] = value end
