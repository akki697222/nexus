-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type capability
capability = {}

---@type table<string, cap_def>
local caps = {}

---@type table<cap_mt, { core: cap_core, def: cap_def }>
local registry = {}

function capability.register(id, def)
    arg(1, id,  "string")
    arg(2, def, "table")
    if caps[id] then
        log.warn("Duplicated capability registration '%s'", id)
    end
    caps[id] = def
    log.info("Capability '%s' registered successfully!", id)
end

function capability.get(id)
    arg(1, id, "string")
    return caps[id]
end

function capability.resolve_ops(def, ops)
    arg(1, def, "table")
    arg(2, ops, "table", true)

    -- collect all valid standalone op names from def.ops
    local valid = {}
    for k, v in pairs(def.ops) do
        if type(k) == "number" and type(v) == "string" then
            valid[v] = true
        end
    end

    -- if ops is nil, default to all standalone ops
    if ops == nil then
        return valid
    end

    local resolved = {}
    for _, entry in ipairs(ops) do
        if type(entry) == "string" then
            local group = def.ops[entry]
            if type(group) == "table" then
                -- expand group
                for _, name in ipairs(group) do
                    if not valid[name] then
                        error("unknown op '" .. name .. "' in group '" .. entry .. "'")
                    end
                    resolved[name] = true
                end
            elseif valid[entry] then
                resolved[entry] = true
            else
                error("unknown op '" .. entry .. "'")
            end
        else
            error("bad ops entry: string expected, got " .. type(entry))
        end
    end

    return resolved
end

function capability.create(id, ops, ...)
    arg(1, id,  "string")
    arg(2, ops, "table", true)

    local def = capability.get(id)
    if not def then
        error("unknown capability '" .. id .. "'")
    end

    local resolved = capability.resolve_ops(def, ops)

    -- get full core from driver/service
    local core = def.new(...)

    -- build filtered core containing only resolved ops
    local filtered = {}
    for k, v in pairs(core) do
        if type(v) == "function" and resolved[k] then
            filtered[k] = v
        end
    end

    -- shared metatable: all instances derived from this cap share the same mt
    -- revocation is performed by setting mt.__index = nil
    ---@type cap_mt
    local mt = { __index = filtered }

    -- store mt → { core, def } for revocation
    local owner = scheduler.current()
    registry[mt] = { core = core, def = def, owner = owner }
    core._mt = mt   -- lets an op revoke its own capability (e.g. stream:close)

    -- lifetime: revoked automatically when the creating process dies
    local proc = process_manager.get(owner)
    if proc then proc.owned[mt] = true end

    ---@type cap_obj
    local instance = setmetatable({}, mt)

    return instance, mt
end

function capability.revoke(mt)
    arg(1, mt, "table")
    local entry = registry[mt]
    if not entry then
        log.warn("capability.revoke: unknown mt, already revoked?")
        return
    end
    -- invalidate all instances sharing this mt
    mt.__index = nil
    local proc = process_manager.get(entry.owner)
    if proc then proc.owned[mt] = nil end
    -- release driver/service resources
    local ok, err = pcall(entry.def.dispose, entry.core)
    if not ok then
        log.warn("capability dispose error: %s", tostring(err))
    end
    registry[mt] = nil
end

function capability.is_valid(instance)
    arg(1, instance, "table")
    local mt = getmetatable(instance)
    if not mt then return false end
    return mt.__index ~= nil
end

-- ------------------------------------------------------------
--  Device registry (driver_handle -> capability)
-- ------------------------------------------------------------

---@type table<string, { handle: table, mts: table<table, true> }>
local devices = {}

---Register a driver_handle (called by driver_service).
function capability.register_device(handle)
    arg(1, handle, "table")
    devices[handle.addr] = { handle = handle, mts = {} }
    log.info("Device registered: %s (%s)", handle.nexus_type, handle.addr:sub(1, 8))
end

---Create a capability for a registered device.
---@param nexus_type string
---@param ops (string|string[])[]|nil
---@param addr string?  # pick a specific device (default: first of that type)
function capability.open_device(nexus_type, ops, addr)
    arg(1, nexus_type, "string")
    arg(2, ops,  "table",  true)
    arg(3, addr, "string", true)
    local dev
    if addr then
        dev = devices[addr]
        if dev and dev.handle.nexus_type ~= nexus_type then dev = nil end
    else
        local best
        for a, d in pairs(devices) do
            if d.handle.nexus_type == nexus_type and (not best or a < best) then
                best, dev = a, d
            end
        end
    end
    if not dev then
        return nil, "no '" .. nexus_type .. "' device available"
    end
    local cap, mt = capability.create(nexus_type, ops, dev.handle)
    dev.mts[mt] = true
    return cap, mt
end

---Revoke every capability of a device and forget it. Returns the handle.
function capability.revoke_device(addr)
    arg(1, addr, "string")
    local dev = devices[addr]
    if not dev then return nil end
    devices[addr] = nil
    local mts = {}
    for mt in pairs(dev.mts) do
        if registry[mt] then mts[#mts + 1] = mt end   -- skip already-disposed ones
    end
    for _, mt in ipairs(mts) do
        capability.revoke(mt)
    end
    log.info("Device revoked: %s (%s), %d capabilities", dev.handle.nexus_type, addr:sub(1, 8), #mts)
    return dev.handle
end

function capability.list_devices()
    local out = {}
    for addr, d in pairs(devices) do out[addr] = d.handle end
    return out
end
