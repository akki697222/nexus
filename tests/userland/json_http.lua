-- libjson and libhttp (require("json"), require("http")).
-- Run from the Nexus directory: lua tests/userland/json_http.lua
local json = assert(loadfile("root/usr/lib/libjson.lua"))()

-- encoding
assert(json.encode({ b = 1, a = { true, false, json.null }, c = "x\n\"\1" })
    == '{"a":[true,false,null],"b":1,"c":"x\\n\\"\\u0001"}')
assert(json.encode({}) == "{}" and json.encode(json.array()) == "[]")
assert(json.encode(1.5) == "1.5" and json.encode(2.0) == "2.0" and json.encode(-7) == "-7")
assert(json.encode("日本") == '"日本"')
assert(not pcall(json.encode, { [1] = 1, x = 2 }), "mixed keys")
local cyc = {}
cyc.self = cyc
assert(not pcall(json.encode, cyc))
assert(not pcall(json.encode, 0 / 0))

-- decoding
local v = assert(json.decode(' { "a" : [1, 2.5, -3e2, "s\\u00e9\\ud83d\\ude00\\n", true, null], "b": {} } '))
assert(v.a[1] == 1 and math.type(v.a[1]) == "integer" and v.a[2] == 2.5 and v.a[3] == -300)
assert(v.a[4] == "sé😀\n" and v.a[5] == true and v.a[6] == json.null and next(v.b) == nil)
assert(json.encode(json.decode("[]")) == "[]", "decoded arrays stay arrays")
for _, bad in ipairs({ "", "{", '{"a"}', "[1,]", '"\\x"', "tru", "1 2", '"a\nb"', "[" .. ("[" ):rep(300) }) do
    local ok, err = json.decode(bad)
    assert(ok == nil and type(err) == "string" and err:find("^json:"), bad)
end
local _, where = json.decode('{\n"a": ?}')
assert(where:find("line 2"), where)
-- round trip
local doc = { model = "m", messages = json.array({ { role = "user", content = "hi" } }), n = 3, f = false }
assert(json.encode(json.decode(json.encode(doc))) == json.encode(doc))

------------------------------------------------------------
-- libhttp over a fake /dev/eth0
------------------------------------------------------------
local now = 0
local pulls = 0
local script -- url -> { status, headers, pieces }
local requests = {}
local deviceLib = {}
local opened = 0
function deviceLib.open(path, mode)
    if path ~= "/dev/eth0" then return nil, "No such device" end
    if mode ~= "rw" then return nil, "bad mode" end
    opened = opened + 1
    return {
        request = function(url, body, headers, method)
            requests[#requests + 1] = { url = url, body = body, headers = headers, method = method }
            local s = script[url]
            if not s then return nil, "unknown host" end
            local pieces = { table.unpack(s.pieces or {}) }
            local r, asked = {}, false
            function r:finishConnect() return true end
            function r:response()
                if not asked then asked = true return nil end
                return s.status, "msg", s.headers or {}
            end
            function r:read()
                local p = table.remove(pieces, 1)
                if p == "!" then return nil, "reset" end
                return p
            end
            function r:close() end
            return r
        end,
    }
end
function deviceLib.close() opened = opened - 1 return true end
local env = setmetatable({
    require = function(n)
        if n == "device" then return deviceLib end
        if n == "event" then return { pull = function() pulls = pulls + 1 now = now + 0.05 end } end
        if n == "computer" then return { uptime = function() return now end } end
        error(n)
    end,
}, { __index = _G })
local http = assert(loadfile("root/usr/lib/libhttp.lua", "t", env))()

script = {
    ["https://a.test/x"] = { status = 302, headers = { Location = { "/y" } } },
    ["https://a.test/y"] = { status = 200, headers = { ["Content-Type"] = { "text/plain", "charset=x" } },
        pieces = { "ab", "", "cd" } },
}
local res = assert(http.request("https://a.test/x", { method = "POST", body = "q", headers = { A = "1" } }))
assert(res.status == 200 and res.body == "abcd" and res.headers["content-type"] == "text/plain, charset=x")
assert(requests[2].url == "https://a.test/y" and requests[2].method == "POST" and requests[2].body == "q")
assert(opened == 0, "the device is closed again")

-- streamed
local got = {}
res = assert(http.request("https://a.test/y", { onChunk = function(c) got[#got + 1] = c end }))
assert(res.body == nil and table.concat(got) == "abcd")

-- 303 turns into a GET without a body
script["https://a.test/s"] = { status = 303, headers = { location = { "https://a.test/y" } } }
requests = {}
assert(http.request("https://a.test/s", { method = "POST", body = "q" }))
assert(requests[2].method == "GET" and requests[2].body == nil)

-- errors
script["https://a.test/loop"] = { status = 302, headers = { Location = { "https://a.test/loop" } } }
local none, why = http.request("https://a.test/loop")
assert(none == nil and why:find("too many redirects"))
none, why = http.request("https://nowhere.test/")
assert(none == nil and why:find("unknown host"))
script["https://a.test/r"] = { status = 200, pieces = { "a", "!" } }
none, why = http.request("https://a.test/r")
assert(none == nil and why:find("reset"))
script["https://a.test/slow"] = { status = 200, pieces = (function() local t = {} for i = 1, 100 do t[i] = "" end return t end)() }
none, why = http.request("https://a.test/slow", { timeout = 1 })
assert(none == nil and why:find("timed out"))
none, why = http.request("https://a.test/y", { device = "/dev/eth9" })
assert(none == nil and why:find("No such device"))
assert(opened == 0)

print("json/http tests passed")
