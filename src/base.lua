log_buffer = setmetatable({}, {
    __newindex = function(t, k, v)
        if type(k) == "number" then
            if k > 500 then -- Limit to 500 lines
                table.remove(t, 1)
                rawset(t, #t + 1, v)
                return
            end
        end
        rawset(t, k, v)
    end
})
bootRealTime = 0

_OSVERSION = _OSVERSION or "Nexus 0.1.0-dev-oc_ocelot"
_OSVERSIONNUMBER = _OSVERSIONNUMBER or 1
_OSDIST = _OSDIST or _OSVERSION

getRealTime = function()
    return bootRealTime + computer.uptime()
end

---@type onix_config
config = {}
do
    local f, e = loadfile("/boot/config.lua")
    if f then
        config = f() or {}
    end
end

---@param env? table
loadfile = function(file, env) end

fnv1a_hash = function(str)
    local hash = 2166136261
    for i = 1, #str do
        hash = (hash ~ str:byte(i)) & 0xFFFFFFFF
        hash = (hash * 16777619) % 4294967296
        hash = math.tointeger(hash) & 0xFFFFFFFF
    end
    return hash
end

function toHex(str)
    return (str:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

function checkArg(index, value, ...)
    local types = table.pack(...)
    local real_type = type(value)
    local matched = false

    for i = 1, types.n do
        if real_type == types[i] then
            matched = true
            break
        end
    end

    if not matched then
        local expected = table.concat(types, " or ")
        error(string.format("bad argument #%d (%s expected, got %s)", index, expected, real_type), 3)
    end
end

local process
local io
