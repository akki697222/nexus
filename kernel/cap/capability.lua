-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

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

function capability.create(id, ops)
    arg(1, id,  "string")
    arg(2, ops, "table", true)

    local def = capability.get(id)
    if not def then
        error("unknown capability '" .. id .. "'")
    end

    local resolved = capability.resolve_ops(def, ops)

    -- get full core from driver/service
    local core = def.new()

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
    registry[mt] = { core = core, def = def }

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
    -- release driver/service resources
    entry.def.dispose(entry.core)
    registry[mt] = nil
end

function capability.is_valid(instance)
    arg(1, instance, "table")
    local mt = getmetatable(instance)
    if not mt then return false end
    return mt.__index ~= nil
end