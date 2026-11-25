-- The .meta files the installer writes (installer/src/meta.lua) and
-- build.lua deploys (tools/nximg.lua deployMeta), read by the real VFS:
-- modes and owners arrive as written, and the lines match the ones the
-- VFS writes itself, so the two writers cannot drift apart.
-- Run from nexus/: lua tests/kernel/install_meta.lua
-- (VFS harness shared with tests/kernel/imgfs.lua)
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
local function octal(s) return tonumber(s, 8) end

-- the installer's writer, as stage1 uses it
local menv = { string = string, math = math, table = table, pairs = pairs, ipairs = ipairs }
assert(hostLoadfile("installer/src/meta.lua", "t", menv))()
local meta = menv.meta

local disk = fakeFs("disk-i")
local function mkdir(path) assert(disk.makeDirectory(path)) end
local function put(path, data)
    local h = assert(disk.open(path, "w"))
    disk.write(h, data)
    disk.close(h)
end
for _, d in ipairs({ "/usr", "/usr/bin", "/etc", "/home", "/home/alice", "/root" }) do mkdir(d) end
put("/usr/bin/sudo.lua", "return 'sudo'")
put("/usr/bin/sh.lua", "return 'sh'")
put("/etc/shadow", "root:*:0:0:99999:7:::\n")
put("/etc/notes", "no .meta line")

local set = meta.new()
set.add("/usr", true, octal("755"), 0, 0)
set.add("/usr/bin", true, octal("755"), 0, 0)
set.add("/usr/bin/sudo.lua", false, octal("4755"), 0, 0)
set.add("/usr/bin/sh.lua", false, octal("755"), 0, 0)
set.add("/etc", true, octal("755"), 0, 0)
set.add("/etc/shadow", false, octal("400"), 0, 0)
set.add("/home", true, octal("755"), 0, 0)
set.add("/home/alice", true, octal("755"), 100, 100)
set.add("/root", true, octal("700"), 0, 0)
local TIME = 1767225600
local written = {}
set.each(TIME, function(dir, text)
    written[dir] = text
    put((dir == "/" and "" or dir) .. "/.meta", text)
end)
assert(written["/usr/bin"]:find("sudo.lua:VREG:%d+:1767225600:1767225600:4755:1:0:0:\n"))

assert(vfs.mount(disk, "/"))
local function node(path) return assert(vfsk.lookup(path), path) end
assert(node("/usr/bin/sudo.lua").mode == 4755 and node("/usr/bin/sudo.lua").uid == 0)
assert(node("/usr/bin/sh.lua").mode == 755)
assert(node("/etc/shadow").mode == 400)
assert(node("/etc/notes").mode == 644, "files without a line keep the defaults")
local alice = node("/home/alice")
assert(alice.mode == 755 and alice.uid == 100 and alice.gid == 100)
assert(node("/root").mode == 700)
assert(node("/usr/bin/sudo.lua").mtime == TIME and node("/usr/bin/sudo.lua").btime == TIME)
local attrs = assert(vfs.attributes("/usr/bin/sudo.lua"))
assert(attrs.mode == 4755 and attrs.uid == 0)

-- The VFS writes the same lines back (its hash aside) after a change.
assert(vfs.chmod("/usr/bin/sh.lua", 750))
assert(vfs.chmod("/usr/bin/sh.lua", 755))
assert(vfs.saveMetadata())
local h = assert(disk.open("/usr/bin/.meta", "r"))
local back = disk.read(h, 1 << 20)
disk.close(h)
-- name:vtype:...:mode:refcount:uid:gid:link, without hash and times
local function lines(text)
    local out = {}
    for line in text:gmatch("[^\n]+") do
        local name, rest = line:match("^([^:]+:V%u+:)%d+:%d+:%d+:(.*)$")
        out[#out + 1] = name .. rest
    end
    table.sort(out)
    return table.concat(out, "\n")
end
assert(lines(back) == lines(written["/usr/bin"]), back .. "\n--\n" .. written["/usr/bin"])

-- build.lua: the .meta files of a deployed /usr (on the host: the VFS
-- replaced the global loadfile)
local vfsLoadfile = loadfile
loadfile = hostLoadfile
local hostRead = function(path)
    local f = assert(io.open(path, "rb"))
    local v = f:read("a")
    f:close()
    return v
end
local nximg = assert(hostLoadfile("tools/nximg.lua"))()
local dest = os.tmpname()
os.remove(dest)
local count = nximg.deployMeta("root/usr", dest, "/usr")
assert(count > 3)
local bin = hostRead(dest .. "/bin/.meta")
assert(bin:find("\nsudo.lua:VREG:%d+:%d+:%d+:4755:1:0:0:\n") or bin:find("^sudo.lua:VREG:%d+:%d+:%d+:4755:1:0:0:\n"), bin)
assert(bin:find("sh.lua:VREG:%d+:%d+:%d+:755:1:0:0:\n"), bin)
assert(hostRead(dest .. "/.meta"):find("bin:VDIR:%d+:%d+:%d+:755:1:0:0:\n"))
assert(hostRead(dest .. "/lib/.meta"):find("libargparse.lua:VREG:%d+:%d+:%d+:644:1:0:0:\n"))
os.execute((package.config:sub(1, 1) == "\\" and 'rmdir /s /q "' or 'rm -rf "') .. dest .. '"')
loadfile = vfsLoadfile

for name, value in pairs(saved) do _G[name] = value end
io.write("install meta tests passed\n")
