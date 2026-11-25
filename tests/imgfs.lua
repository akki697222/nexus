-- imgfs: the NXIMG usr/etc sections through the real VFS.
-- Run from nexus/: lua tests/imgfs.lua
-- (VFS harness shared with tests/vfs_fileops.lua)
local hostLoadfile = loadfile
local source = dofile("tests/lib/kernel.lua").source("vfs")

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
local pf = assert(io.open("src/sec/permission.lua", "r"))
local permissionSource = pf:read("*a")
pf:close()
assert(load(permissionSource, "src/sec/permission.lua"))()
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

assert(load(source, "=vfs"))()
local fsA = fakeFs("disk-a")
assert(vfs.mount(fsA, "/"))

local nximg = assert(hostLoadfile("tools/nximg.lua"))()
local LD = assert(hostLoadfile("tools/lib/libdeflate.lua"))()
local function octal(s) return tonumber(s, 8) end

local lines = {}
for i = 1, 3000 do lines[i] = string.format("line %05d\n", i) end
local big = table.concat(lines)

local usrRaw = nximg.encodeFs({
    { path = "bin", kind = nximg.FS_DIR, mode = octal("755") },
    { path = "bin/sh.lua", kind = nximg.FS_FILE, mode = octal("755"), data = "return 'sh'" },
    { path = "bin/sudo.lua", kind = nximg.FS_FILE, mode = octal("4755"), data = "return 'sudo'" },
    { path = "lib", kind = nximg.FS_DIR, mode = octal("755") },
    { path = "lib/big.txt", kind = nximg.FS_FILE, mode = octal("644"), data = big },
    { path = "lib/private", kind = nximg.FS_DIR, mode = octal("700"), uid = 5, gid = 6 },
})
local etcRaw = nximg.encodeFs({
    { path = "init.d", kind = nximg.FS_DIR, mode = octal("755") },
    { path = "init.d/uname", kind = nximg.FS_FILE, mode = octal("644"), data = "uname" },
    { path = "sudoers", kind = nximg.FS_FILE, mode = octal("440"), data = "root ALL" },
})
local BLOCK = 4096
local image = nximg.encode({
    { type = nximg.SECTION.kernel, data = "return" },
    { type = nximg.SECTION.usr, data = usrRaw },
    { type = nximg.SECTION.etc, data = etcRaw },
}, { compression = nximg.COMP_ZLIB, blockSize = BLOCK,
     deflate = function(raw) return LD:CompressZlib(raw) end })

-- The image lives on the root disk; imgfs reads it through the raw component.
assert(fsA.makeDirectory("/boot"))
local h = assert(fsA.open("/boot/nexusos", "w"))
fsA.write(h, image)
fsA.close(h)

local inflateCalls, haveDataCard = 0, true
component = {
    proxy = function(address)
        if address == "disk-a" then return fsA end
        if address == "data" then
            return { inflate = function(z) inflateCalls = inflateCalls + 1; return LD:DecompressZlib(z) end }
        end
    end,
    list = function(kind)
        local done = not (kind == "data" and haveDataCard)
        return function()
            if done then return nil end
            done = true
            return "data"
        end
    end,
}

local f = assert(io.open("src/fs/imgfs.lua", "r"))
local imgfsSource = f:read("*a")
f:close()
assert(load(imgfsSource, "src/fs/imgfs.lua"))()

-- 1. Proxy behaviour.
local usr = assert(imgfs.open("disk-a", "/boot/nexusos", imgfs.SECTION.usr))
local root = usr.list("/")
assert(#root == 2 and root[1] == "bin/" and root[2] == "lib/")
assert(usr.isDirectory("/bin") and not usr.isDirectory("/bin/sh.lua"))
assert(usr.exists("/bin/.meta") and not usr.exists("/nope"))
assert(usr.size("/lib/big.txt") == #big)
local mh = assert(usr.open("/bin/.meta", "r"))
local meta = usr.read(mh, math.huge)
usr.close(mh)
assert(meta:find("sudo.lua:VREG:%d+:%d+:%d+:4755:1:0:0:\n"), meta)
assert(not usr.open("/bin/sh.lua", "w") and not usr.makeDirectory("/x") and not usr.remove("/bin/sh.lua"))

inflateCalls = 0
local fh = assert(usr.open("/lib/big.txt", "rb"))
local parts = {}
while true do
    local chunk = usr.read(fh, math.huge)
    if not chunk then break end
    assert(#chunk <= BLOCK, "a read must not exceed one block")
    parts[#parts + 1] = chunk
end
assert(table.concat(parts) == big)
assert(usr.seek(fh, "set", 10) == 10 and usr.read(fh, 10) == big:sub(11, 20))
usr.close(fh)
assert(inflateCalls <= math.ceil(#usrRaw / BLOCK) + 1, "sequential read re-inflated blocks: " .. inflateCalls)

-- 2. Mounted at /usr through the VFS.
assert(vfs.mount(usr, "/usr"))
local names = {}
for name in vfs.list("/usr/bin") do names[#names + 1] = name end
table.sort(names)
assert(#names == 2 and names[1] == "sh.lua" and names[2] == "sudo.lua", table.concat(names, ","))
assert(vfsk.lookup("/usr/bin/sudo.lua").mode == 4755, "setuid bit must come from the image")
assert(vfsk.lookup("/usr/bin/sh.lua").mode == 755)
local private = vfsk.lookup("/usr/lib/private")
assert(private.mode == 700 and private.uid == 5 and private.gid == 6)
local file = assert(vfs.open("/usr/lib/big.txt", "r"))
assert(file:read("*a") == big)
file:close()
assert(not vfs.open("/usr/bin/new.lua", "w"))
local ok, err = vfs.chmod("/usr/bin/sudo.lua", 777)
assert(not ok and err == "Read-only file system")
ok, err = vfs.chown("/usr/bin/sudo.lua", 1, 1)
assert(not ok and err == "Read-only file system")
assert(vfsk.lookup("/usr/bin/sudo.lua").mode == 4755)
assert(not vfs.makeDirectory("/usr/new"))
assert(not vfs.remove("/usr/bin/sh.lua"))
local stats = assert(vfs.statfs("/usr/bin"))
assert(stats.readOnly == true and stats.label == "nexusos" and stats.mountPath == "/usr")
assert(vfs.saveMetadata())
assert(not fsA.exists("/usr/.meta") and not fsA.exists("/usr"), "nothing may be written under /usr on disk")

-- 3. /etc is seeded once; local edits survive, missing files come back
--    only until the stamp is written.
assert(not vfs.exists("/etc"))
assert(imgfs.seedEtc("disk-a", "/boot/nexusos"))
assert(fsA.content("/etc/sudoers") == "root ALL")
assert(fsA.content("/etc/init.d/uname") == "uname")
assert(vfsk.lookup("/etc/sudoers").mode == 440)
assert(vfs.exists("/etc/.nexusos-seeded"))
local edit = assert(vfs.open("/etc/sudoers", "w"))
edit:write("edited")
edit:close()
assert(vfs.remove("/etc/init.d/uname"))
assert(imgfs.seedEtc("disk-a", "/boot/nexusos"))
assert(not vfs.exists("/etc/init.d/uname"), "seeded systems are left alone")
assert(vfs.remove("/etc/.nexusos-seeded"))
assert(imgfs.seedEtc("disk-a", "/boot/nexusos"))
assert(fsA.content("/etc/init.d/uname") == "uname", "an interrupted seed completes")
assert(fsA.content("/etc/sudoers") == "edited", "existing files are never overwritten")

-- 4. Errors.
haveDataCard = false
local none, noneErr = imgfs.open("disk-a", "/boot/nexusos", imgfs.SECTION.usr)
assert(not none and noneErr:find("data card", 1, true))
-- with the loader's Lua inflater, no data card is needed
local softCalls = 0
NEXUS_INFLATE = function(z) softCalls = softCalls + 1; return LD:DecompressZlib(z) end
assert(load(imgfsSource, "src/fs/imgfs.lua"))()
assert(NEXUS_INFLATE == nil, "imgfs takes the inflater out of the global table")
local softUsr = assert(imgfs.open("disk-a", "/boot/nexusos", imgfs.SECTION.usr))
local sh = assert(softUsr.open("/lib/big.txt", "rb"))
local got = {}
while true do
    local chunk = softUsr.read(sh, math.huge)
    if not chunk then break end
    got[#got + 1] = chunk
end
softUsr.close(sh)
assert(table.concat(got) == big and softCalls > 0)
NEXUS_INFLATE = function() error("bad data") end
assert(load(imgfsSource, "src/fs/imgfs.lua"))()
local badUsr, badErr = imgfs.open("disk-a", "/boot/nexusos", imgfs.SECTION.usr)
assert(not badUsr and tostring(badErr):find("imgfs: inflate failed", 1, true), tostring(badErr))

haveDataCard = true
none, noneErr = imgfs.open("disk-a", "/boot/missing", imgfs.SECTION.usr)
assert(not none and noneErr:find("cannot open", 1, true))
local badHandle = assert(fsA.open("/boot/bad", "w"))
fsA.write(badHandle, "garbage that is long enough to be read as a header....")
fsA.close(badHandle)
none, noneErr = imgfs.open("disk-a", "/boot/bad", imgfs.SECTION.usr)
assert(not none and noneErr:find("not a Nexus boot image", 1, true))

-- 4. The image replaced under a mounted section: a failed block read is a
--    kernel panic naming the image, not an error in the reading process.
do
    local savedPanic = panic
    local panics = {}
    panic = function(kind, reason)
        panics[#panics + 1] = kind .. ": " .. reason
        error("halted", 0)
    end
    local live = assert(imgfs.open("disk-a", "/boot/nexusos", imgfs.SECTION.usr))
    local swap = assert(fsA.open("/boot/nexusos", "w"))
    fsA.write(swap, ("x"):rep(#image))
    fsA.close(swap)
    local lh = assert(live.open("/lib/big.txt", "rb"))
    assert(live.seek(lh, "set", #big - 10))
    local ok, err = pcall(live.read, lh, 10)
    assert(not ok and err == "halted", tostring(err))
    assert(#panics == 1 and panics[1]:find("^not syncing: imgfs: /boot/nexusos: imgfs:"), panics[1])
    panic = savedPanic
end

for name, value in pairs(saved) do _G[name] = value end
io.write("imgfs tests passed\n")
