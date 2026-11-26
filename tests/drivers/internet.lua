-- internet driver: HTTP requests and TCP sockets through the card, as
-- devmgr loads it (no component, computer or event in its environment).
-- Run from the Nexus directory: lua tests/drivers/internet.lua
local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("a")
    f:close()
    return s
end

local source = read("root/usr/lib/modules/system/kernel/drivers/network/internet.drv.lua")

local env = {
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring, tonumber = tonumber,
    error = error, pcall = pcall, select = select, setmetatable = setmetatable,
    checkArg = function(_, v, ...)
        for _, t in ipairs({ ... }) do if type(v) == t then return end end
        error("bad argument", 2)
    end,
    string = string, table = table, math = math,
}
local mod = assert(load(source, "=internet.drv.lua", "t", env))()
local drv = mod.driver
assert(mod.manifest.name == "internet" and mod.manifest.abi == 1 and mod.manifest.version_n == 1)
assert(type(mod.load) == "function" and type(mod.unload) == "function")
assert(drv.node == "eth" and drv.group == "ethernet" and drv.access.request == "rw" and drv.priority == 0)
for op in pairs(drv.access) do
    assert(type(drv.ops[op]) == "function", "missing op " .. op)
end

-- a card: request() hands back a scripted request
local made = {}
local http = true
local proxy = {
    isHttpEnabled = function() return http end,
    isTcpEnabled = function() return true end,
    request = function(url, body, headers, method, extra)
        assert(extra == nil)
        if url == "https://down.test/" then error("host unreachable") end
        local r = { url = url, body = body, headers = headers, method = method, closed = false,
            connects = 0, pieces = { "he", "", "llo" } }
        function r.finishConnect()
            r.connects = r.connects + 1
            return r.connects > 1
        end
        function r.response() return 200, "OK", { ["Content-Type"] = { "text/plain" } } end
        function r.read()
            if r.url:find("broken") then error("connection reset") end
            return table.remove(r.pieces, 1)
        end
        function r.close() r.closed = true end
        made[#made + 1] = r
        return r
    end,
    connect = function(addr, port)
        local s = { addr = addr, port = port }
        function s.finishConnect() return true end
        function s.id() return "sock1" end
        function s.write(d) return #d end
        function s.read() return "pong" end
        function s.close() s.closed = true end
        return s
    end,
}
local inst = assert(drv.attach({ address = "1234abcd", type = "internet", proxy = proxy }))

local req = assert(drv.ops.request(inst, "https://x.test/a", "{}", { ["X-A"] = "1" }, "POST"))
local r = made[1]
assert(r.body == "{}" and r.headers["X-A"] == "1" and r.method == "POST")
assert(req:finishConnect() == false and req:finishConnect() == true)
local code, message, headers = req:response()
assert(code == 200 and message == "OK" and headers["Content-Type"][1] == "text/plain")
headers["Content-Type"][1] = "changed"
assert(select(3, req:response())["Content-Type"][1] == "text/plain", "callers get a copy")
assert(req:read(10) == "he" and req:read() == "" and req:read() == "llo" and req:read() == nil)
req:close()
assert(r.closed and select(2, req:read()) == "request is closed")

-- GET without a method argument; failures come back as nil, why
assert(drv.ops.request(inst, "https://x.test/b"))
assert(made[2].method == nil and made[2].body == nil)
local none, why = drv.ops.request(inst, "https://down.test/")
assert(none == nil and why:find("host unreachable"))
local broken = assert(drv.ops.request(inst, "https://x.test/broken"))
local chunk, rerr = broken:read()
assert(chunk == nil and rerr:find("connection reset"))
http = false
assert(select(2, drv.ops.request(inst, "https://x.test/")) == "HTTP is disabled on this server")
assert(not pcall(drv.ops.request, inst, 42), "the URL must be a string")

-- TCP: connected by the caller, no event library needed
local sock = assert(drv.ops.connect(inst, "example.test", 25))
assert(sock:finishConnect() == true and sock:id() == "sock1")
assert(sock:write("ping") == 4 and sock:read() == "pong")
sock:close()
assert(select(2, sock:read()) == "socket is closed")

print("internet driver tests passed")
