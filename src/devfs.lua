---@class devfs : oc_component_fs
devfs = {}

---@class devfs_handle
---@field driver table
---@field mode string

---@class devfs_entry
---@field driver table
---@field vnode vnode

---@type table<string, devfs_entry>
local devices = {}

---@type table<integer, vfs_descriptor>
vhandles = vhandles

---@type table<integer, devfs_handle>
local handles = {}
local next_handle = 1

---@type module
local module
---@type system
local system

function devfs.init()
    vfs.mount(devfs, "/dev")

    local i = 0
    for proxy in component.list("gpu") do
        devfs.create("gpu" .. i, component.proxy(proxy) --[[@as oc_component_gpu]])
        i = i + 1
    end

    local _, _, vstdin = devfs.create("stdin", system.console.stdin)
    local _, _, vstdout = devfs.create("stdout", system.console.stdout)
    local _, _, vstderr = devfs.create("stderr", system.console.stderr)

    vhandles["0"] = { flag = "r", fd = 0, fs = devfs, vnode = vstdin }
    vhandles["1"] = { flag = "w", fd = 1, fs = devfs, vnode = vstdout }
    vhandles["2"] = { flag = "w", fd = 2, fs = devfs, vnode = vstderr }
    handles["0"] = { mode = "r", driver = system.console.stdin }
    handles["1"] = { mode = "w", driver = system.console.stdout }
    handles["2"] = { mode = "w", driver = system.console.stderr }
end

---@param name string
---@param driver table
---@return boolean, string?, vnode?
function devfs.create(name, driver)
    --printd("creating device " .. name)
    if devices[name] then
        return false, "Device already exists"
    end
    local vnode = vfs.createVNode("/dev", name, "VCHR", devfs)
    devices[name] = { driver = driver, vnode = vnode }
    return true, nil, vnode
end

function devfs.attributes(name)
    local entry = devices[name]
    if not entry then
        return false, "No such file or directory"
    end
    return entry.vnode
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
    printk("list: " .. path)
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
    handles[tostring(handle)] = { driver = entry.driver, mode = mode or "r" }

    return handle
end

function devfs.read(handle, ...)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end
    if not h.mode:find("r") then return nil, "File not open for reading" end

    if h.driver.read then
        return h.driver.read(handle, ...)
    end
    return h.driver
end

function devfs.write(handle, value)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end
    if not h.mode:find("w") and not h.mode:find("a") then return nil, "File not open for writing" end

    if h.driver.write then
        return h.driver.write(handle, value)
    end
    return false, "Device not writable"
end

function devfs.seek(handle, whence, offset)
    local h = handles[tostring(handle)]
    if not h then return nil, "Bad file descriptor" end

    if h.driver.seek then
        return h.driver.seek(handle, whence, offset)
    end
    return 0
end

function devfs.close(handle)
    local h = handles[tostring(handle)]
    if h then
        if h.driver.close then
            h.driver.close(handle)
        end
        handles[tostring(handle)] = nil
    end
end
