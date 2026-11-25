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
getRealTime = function()
    return bootRealTime + computer.uptime()
end

loadfile = loadfile and loadfile or function(a,b)local c,d=computer.getBootAddress(),component.invoke;local e,f=d(c,"open",a)if not e then return nil,f end;local g=""while true do local h,f=d(c,"read",e,math.huge)if not h then if f then d(c,"close",e)return nil,f else break end end;g=g..h end;d(c,"close",e)local i,j=load(g,"="..a,"bt",b or _ENV)if not i then return nil,j end;return i end

---@type nexus_config
config = {}
do
    local f, e = loadfile("/boot/config.lua")
    if f then
        config = f() or {}
    end
end

---@param env? table
loadfile = function(file, env) end

version = {
    id = "Nexus 0.0.7-dev-oc";
    name = "Nexus";
    ver = "0.0.7-dev-oc";
    dist = "Nexus";
};

_OSVERSION = config.kernel_version.id
_OSVERSIONSTRING = config.kernel_version.ver
_OSDIST = config.kernel_version.dist
_OSNAME = config.kernel_version.name
_MACHINE = "OpenComputers (" .. computer.getArchitecture() .. ")"

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

