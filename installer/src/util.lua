-- installer/src/util.lua - small helpers

util = {}

-- Lets the machine breathe during long work; OC stops a machine that runs
-- for seconds without yielding. Drops a queued signal, if any.
function util.yield()
    computer.pullSignal(0)
end

-- Seconds since the Unix epoch: a fresh tmpfs file's modification time is
-- the host's wall clock (as the kernel does at boot). 0 when unknown.
function util.realTime()
    local tmp = computer.tmpAddress and computer.tmpAddress()
    if not tmp then return 0 end
    local path = "/.nexus-install-clock"
    local handle = component.invoke(tmp, "open", path, "w")
    if not handle then return 0 end
    component.invoke(tmp, "close", handle)
    local ms = component.invoke(tmp, "lastModified", path)
    component.invoke(tmp, "remove", path)
    if type(ms) ~= "number" or ms <= 0 then return 0 end
    return math.floor(ms / 1000)
end

-- Plain data (strings, numbers, booleans, tables) as Lua source.
function util.serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then error("cannot serialize a " .. t, 0) end
    local inner = indent .. "    "
    local parts, n = {}, #v
    for i = 1, n do parts[#parts + 1] = inner .. util.serialize(v[i], inner) .. ",\n" end
    local keys = {}
    for k in pairs(v) do
        if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = inner .. k .. " = " .. util.serialize(v[k], inner) .. ",\n"
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts) .. indent .. "}"
end

-- Loads a data file (`return { ... }`) without giving it any environment.
-- Returns the value, or nil and why. These files come from disks and the
-- network, so a broken one is reported, not raised.
function util.loadData(text, name)
    local chunk, err = load(text, "=" .. name, "t", {})
    if not chunk then return nil, err end
    local ok, value = pcall(chunk)
    if not ok then return nil, name .. ": " .. tostring(value) end
    return value
end

function util.size(bytes)
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1048576) end
    if bytes >= 1024 then return string.format("%d KB", math.floor(bytes / 1024 + 0.5)) end
    return bytes .. " B"
end

-- hostnames and user names the system accepts
function util.validHostname(name)
    return #name >= 1 and #name <= 63 and name:match("^[%w][%w%-]*$") ~= nil
end

function util.validUsername(name)
    return #name >= 1 and #name <= 32 and name:match("^[%l_][%l%d_%-]*$") ~= nil and name ~= "root"
end

-- The /etc/shadow hash of a password (src/sec/user.lua).
function util.passwordHash(password)
    return (sha512(password .. "salt"):gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end
