---@class devfs : oc_component_fs
devfs = {}

---@class devfs_handle
---@field ops table
---@field mode string

---@class devfs_entry
---@field ops table
---@field vnode vnode

---@type table<string, devfs_entry>
local devices = {}

---@type table<integer, vfs_descriptor>
vhandles = vhandles

---@type table<integer, devfs_handle>
local handles = {}
-- handles 0-2 are the console descriptors (see devfs.init)
local next_handle = 3


function devfs.init()
    -- The console descriptors. Their vnode (the console node) only exists once
    -- /dev is mounted, see devfs.postmount().
    vhandles["0"] = { flag = "r", fd = 0, fs = devfs }
    vhandles["1"] = { flag = "w", fd = 1, fs = devfs }
    vhandles["2"] = { flag = "w", fd = 2, fs = devfs }
    handles["0"] = { mode = "r", ops = system.console.stdin }
    handles["1"] = { mode = "w", ops = system.console.stdout }
    handles["2"] = { mode = "w", ops = system.console.stderr }
end

-- Console device ops. They resolve system.console on every call, so a later
-- system.setConsole() is picked up by already created nodes.
local consoleOps = {
    read = function(handle, ...)
        return system.console.stdin.read(handle, ...)
    end,
    write = function(handle, value)
        return system.console.stdout.write(handle, value)
    end,
}

---@param name string
---@param target string
---@return vnode|nil
local function createSymlink(name, target)
    local node = vfsk.createVNode("/dev", name, "VLNK", devfs, 777)
    if node then
        node.link = target
        node.mode = 777
    end
    return node
end

-- Creates the nodes that need /dev to be mounted (they carry a mode, or are
-- symlinks). Like Linux: /dev/console is root's, /dev/tty is the controlling
-- terminal for everybody, and /dev/std* go through /proc/self/fd/N so that
-- they follow the calling process's own descriptors.
function devfs.postmount()
    local _, _, vconsole = devfs.create("console", consoleOps, false, 620)
    devfs.create("tty", consoleOps, false, 666)
    -- /dev/null discards writes and reads as end of file; /dev/zero reads zeros
    devfs.create("null", {
        read = function() return nil end,
        write = function() return true end,
    }, false, 666)
    devfs.create("zero", {
        read = function(_, count)
            if type(count) == "number" then return string.rep("\0", math.max(0, math.min(count, 4096))) end
            return nil
        end,
        write = function() return true end,
    }, false, 666)

    if vconsole then
        for i = 0, 2 do
            vhandles[tostring(i)].vnode = vconsole
        end
    end

    createSymlink("stdin", "/proc/self/fd/0")
    createSymlink("stdout", "/proc/self/fd/1")
    createSymlink("stderr", "/proc/self/fd/2")
    createSymlink("fd", "/proc/self/fd")
end

local DEVFS_CHARS = "abcdefghijklnmopqrstuvwxyz"
function devfs.char(index)
    return DEVFS_CHARS:sub(index, index)
end

---@param name string
---@param ops table
---@param block? boolean
---@param perm? integer
---@return boolean, string?, vnode?
function devfs.create(name, ops, block, perm)
    if devices[name] then
        return false, "Device already exists"
    end
    local vnode = vfsk.createVNode("/dev", name, block and "VBLK" or "VCHR", devfs, perm)
    devices[name] = { ops = ops, vnode = vnode }
    return true, nil, vnode
end

function devfs.attributes(name)
    local entry = devices[name]
    if not entry then
        return false, "No such file or directory"
    end
    return entry.vnode
end

-- Internal detach path. Existing open handles retain their descriptions.
function devfs.unregister(name)
    local entry = devices[name]
    if not entry then return end
    devices[name] = nil
    local node = entry.vnode
    if node and node.parent and node.parent.children[node.hash] == node then
        node.parent.children[node.hash] = nil
    end
end

function devfs.spaceUsed() return 0 end

function devfs.spaceTotal() return 0 end

function devfs.isReadOnly() return false end

function devfs.makeDirectory(path) return false, "Permission denied" end

function devfs.remove(path) return false, "Permission denied" end

function devfs.rename(from, to) return false, "Permission denied" end

function devfs.lastModified(path) return 0 end

function devfs.getLabel() return "devfs" end

function devfs.setLabel(value) return "devfs" end

function devfs.size(path) return 0 end

function devfs.exists(path)
    if path == "/" or path == "" or path == "." then return true end
    local name = path:match("^/?(.+)$")
    return devices[name] ~= nil
end

function devfs.isDirectory(path)
    return path == "/" or path == "" or path == "."
end

function devfs.list(path)
    --printk("list: " .. path)
    if not devfs.isDirectory(path) then return {} end
    local list = {}
    for name, _ in pairs(devices) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
end

function devfs.open(path, mode)
    local name = path:match("^/?(.+)$")
    local entry = devices[name]

    if not entry then
        return nil, "No such file or directory"
    end

    local handle = next_handle
    next_handle = next_handle + 1
    handles[tostring(handle)] = { ops = entry.ops, mode = mode or "r" }

    return handle
end

function devfs.read(handle, ...)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end
    if not h.mode:find("r") then return nil, "File not open for reading" end

    if h.ops.read then
        return h.ops.read(handle, ...)
    end
    return nil, "Operation not supported"
end

function devfs.write(handle, value)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end
    if not h.mode:find("w") and not h.mode:find("a") then return nil, "File not open for writing" end

    if h.ops.write then
        return h.ops.write(handle, value)
    end
    return false, "Device not writable"
end

function devfs.seek(handle, whence, offset)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end

    if h.ops.seek then
        return h.ops.seek(handle, whence, offset)
    end
    return 0
end

function devfs.close(handle)
    local h = handles[tostring(handle)]
    if h then
        if h.ops.close then
            h.ops.close(handle)
        end
        handles[tostring(handle)] = nil
    end
end
