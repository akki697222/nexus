-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- driver_service: maps OC components to Nexus device types, registers them
-- with the Capability Manager and follows hotplug (component_added /
-- component_removed). Drivers only build handles; capability issue, revoke
-- and lifetime are handled by the kernel (capability.*).

-- ------------------------------------------------------------
--  Capability definitions per Nexus device type
-- ------------------------------------------------------------

local function device_def(ops)
    return {
        ops = ops,
        new = function(handle)
            local core = {}
            for name, fn in pairs(handle.ops) do core[name] = fn end
            core.addr = function() return handle.addr end
            return core
        end,
        dispose = function() end,
    }
end

capability.register("display", device_def({
    "addr", "bind", "fill", "set", "copy", "set_bg", "set_fg",
    "resolution", "set_resolution", "max_resolution", "depth", "set_depth", "max_depth",
    graphics = { "bind", "fill", "set", "copy", "set_bg", "set_fg", "resolution", "set_resolution", "max_resolution" },
}))
capability.register("screen",  device_def({ "addr" }))
capability.register("input",   device_def({ "addr" }))
capability.register("storage", device_def({ "addr", "label", "space_total", "space_used", "capacity" }))
capability.register("network", device_def({ "addr", "is_wireless" }))
capability.register("eeprom",  device_def({ "addr", "get", "label", "size" }))

-- ------------------------------------------------------------
--  Drivers (1 component type = 1 driver)
-- ------------------------------------------------------------

local drivers = {}

local function simple(component_type, nexus_type, ops_fn)
    drivers[component_type] = {
        component_type = component_type,
        init = function(addr, proxy)
            return {
                addr       = addr,
                nexus_type = nexus_type,
                proxy      = proxy,
                ops        = ops_fn and ops_fn(proxy) or {},
            }
        end,
        teardown = function() end,
    }
end

simple("gpu", "display", function(p)
    return {
        bind           = function(screen_addr) return p.bind(screen_addr, true) end,
        fill           = function(x, y, w, h, ch) return p.fill(x, y, w, h, ch) end,
        set            = function(x, y, str) return p.set(x, y, str) end,
        copy           = function(x, y, w, h, tx, ty) return p.copy(x, y, w, h, tx, ty) end,
        set_bg         = function(col) return p.setBackground(col) end,
        set_fg         = function(col) return p.setForeground(col) end,
        resolution     = function() return p.getResolution() end,
        set_resolution = function(w, h) return p.setResolution(w, h) end,
        max_resolution = function() return p.maxResolution() end,
        depth          = function() return p.getDepth() end,
        set_depth      = function(d) return p.setDepth(d) end,
        max_depth      = function() return p.maxDepth() end,
    }
end)
simple("screen", "screen")
simple("keyboard", "input")
simple("filesystem", "storage", function(p)
    return {
        label       = function() return p.getLabel() end,
        space_total = function() return p.spaceTotal() end,
        space_used  = function() return p.spaceUsed() end,
    }
end)
simple("drive", "storage", function(p)
    return {
        label    = function() return p.getLabel() end,
        capacity = function() return p.getCapacity() end,
    }
end)
simple("modem", "network", function(p)
    return { is_wireless = function() return p.isWireless() end }
end)
simple("internet", "network")
simple("eeprom", "eeprom", function(p)
    return {
        get   = function() return p.get() end,
        label = function() return p.getLabel() end,
        size  = function() return p.getSize() end,
    }
end)

-- ------------------------------------------------------------
--  Hotplug
-- ------------------------------------------------------------

local handles = {}   -- addr -> driver_handle

local function add(addr, ctype)
    local drv = drivers[ctype]
    if not drv or handles[addr] then return end
    local ok, handle = pcall(drv.init, addr, component.proxy(addr))
    if not ok then
        log.warn("[driver] %s init failed for %s: %s", ctype, addr:sub(1, 8), tostring(handle))
        return
    end
    handle.driver = drv
    handles[addr] = handle
    capability.register_device(handle)
    router.broadcast({ type = "device_added", nexus_type = handle.nexus_type, addr = addr })
end

local function remove(addr)
    local handle = handles[addr]
    if not handle then return end
    handles[addr] = nil
    capability.revoke_device(addr)
    pcall(handle.driver.teardown, handle)
    router.broadcast({ type = "device_removed", nexus_type = handle.nexus_type, addr = addr })
end

for addr, ctype in component.list() do
    add(addr, ctype)
end

log.info("[driver] ready")
service_manager.ready("driver")

while true do
    local ev = event.pull()
    if ev.type == "component_added" then
        add(ev.data[2], ev.data[3])
    elseif ev.type == "component_removed" then
        remove(ev.data[2])
    end
end
