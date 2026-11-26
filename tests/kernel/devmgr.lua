-- devmgr: index-driven candidates, probe/attach, residency, teardown,
-- handles, subscribers. Run from the Nexus directory: lua tests/kernel/devmgr.lua
local function readSource(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local logs, signals, sigs = {}, {}, {}
local components, proxies = {}, {}
local current = { pid = 0, uid = 0, euid = 0, gid = 0, egid = 0 }
local groups = {
    { name = "root", gid = 0, members = { "root" } },
    { name = "chat", gid = 20, members = {} },
    { name = "taken", gid = 100, members = {} },
}
local users = {
    [0] = { username = "root", uid = 0 },
    [1000] = { username = "alice", uid = 1000 },
}
local devRoot = { children = {} }
local nodes = {}
local idx = { version = 2, abi = 1, modules = {} }
local mods, loaded, loads, unloads = {}, {}, {}, {}
local reindexes = 0
local env

local function hasLog(text)
    for _, l in ipairs(logs) do
        if l.msg:find(text, 1, true) then return true end
    end
    return false
end
local function lastSignal(name)
    for i = #signals, 1, -1 do
        if signals[i][1] == name then return signals[i] end
    end
end
local function stateOf(address)
    for _, e in ipairs(env.devmgr.list()) do
        if e.address == address then return e end
    end
end
local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do
        if v == value then n = n + 1 end
    end
    return n
end
local function contains(list, value)
    return count(list, value) > 0
end

-- drivers: code tables (what module.load hands back as mod.driver)
local lastInst
local detaches = 0
local chatboxDrv = {
    attach = function(dev)
        lastInst = { dev = dev, name = "box" }
        return lastInst
    end,
    detach = function() detaches = detaches + 1 end,
    ops = {
        say = function(inst, msg) return inst.dev.proxy.say(msg) end,
        status = function() return "ok" end,
        getName = function(inst) return inst.name end,
        setName = function(inst, n) inst.name = n; return true end,
        boom = function() error("kaboom") end,
        unlisted = function() return "nope" end,
    },
}

-- a module in the index: meta is the driver table of the entry, drv the code
local function define(name, meta, drv, needs)
    local depends = {}
    for i, n in ipairs(needs or {}) do depends[i] = { n } end
    idx.modules[name] = {
        path = "/usr/lib/modules/system/kernel/drivers/test/" .. name .. ".drv.lua",
        kind = "driver", desc = name, version = "0.1.0", version_n = 1, abi = 1, size = 1,
        depends = depends, driver = meta,
    }
    mods[name] = { driver = drv, needs = needs or {}, stubborn = name == "stubborn" }
end

env = setmetatable({
    printk = function(msg, level) logs[#logs + 1] = { msg = msg, level = level } end,
    panic = function(msg) error("PANIC: " .. msg, 0) end,
    checkArg = function(n, v, t)
        if type(v) ~= t then error("bad argument #" .. n, 2) end
    end,
    util = { copyTable = function(t)
        local c = {}
        for k, v in pairs(t) do c[k] = v end
        return c
    end },
    component = {
        list = function()
            local items = {}
            for address, ctype in pairs(components) do items[#items + 1] = { address, ctype } end
            local i = 0
            return function()
                i = i + 1
                if items[i] then return items[i][1], items[i][2] end
            end
        end,
        proxy = function(address)
            if not proxies[address] then
                proxies[address] = { address = address, say = function(msg) return "said " .. msg end }
            end
            return proxies[address]
        end,
        type = function(address) return components[address] end,
        slot = function() return 0 end,
    },
    computer = {
        uptime = function() return 42 end,
        pushSignal = function(...) signals[#signals + 1] = table.pack(...) end,
    },
    vfs = { resolve = function(path) return path end },
    vfsk = { lookup = function(path) return devRoot.children[path:match("^/dev/(.+)$")] end },
    devfs = {
        create = function(name, _, _, perm)
            if nodes[name] then return false, "Device already exists" end
            local vnode = { name = name, mode = perm, uid = 0, gid = 0 }
            nodes[name] = vnode
            devRoot.children[name] = vnode
            return true, nil, vnode
        end,
        exists = function(name) return nodes[name] ~= nil end,
        unregister = function(name)
            nodes[name] = nil
            devRoot.children[name] = nil
        end,
    },
    module = {
        index = function() return idx end,
        reindex = function()
            reindexes = reindexes + 1
            return true
        end,
        get = function(name) return loaded[name] end,
        load = function(name)
            local m = mods[name]
            if not m then return nil, name .. ": not found" end
            for _, dep in ipairs(m.needs) do
                if not mods[dep] then return nil, dep .. ": not found" end
            end
            if not loaded[name] then
                loaded[name] = { name = name, driver = m.driver }
                loads[#loads + 1] = name
            end
            return loaded[name]
        end,
        unload = function(name, _, opts)
            if not loaded[name] then return nil, name .. ": not loaded" end
            if mods[name].stubborn then return nil, "broken unload" end
            if env.devmgr.boundCount(name) > 0 then
                if not (opts and opts.force) then return nil, "in use by device" end
                env.devmgr.teardownDriver(name, "unload")
            end
            loaded[name] = nil
            unloads[#unloads + 1] = name
            return true
        end,
    },
    group = {
        getGroup = function(n)
            for _, g in ipairs(groups) do
                if g.name == n then return g end
            end
        end,
        getGroupByGID = function(gid)
            for _, g in ipairs(groups) do
                if g.gid == gid then return g end
            end
        end,
        create = function(name, gid)
            groups[#groups + 1] = { name = name, gid = gid, members = {} }
            return true
        end,
    },
    user = { getUserByUID = function(uid) return users[uid] end },
    process = {
        getCurrent = function() return current end,
        sendDevSignal = function(pid, reason, paths)
            sigs[#sigs + 1] = { pid = pid, reason = reason, paths = paths }
        end,
    },
    device = {},
}, { __index = _G })

assert(load(readSource("src/sec/permission.lua"), "@permission", "t", env))()
assert(load(readSource("src/dev/devmgr.lua"), "@devmgr", "t", env))()
local devmgr, devfs, device = env.devmgr, env.devfs, env.device

------------------------------------------------------------
-- empty index: init works, nothing binds, the note is logged
------------------------------------------------------------
assert(devmgr.init())
assert(hasLog("0 driver(s) indexed"))
assert(#devmgr.drivers() == 0)
components.c1 = "chat_box"
devmgr.coldplug()
assert(stateOf("c1").state == "unbound" and not devfs.exists("chat0"))

------------------------------------------------------------
-- index: priority order, probe nil/false/raise, attach nil/raise, deps
------------------------------------------------------------
define("chatbox", { match = { "chat_box" }, priority = 0, class = "chat", node = "chat", mode = 660,
    group = "chat", access = { say = "w", getName = "r", setName = "root", boom = "w", missing = "r", status = "open" } },
    chatboxDrv)
define("chatbox2", { match = { "chat_box" }, priority = 5, class = "chat", node = "chat", mode = 660,
    group = "chat", access = {} },
    { probe = function() return false end, attach = function() error("probe false must stop attach") end })
define("raiser", { match = { "probe_box" }, priority = 9, class = "test", node = "pb", mode = 600, access = {} },
    { probe = function() error("probe bug") end, attach = function() return {} end })
define("okprobe", { match = { "probe_box" }, priority = 1, class = "test", node = "pb", mode = 600, access = {} },
    { attach = function() return { ok = true } end })
define("broken", { match = { "broken_box" }, priority = 0, class = "test", node = "bk", mode = 600, access = {} },
    { attach = function() error("no hardware") end })
define("needy", { match = { "needy_box" }, priority = 0, class = "test", node = "nd", mode = 600, access = {} },
    { attach = function() return {} end }, { "netstack" })
define("ghost", { match = { "ghost_box" }, priority = 0, class = "test", node = "gh", mode = 600, access = {} },
    { attach = function() return nil end })
define("fakegpu", { match = { "gpu" }, priority = 0, class = "test", node = "fg", mode = 600, access = {} },
    { attach = function() error("core types are never attached") end })
define("stubborn", { match = { "stub_box" }, priority = 0, class = "test", node = "sb", mode = 600, access = {} },
    { attach = function() return nil end })

components.b1 = "broken_box"
components.g1 = "gpu"
components.n1 = "needy_box"
components.p1 = "probe_box"
components.x1 = "ghost_box"
components.u1 = "mystery"

devmgr.rescan()
assert(reindexes == 1, "rescan reloads the index")

local c1 = stateOf("c1")
assert(c1.state == "bound" and c1.driver == "chatbox" and c1.node == "chat0", "unbound device rebinds on rescan")
assert(devRoot.children.chat0.mode == 660 and devRoot.children.chat0.gid == 20, "node mode and group from the driver")
local attachSig
for _, s in ipairs(signals) do
    if s[1] == "device_attached" and s[2] == "c1" then attachSig = s end
end
assert(attachSig[2] == "c1" and attachSig[3] == "chat_box" and attachSig[4] == "chatbox" and attachSig[5] == "chat0")

local i2, i1
for i, n in ipairs(loads) do
    if n == "chatbox2" then i2 = i elseif n == "chatbox" then i1 = i end
end
assert(i2 and i1 and i2 < i1, "higher priority candidate is tried first")
assert(contains(unloads, "chatbox2") and env.module.get("chatbox2") == nil,
    "auto-loaded driver that bound nothing is unloaded")
assert(env.module.get("chatbox") ~= nil and not contains(unloads, "chatbox"))

assert(hasLog("raiser: probe failed for p1"), "a raising probe is logged")
local p1 = stateOf("p1")
assert(p1.state == "bound" and p1.driver == "okprobe" and p1.node == "pb0", "no probe means attach directly")
assert(contains(unloads, "raiser") and not contains(unloads, "okprobe"))

local b1 = stateOf("b1")
assert(b1.state == "failed" and b1.error:find("no hardware", 1, true), "attach raising fails the device")
assert(contains(unloads, "broken"))

assert(stateOf("n1").state == "failed" and stateOf("n1").error == "netstack: not found", "missing dependency")
assert(stateOf("x1").state == "unbound" and contains(unloads, "ghost"), "attach nil refuses")
assert(stateOf("u1").state == "unbound")
assert(devmgr.probe("g1", "gpu") == nil and not contains(loads, "fakegpu"), "core types are never probed")
assert(stateOf("g1") == nil)

------------------------------------------------------------
-- device.open / device.close / access values
------------------------------------------------------------
local grabbed = lastInst.dev
current = { pid = 5, uid = 1000, euid = 1000, gid = 1000, egid = 1000 }
assert(select(2, device.open("/dev/chat0", "w")) == "Permission denied", "other users are refused by 0660 root:chat")
groups[2].members = { "alice" }
local h = assert(device.open("/dev/chat0", "w"))
assert(h.say("hi") == "said hi")
assert(h.status() == "ok", "access 'open' is permitted for any open handle")
assert(h.getName == nil and h.setName == nil, "r and root ops are missing from a w handle")
assert(h.missing == nil and h.unlisted == nil, "ops outside the access table are not exposed")
assert(not pcall(function() h.say = nil end), "handles are read-only")
local hr = assert(device.open("/dev/chat0", "r"))
assert(hr.getName() == "box" and hr.status() == "ok" and hr.say == nil)
assert(device.open("/dev/nosuch", "r") == nil)
assert(device.open("/dev/chat0", "x") == nil)
current = { pid = 6, uid = 0, euid = 0, gid = 0, egid = 0 }
local hroot = assert(device.open("/dev/chat0", "rw"))
assert(hroot.setName("renamed") and hroot.getName() == "renamed", "root ops for root")

current = { pid = 5, uid = 1000, euid = 1000, gid = 1000, egid = 1000 }
assert(device.close(hr))
assert(select(2, hr.getName()) == "device removed", "closed handles stop working")
assert(device.close(hr) == nil)

------------------------------------------------------------
-- subscribers and hotplug add
------------------------------------------------------------
local events = {}
local token = devmgr.subscribe(function(ev, info)
    events[#events + 1] = ev .. ":" .. tostring(info.node)
end)
devmgr.subscribe(function() error("bad subscriber") end)
components.c2 = "chat_box"
devmgr.handleEvent("component_added", "c2", "chat_box")
assert(devfs.exists("chat1"), "second device gets the next node")
assert(events[1] == "attach:chat1", "subscribers get attach events")
assert(hasLog("subscriber failed"), "a raising subscriber is logged, not fatal")
assert(count(loads, "chatbox") == 1, "driver code is shared by instances")

------------------------------------------------------------
-- process exit reaps handles
------------------------------------------------------------
local h1 = assert(device.open("/dev/chat1", "w"))
devmgr.reap(5)
assert(select(2, h1.say("x")) == "device removed")
assert(select(2, h.say("x")) == "device removed")

------------------------------------------------------------
-- ops raising: failed teardown, SIGDEV once per holder, dead handles
------------------------------------------------------------
local h2a = assert(device.open("/dev/chat0", "w"))
local h2b = assert(device.open("/dev/chat0", "r"))
local sigFrom = #sigs
local detachesBefore = detaches
local r, err = h2a.boom()
assert(r == nil and err == "device error")
assert(not devfs.exists("chat0"), "failed device loses its node")
local st = stateOf("c1")
assert(st.state == "failed" and st.error:find("kaboom", 1, true))
assert(detaches == detachesBefore + 1, "detach runs on failure")
assert(select(2, h2b.getName()) == "device removed")
assert(select(2, hroot.getName()) == "device removed", "every handle of the device is revoked")
assert(select(2, h2a.say("x")) == "device removed")

local newSigs = {}
for i = sigFrom + 1, #sigs do newSigs[#newSigs + 1] = sigs[i] end
assert(#newSigs == 2, "one SIGDEV per process holding a handle")
local byPid = {}
for _, s in ipairs(newSigs) do byPid[s.pid] = s end
assert(byPid[5].reason == "failed" and #byPid[5].paths == 1 and byPid[5].paths[1] == "/dev/chat0")
assert(byPid[6].reason == "failed")
local dd = lastSignal("device_detached")
assert(dd[2] == "c1" and dd[4] == "chatbox" and dd[5] == "chat0" and dd[6] == "failed")
assert(events[#events] == "detach:chat0", "subscribers get detach events")
assert(env.devmgr.boundCount("chatbox") == 1, "driver stays resident, c2 still bound")
assert(env.module.get("chatbox") ~= nil)

assert(not pcall(function() return grabbed.proxy.say("x") end), "dev.proxy dies with the binding")
assert(select(2, pcall(function() return grabbed.proxy.say("x") end)):find("device removed", 1, true))
assert(not pcall(function() grabbed.pushSignal("x") end))

------------------------------------------------------------
-- manual bind / unbind, admin wrappers need root
------------------------------------------------------------
assert(devmgr.bind("c1"), "manual bind")
assert(devfs.exists("chat0"))
assert(select(2, devmgr.bind("c1")) == "already bound")
assert(devmgr.unbind("c1"))
assert(select(2, devmgr.bind("c1", "fakegpu")) == "driver does not match chat_box")
assert(select(2, devmgr.bind("c1", "nosuch")) == "no such driver")
assert(devmgr.bind("c1") and devfs.exists("chat0"))

current = { pid = 7, uid = 1000, euid = 1000, gid = 1000, egid = 1000 }
assert(select(2, device.bind("c3")) == "Permission denied")
assert(select(2, device.unbind("c2")) == "Permission denied")
assert(select(2, device.rescan()) == "Permission denied")
assert(#device.bindings() > 0 and #device.drivers() > 0, "listing is open to everyone")

current = { pid = 0, uid = 0, euid = 0, gid = 0, egid = 0 }
assert(device.unbind("c2") == true)
assert(not devfs.exists("chat1"), "unbind frees the node")
assert(stateOf("c2").state == "unbound" and stateOf("c2").driver == nil)
assert(lastSignal("device_detached")[6] == "removed")
assert(select(2, device.unbind("c2")) == "not bound")

------------------------------------------------------------
-- hot removal keeps the driver resident; re-add reuses the node
------------------------------------------------------------
components.c1 = nil
devmgr.handleEvent("component_removed", "c1")
assert(stateOf("c1") == nil and not devfs.exists("chat0"))
assert(env.module.get("chatbox") ~= nil and not contains(unloads, "chatbox"), "bound drivers stay resident")
components.c3 = "chat_box"
devmgr.handleEvent("component_added", "c3", "chat_box")
assert(devfs.exists("chat0"), "lowest free node is reused")
assert(count(loads, "chatbox") == 1)

------------------------------------------------------------
-- forced unload tears devices down with SIGDEV reason "unload"
------------------------------------------------------------
current = { pid = 5, uid = 1000, euid = 1000, gid = 1000, egid = 1000 }
local h3 = assert(device.open("/dev/chat0", "w"))
sigFrom = #sigs
local ok, uerr = env.module.unload("chatbox", true)
assert(ok == nil and uerr == "in use by device")
assert(env.module.unload("chatbox", true, { force = true }) == true)
local us = sigs[sigFrom + 1]
assert(us and us.pid == 5 and us.reason == "unload" and us.paths[1] == "/dev/chat0")
assert(select(2, h3.say("x")) == "device removed")
assert(stateOf("c3").state == "unbound" and not devfs.exists("chat0"))
assert(env.module.get("chatbox") == nil and env.devmgr.boundCount("chatbox") == 0)

------------------------------------------------------------
-- drivers() and list() output; teardownDriver API
------------------------------------------------------------
current = { pid = 0, uid = 0, euid = 0, gid = 0, egid = 0 }
assert(device.bind("c3") == true, "admin bind as root")
local drvs = {}
for _, d in ipairs(devmgr.drivers()) do drvs[d.name] = d end
assert(drvs.chatbox.loaded == true and drvs.chatbox.bound == 1)
assert(drvs.chatbox.match[1] == "chat_box" and drvs.chatbox.node == "chat" and drvs.chatbox.mode == 660)
assert(drvs.chatbox.access.say == "w" and drvs.chatbox.priority == 0)
assert(drvs.chatbox2.loaded == false and drvs.chatbox2.bound == 0)
assert(devmgr.drivers()[1].name == "raiser", "drivers are listed by priority")
local c3entry = stateOf("c3")
assert(c3entry.type == "chat_box" and c3entry.driver == "chatbox" and c3entry.node == "chat0" and c3entry.state == "bound")

assert(device.open("/dev/pb0", "r"))
sigFrom = #sigs
assert(devmgr.teardownDriver("okprobe", "unload") == 1)
assert(sigs[sigFrom + 1].reason == "unload" and sigs[sigFrom + 1].pid == 0)
assert(stateOf("p1").state == "unbound" and not devfs.exists("pb0"))
assert(env.module.get("okprobe") ~= nil, "teardownDriver does not unload the module")
assert(select(2, devmgr.teardownDriver("okprobe", "bogus")) == "bad reason")

------------------------------------------------------------
-- resident subscribers: unsubscribe stops events
------------------------------------------------------------
devmgr.unsubscribe(token)
local before = #events
components.c4 = "chat_box"
devmgr.handleEvent("component_added", "c4", "chat_box")
assert(#events == before, "unsubscribed callbacks get nothing")

------------------------------------------------------------
-- an unload that fails for a reason other than "in use" is a kernel panic
------------------------------------------------------------
components.s1 = "stub_box"
local okP, perr = pcall(devmgr.handleEvent, "component_added", "s1", "stub_box")
assert(not okP and tostring(perr):find("cannot unload stubborn", 1, true), "bad unload panics")

print("devmgr tests passed")
