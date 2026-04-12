---@type oc_env
_ENV = _ENV

---@param env? table
loadfile = function(file, env)
    local addr, invoke = computer.getBootAddress(), component.invoke
    local handle, reason = invoke(addr, "open", file)
    if not handle then
        return nil, reason
    end

    local buffer = ""
    while true do
        local data, reason = invoke(addr, "read", handle, math.huge)
        if not data then
            if reason then
                invoke(addr, "close", handle)
                return nil, reason
            else
                break
            end
        end
        buffer = buffer .. data
    end
    invoke(addr, "close", handle)

    local chunk, err = load(buffer, "=" .. file, "bt", env or _ENV)
    if not chunk then
        return nil, err
    end
    return chunk
end

local f, e = loadfile("boot/kernel.lua")
if not f then
    error(e)
else
    local s, e = xpcall(f, debug.traceback, "init=/usr/sbin/init.lua")
    if not s then
        error(e)
    end
end
