-- Run from the Nexus directory: lua tests/device_hotplug.lua
local function readSource(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local info = {
    system = { class = "volume", description = "Disk", vendor = "OC", product = "System disk", size = "32768" },
}
local devRoot = { children = {} }
local env = setmetatable({
    computer = { getDeviceInfo = function() return info end },
    util = { copyTable = function(entry)
        local copy = {}
        for k, v in pairs(entry) do copy[k] = v end
        return copy
    end },
    vfsk = { createVNode = function(path, name, kind, fs, mode)
        assert(path == "/dev" and devRoot.children[name] == nil)
        local node = { name = name, hash = name, type = kind, mode = mode, fs = fs, parent = devRoot }
        devRoot.children[name] = node
        return node
    end },
}, { __index = _G })

local source = table.concat({
    readSource("src/fs/devfs.lua"),
    readSource("src/dev/device.lua"),
    "return device",
}, "\n")
local device = assert(load(source, "@device_hotplug", "t", env))()

device.init()
device.register()
device.register()
assert(devRoot.children.hd0.type == "VBLK")
assert(devRoot.children.hd1 == nil)
assert(device.get("system").product == "System disk")
assert(device.get("system").node == "hd0")
local snapshot = device.list()
snapshot.system.type = "floppy"
snapshot.system.node = "evil"
assert(device.get("system").type == "volume")
assert(device.get("system").node == "hd0")

info.extra = { class = "volume", description = "Disk", vendor = "OC", product = "Extra disk" }
device.handleEvent("component_added", "extra")
assert(env.devfs.exists("hd1") and devRoot.children.hd1.type == "VBLK")
assert(device.get("extra").node == "hd1")
device.handleEvent("component_added", "extra")
assert(device.get("extra").node == "hd1" and devRoot.children.hd1)
device.handleEvent("component_removed", "extra")
assert(not env.devfs.exists("hd1") and devRoot.children.hd1 == nil and device.get("extra") == nil)
assert(env.devfs.exists("hd0") and device.get("system"))

info.floppy = { class = "volume", clock = "20/20/20", product = "Floppy", size = "-1" }
device.handleEvent("component_added", "floppy")
local rows = {}
local filesystem = { mounts = function()
    local rows = {
        { { address = "system", label = "rootfs", readOnly = false }, "/root-copy" },
        { { address = "system", label = "rootfs", readOnly = false }, "/" },
    }
    local index = 0
    return function()
        index = index + 1
        if rows[index] then return table.unpack(rows[index]) end
    end
end }
local modules = {
    argparse = assert(loadfile("root/usr/lib/libargparse.lua"))(),
    device = device,
    filesystem = filesystem,
}
local cli = setmetatable({
    require = function(name) return assert(modules[name], name) end,
    io = { write = function(line) rows[#rows + 1] = line end },
}, { __index = _G })
assert(loadfile("root/usr/ubin/lsblk.lua", "t", cli))("-b")
assert(rows[2]:find("/dev/fd0", 1, true) and rows[2]:find("unlimited", 1, true))
assert(rows[3]:find("/dev/hd0", 1, true) and rows[3]:find("32768", 1, true))
assert(rows[3]:find("rootfs", 1, true) and rows[3]:find("/,/root-copy", 1, true))
assert(#rows == 3, "detached volumes must not appear in lsblk")

print("OC device inventory and hotplug tests passed")
