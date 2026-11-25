-- Tests for src/debugcon.lua (kernel debug consoles) with src/klog.lua.
-- Run from nexus/: lua tests/debugcon.lua
local function read(path)
    local f = assert(io.open(path, "r"))
    local v = f:read("a")
    f:close()
    return v
end
local source = read("src/klog.lua") .. "\n" .. read("src/debugcon.lua")

local function system(opts)
    opts = opts or {}
    local now = 0
    local components = opts.components or {}   -- address -> type
    local calls = {}                            -- { address, method, arg }
    local sockets = {}
    local env
    env = setmetatable({
        config = { debug_console = opts.config },
        getRealTime = function() return 0 end,
        computer = { uptime = function() return now end },
        component = {
            list = function(kind, exact)
                local keys = {}
                for address, t in pairs(components) do
                    if t == kind then keys[#keys + 1] = address end
                end
                table.sort(keys)
                local i = 0
                return function() i = i + 1 return keys[i] end
            end,
            invoke = function(address, method, ...)
                assert(components[address], "no component " .. address)
                if opts.fail and opts.fail[address] then error("component gone") end
                if method == "connect" then
                    local s = { host = ..., port = select(2, ...), sent = {}, ready = opts.connectAfter or 0 }
                    sockets[#sockets + 1] = s
                    s.finishConnect = function()
                        if s.refuse then error("connection refused") end
                        s.ready = s.ready - 1
                        return s.ready < 0
                    end
                    s.write = function(data)
                        if s.broken then error("connection lost") end
                        local n = math.min(#data, s.limit or #data)
                        s.sent[#s.sent + 1] = data:sub(1, n)
                        return n
                    end
                    s.close = function() s.closed = true end
                    return s
                end
                calls[#calls + 1] = { address, method, (...) }
            end,
        },
        printk = function(msg, level) env.klog.record(level or "info", "kernel", msg) end,
    }, { __index = _G })
    assert(load(source, "=debugcon", "t", env))()
    return {
        env = env, calls = calls, sockets = sockets, components = components,
        log = function(msg, level, tag, pid) env.klog.record(level or "info", tag or "kernel", msg, pid) end,
        advance = function(dt) now = now + dt end,
        setTime = function(t) now = t end,
    }
end

local function texts(calls, address)
    local out = {}
    for _, c in ipairs(calls) do
        if c[1] == address then out[#out + 1] = c[3] end
    end
    return out
end

-- 1. Consoles present at probe get the boot lines so far, then each line.
local s = system({ components = { oc1 = "ocelot", ser = "serial", gpu = "gpu" } })
s.log("Nexus version 0.0.7")
s.advance(1.25)
s.log("device list", "debug")
s.env.debugcon.probe()
local oc = texts(s.calls, "oc1")
assert(#oc == 2, "replayed per line: " .. #oc)
assert(oc[1] == "[    0.00] info    kernel: Nexus version 0.0.7", oc[1])
assert(oc[2]:find("debug   kernel: device list", 1, true))
local ser = texts(s.calls, "ser")
assert(#ser == 1 and ser[1]:find("Nexus version 0.0.7\n", 1, true) and ser[1]:sub(-1) == "\n",
    "serial gets one write with newlines")
s.log("from a process", "notice", "sh", 12)
oc = texts(s.calls, "oc1")
assert(oc[3] == "[    1.25] notice  sh[12]: from a process", oc[3])
assert(texts(s.calls, "ser")[2] == "[    1.25] notice  sh[12]: from a process\n")
assert(#texts(s.calls, "gpu") == 0)
assert(table.concat(s.env.debugcon.list(), ",") == "ocelot oc1,serial ser")

-- 2. Level filter and disabled kinds.
s = system({ components = { oc1 = "ocelot", ser = "serial" }, config = { level = "warning", serial = false } })
s.env.debugcon.probe()
s.log("chatty", "info")
s.log("careful", "warning")
s.log("broken", "err")
oc = texts(s.calls, "oc1")
assert(#oc == 2 and oc[1]:find("careful", 1, true) and oc[2]:find("broken", 1, true))
assert(#texts(s.calls, "ser") == 0, "serial = false")
s = system({ components = { oc1 = "ocelot" }, config = false })
s.env.debugcon.probe()
s.log("nothing")
assert(#s.calls == 0, "debug_console = false turns all off")

-- 3. A failing console is dropped once, with a warning in klog (not sent to
--    itself again), and the others keep working.
s = system({ components = { oc1 = "ocelot", ser = "serial" }, fail = { ser = true } })
s.log("boot")
s.env.debugcon.probe()
local entries = s.env.klog.read(0)
assert(entries[#entries].msg:find("debugcon: serial dropped", 1, true), entries[#entries].msg)
s.log("after")
oc = texts(s.calls, "oc1")
assert(oc[#oc]:find("after", 1, true))
assert(oc[#oc - 1]:find("debugcon: serial dropped", 1, true), "the warning reaches the working console")
assert(table.concat(s.env.debugcon.list(), ",") == "ocelot oc1")

-- 4. Hotplug: a card added later gets the ring first; removal stops output.
s = system({ components = {} })
s.env.debugcon.probe()
s.log("early")
s.components.oc2 = "ocelot"
s.env.debugcon.handleEvent("component_added", "oc2", "ocelot")
s.log("later")
oc = texts(s.calls, "oc2")
assert(#oc == 2 and oc[1]:find("early", 1, true) and oc[2]:find("later", 1, true))
s.env.debugcon.handleEvent("component_removed", "oc2", "ocelot")
s.log("gone")
assert(#texts(s.calls, "oc2") == 2)

-- 5. TCP: connect through the internet card, replay the ring once up, send
--    what is buffered (partial writes too), reconnect after a loss.
s = system({ components = { inet = "internet" }, config = { tcp = "127.0.0.1:7777" }, connectAfter = 1 })
s.log("boot line")
s.env.debugcon.probe()
s.env.debugcon.tick()                       -- connect, not ready yet
assert(#s.sockets == 1 and s.sockets[1].host == "127.0.0.1" and s.sockets[1].port == 7777)
assert(#s.sockets[1].sent == 0)
s.log("while connecting")                   -- in the ring, sent with the replay
s.env.debugcon.tick()                       -- connected: replay and send
local sent = table.concat(s.sockets[1].sent)
assert(sent:find("boot line\n", 1, true) and sent:find("while connecting\n", 1, true), sent)
s.sockets[1].limit = 10
s.log("a longer line that needs more than one write")
s.env.debugcon.tick()
assert(table.concat(s.sockets[1].sent):find("a longer line that needs more than one write\n", 1, true),
    "partial writes are continued in the same pass")
s.sockets[1].broken = true
s.log("lost")
s.env.debugcon.tick()
assert(s.sockets[1].closed)
s.env.debugcon.tick()
assert(#s.sockets == 1, "no reconnect before the retry delay")
s.advance(s.env.debugcon.TCP_RETRY)
s.env.debugcon.tick()
s.env.debugcon.tick()
assert(#s.sockets == 2)
sent = table.concat(s.sockets[2].sent)
assert(sent:find("tcp 127.0.0.1:7777 lost: ", 1, true) and sent:find("connection lost", 1, true),
    "the loss is logged and replayed")
assert(sent:find("lost\n", 1, true))

-- 6. Refused connections retry; a bad target is reported; flush gives up.
s = system({ components = { inet = "internet" }, config = { tcp = "localhost:9" }, connectAfter = 3 })
s.env.debugcon.probe()
s.env.debugcon.tick()
s.sockets[1].refuse = true
s.env.debugcon.tick()
assert(s.sockets[1].closed)
s = system({ components = { inet = "internet" }, config = { tcp = "10.0.0.1:7777" }, connectAfter = 1e9 })
s.env.debugcon.probe()
s.env.debugcon.tick()
s.advance(s.env.debugcon.TCP_CONNECT_TIMEOUT)
s.env.debugcon.tick()
assert(s.sockets[1].closed, "a connection that never comes up times out")
entries = s.env.klog.read(0)
assert(entries[#entries].msg:find("no connection", 1, true), entries[#entries].msg)
s.env.debugcon.tick()
s.advance(s.env.debugcon.TCP_RETRY)
s.env.debugcon.tick()
s.advance(s.env.debugcon.TCP_CONNECT_TIMEOUT)
s.env.debugcon.tick()
assert(#s.sockets == 2)
local warnings = 0
for _, e in ipairs(s.env.klog.read(0)) do
    if e.msg:find("no connection", 1, true) then warnings = warnings + 1 end
end
assert(warnings == 1, "the same failure is logged once: " .. warnings)
s = system({ components = { inet = "internet" }, config = { tcp = "no-port" } })
s.env.debugcon.probe()
entries = s.env.klog.read(0)
assert(entries[#entries].msg:find("bad tcp target", 1, true))
s = system({ components = {}, config = { tcp = "127.0.0.1:7777" } })
s.env.debugcon.probe()
s.env.debugcon.flush(0.5)                   -- no internet card: returns at the deadline
assert(#s.sockets == 0)

print("debugcon tests passed")
