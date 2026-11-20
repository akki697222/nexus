-- Run from the Nexus directory: lua tests/device_hotplug.lua
local function readSource(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local info = {
    system = { class = "volume", description = "Disk", vendor = "OC", product = "System disk" },
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
    readSource("src/devfs.lua"),
    readSource("src/device.lua"),
    "return device",
}, "\n")
local device = assert(load(source, "@device_hotplug", "t", env))()

device.init()
device.register()
device.register()
assert(devRoot.children.hd0.type == "VBLK")
assert(devRoot.children.hd1 == nil)
assert(device.get("system").product == "System disk")
local snapshot = device.list()
snapshot.system.type = "floppy"
assert(device.get("system").type == "volume")

info.extra = { class = "volume", description = "Disk", vendor = "OC", product = "Extra disk" }
device.handleEvent("component_added", "extra")
assert(env.devfs.exists("hd1") and devRoot.children.hd1.type == "VBLK")
device.handleEvent("component_removed", "extra")
assert(not env.devfs.exists("hd1") and devRoot.children.hd1 == nil and device.get("extra") == nil)
assert(env.devfs.exists("hd0") and device.get("system"))
print("OC device inventory and hotplug tests passed")
