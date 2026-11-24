-- devmgr: index, probe/release, sandbox, device.open/close, failures.
-- Run from the Nexus directory: lua tests/devmgr.lua
local function readSource(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local files = {}
local logs = {}
local signals = {}
local components = {}
local proxies = {}
local loadCount = {}
local modules = { sound = { beep = function() return "beep" end } }
local current = { pid = 0, uid = 0, euid = 0, gid = 0, egid = 0 }
local groups = {
    { name = "root", gid = 0, members = { "root" } },
    { name = "chat", gid = 20, members = {} },
    { name = "taken", gid = 100, members = {} },
}
local users = { [0] = { name = "root" }, [1000] = { name = "alice" }, [1001] = { name = "bob" } }

local devRoot = { children = {} }
local env
env = setmetatable({
    printk = function(msg) logs[#logs + 1] = msg end,
    component = {
        list = function()
            local k
            return function()
                local addr, t = next(components, k)
                k = addr
                return addr, t
            end
        end,
        proxy = function(addr)
            proxies[addr] = proxies[addr] or { address = addr, say = function(msg) return "said " .. msg end }
            return proxies[addr]
        end,
        type = function(addr) return components[addr] end,
    },
    computer = {
        uptime = function() return 42 end,
        pushSignal = function(...) signals[#signals + 1] = table.pack(...) end,
    },
    util = { copyTable = function(t)
        local c = {}
        for k, v in pairs(t) do c[k] = v end
        return c
    end },
    vfs = {
        open = function(path)
            local data = files[path]
            if not data then return nil, "No such file or directory" end
            return { readAll = function() return data end, close = function() end }
        end,
        resolve = function(p) return p end,
    },
    vfsk = {
        createVNode = function(path, name, kind, fs, mode)
            assert(path == "/dev" and devRoot.children[name] == nil)
            local node = { name = name, hash = name, type = kind, mode = mode, fs = fs, parent = devRoot, uid = 0, gid = 0 }
            devRoot.children[name] = node
            return node
        end,
        lookup = function(path) return devRoot.children[path:match("^/dev/(.+)$")] end,
    },
    loadfile = function(path, mode, e)
        local data = files[path]
        if not data then return nil, path .. ": not found" end
        loadCount[path] = (loadCount[path] or 0) + 1
        return load(data, "=" .. path, mode, e)
    end,
    module = {
        exists = function(n) return modules[n] ~= nil end,
        require = function(n) return modules[n] end,
    },
    group = {
        getGroup = function(n) for _, g in ipairs(groups) do if g.name == n then return g end end end,
        getGroupByGID = function(gid) for _, g in ipairs(groups) do if g.gid == gid then return g end end end,
        create = function(name, gid)
            groups[#groups + 1] = { name = name, gid = gid, members = {} }
            return true
        end,
    },
    user = { getUserByUID = function(uid) return users[uid] end },
    process = { getCurrent = function() return current end },
    checkArg = function(_, v, t) assert(type(v) == t, "bad argument") end,
}, { __index = _G })

local source = table.concat({
    readSource("src/permission.lua"),
    "\nlocal devfs = {}\n",
    -- devfs.lua declares a global; keep it inside the chunk
    (readSource("src/devfs.lua"):gsub("^devfs = {}", "")),
    -- devfs.lua declares `local module`; module.lua fills it in the kernel
    "\nmodule = _ENV.module\n",
    "\nlocal device = {}\n",
    readSource("src/devmgr.lua"),
    "\nreturn devmgr, device, devfs",
}, "\n")
local devmgr, device, devfs = assert(load(source, "@devmgr", "t", env))()

local function lastSignal(name)
    for i = #signals, 1, -1 do
        if signals[i][1] == name then return signals[i] end
    end
end
local function hasLog(pat)
    for _, l in ipairs(logs) do if l:find(pat) then return true end end
    return false
end

------------------------------------------------------------
-- no index: nothing binds, a note is logged
------------------------------------------------------------
assert(devmgr.init() == nil)
assert(hasLog("no driver index"), "missing index must be logged")
components.c1 = "chat_box"
devmgr.coldplug()
assert(devfs.exists("chat0") == false)

------------------------------------------------------------
-- index with a duplicate match and a core-type driver
------------------------------------------------------------
files["/usr/lib/drivers/drivers.idx"] = [[
return { version = 1, drivers = {
    { name = "chatbox", path = "/usr/lib/drivers/chatbox.lua", match = { "chat_box" },
      depends = { "sound" }, node = "chat", mode = 660, group = "chat",
      access = { say = "w", getName = "r", setName = "root", boom = "w", missing = "r" } },
    { name = "chatbox2", path = "/usr/lib/drivers/chatbox2.lua", match = { "chat_box" } },
    { name = "fakegpu", path = "/usr/lib/drivers/fakegpu.lua", match = { "gpu" } },
    { name = "broken", path = "/usr/lib/drivers/broken.lua", match = { "broken_box" } },
    { name = "needy", path = "/usr/lib/drivers/needy.lua", match = { "needy_box" }, depends = { "netstack" } },
}}
]]
files["/usr/lib/drivers/chatbox.lua"] = [[
local driver = {}
driver.info = { match = { "chat_box" } }
probe = {
    component = component, vfs = vfs, printk = printk, process = process,
    pushSignal = computer.pushSignal, uptime = computer.uptime(),
    sound = require("sound").beep(),
}
probe.undeclared = select(2, pcall(require, "netstack"))
function driver.attach(dev)
    log("attach", dev.address)
    probe.proxyOk = dev.proxy.address == dev.address
    probe.setProxy = pcall(function() dev.proxy2 = 1 end)
    return { dev = dev, name = "box" }
end
function driver.detach(inst) inst.detached = true; probe.detached = (probe.detached or 0) + 1 end
driver.ops = {}
function driver.ops.say(inst, msg) return inst.dev.proxy.say(msg) end
function driver.ops.getName(inst) return inst.name end
function driver.ops.setName(inst, n) inst.name = n; return true end
function driver.ops.boom(inst) error("kaboom") end
function driver.ops.unlisted(inst) return "nope" end
return driver
]]
files["/usr/lib/drivers/broken.lua"] = [[
return { attach = function() error("no hardware") end }
]]
files["/usr/lib/drivers/needy.lua"] = [[
return { attach = function() return {} end }
]]

assert(devmgr.rescan())
assert(devfs.exists("chat0"), "coldplug binds existing devices")
local node = devRoot.children.chat0
assert(node.mode == 660 and node.gid == 20, "node mode and group come from the driver")
local s = lastSignal("device_attached")
assert(s[2] == "c1" and s[3] == "chat_box" and s[4] == "chatbox" and s[5] == "chat0")
assert(loadCount["/usr/lib/drivers/chatbox2.lua"] == nil, "first match in index order wins")
assert(loadCount["/usr/lib/drivers/chatbox.lua"] == 1)
assert(hasLog("^chatbox: attach c1"), "driver log goes to klog with its name")

local list = devmgr.list()
assert(#list == 1 and list[1].state == "bound" and list[1].node == "chat0")

-- core types are never probed
components.g1 = "gpu"
assert(devmgr.probe("g1", "gpu") == nil)
assert(loadCount["/usr/lib/drivers/fakegpu.lua"] == nil)

-- second device: attach only, code loaded once
components.c2 = "chat_box"
devmgr.handleEvent("component_added", "c2", "chat_box")
assert(devfs.exists("chat1"))
assert(loadCount["/usr/lib/drivers/chatbox.lua"] == 1, "driver code is shared between instances")

------------------------------------------------------------
-- sandbox contents: a spy driver reports what it can see
------------------------------------------------------------
files["/usr/lib/drivers/spy.lua"] = [[
    local spy = {
        component = component, vfs = vfs, printk = printk, process = process,
        kernelDevice = device, devmgr = devmgr, loadfile = loadfile, load = load,
        pushSignal = computer.pushSignal, uptime = computer.uptime(),
        devfsCreate = devfs.create, devfsExists = devfs.exists ~= nil,
        sound = select(2, pcall(require, "sound")),
        undeclared = select(2, pcall(require, "netstack")),
    }
    string.evil = true
    return { attach = function(dev)
        spy.proxyOk = dev.proxy.address == dev.address
        spy.writeDev = pcall(function() dev.x = 1 end)
        dev.emit("spy_report", spy)
        return spy
    end }
]]
files["/usr/lib/drivers/drivers.idx"] = files["/usr/lib/drivers/drivers.idx"]:gsub(
    "}}\n$", "{ name = \"spy\", path = \"/usr/lib/drivers/spy.lua\", match = { \"spy_box\" }, depends = { \"sound\" }, node = \"spy\", mode = 640, group = \"spies\" },\n}}\n")
assert(devmgr.rescan())
components.s1 = "spy_box"
devmgr.handleEvent("component_added", "s1", "spy_box")
local report = assert(lastSignal("spy_report"), "dev.emit pushes a signal")
assert(report[2] == "s1", "emitted signals carry the device address")
local spy = report[3]
assert(spy.component == nil and spy.vfs == nil and spy.printk == nil and spy.process == nil)
assert(spy.kernelDevice == nil and spy.devmgr == nil and spy.loadfile == nil and spy.load == nil)
assert(spy.pushSignal == nil and spy.uptime == 42, "computer exposes uptime only")
assert(spy.devfsCreate == nil and spy.devfsExists)
assert(spy.sound == modules.sound, "declared modules can be required")
assert(tostring(spy.undeclared):find("not declared"), "undeclared modules are refused")
assert(spy.proxyOk and spy.writeDev == false)
assert(string.evil == nil, "drivers cannot modify the shared string library")
local spiesGroup = groups[#groups]
assert(spiesGroup.name == "spies" and spiesGroup.gid == 101, "missing groups are created with the lowest free system gid")
assert(devRoot.children.spy0.gid == 101 and devRoot.children.spy0.mode == 640)

------------------------------------------------------------
-- device.open / device.close
------------------------------------------------------------
current = { pid = 5, uid = 1000, euid = 1000, gid = 1000, egid = 1000 }
local h, e = device.open("/dev/chat0", "w")
assert(h == nil and e == "Permission denied", "other users are refused by 0660 root:chat")
groups[2].members = { "alice" }
h = assert(device.open("/dev/chat0", "w"))
assert(h.say("hi") == "said hi")
assert(h.getName == nil, "r op missing from a w handle")
assert(h.setName == nil, "root op missing for non-root")
assert(h.unlisted == nil and h.missing == nil, "ops outside info.access are not exposed")
assert(not pcall(function() h.say = nil end), "handles are read-only")
local hr = assert(device.open("/dev/chat0", "r"))
assert(hr.getName() == "box" and hr.say == nil)
assert(device.open("/dev/nosuch", "r") == nil)
assert(device.open("/dev/chat0", "x") == nil)

current = { pid = 6, uid = 0, euid = 0, gid = 0, egid = 0 }
local hroot = assert(device.open("/dev/chat0", "rw"))
assert(hroot.setName("renamed") and hroot.getName() == "renamed")

-- close
current = { pid = 5, uid = 1000, euid = 1000, gid = 1000, egid = 1000 }
assert(device.close(hr))
assert(select(2, hr.getName()) == "device removed", "closed handles stop working")
assert(device.close(hr) == nil)

-- process exit reaps handles
local h1 = assert(device.open("/dev/chat1", "w"))
devmgr.reap(5)
assert(select(2, h1.say("x")) == "device removed")
assert(select(2, h.say("x")) == "device removed")

------------------------------------------------------------
-- op exception detaches the device
------------------------------------------------------------
h = assert(device.open("/dev/chat0", "w"))
local r, err = h.boom()
assert(r == nil and err == "device error")
assert(not devfs.exists("chat0"), "failed device loses its node")
assert(select(2, h.say("x")) == "device removed")
assert(select(2, hroot.getName()) == "device removed", "every handle of the device is revoked")
local st
for _, e2 in ipairs(devmgr.list()) do if e2.address == "c1" then st = e2 end end
assert(st.state == "failed" and st.error:find("kaboom"))
s = lastSignal("device_detached")
assert(s[2] == "c1" and s[4] == "chatbox" and s[5] == "chat0")

-- manual rebind gets the lowest free node again
current = { pid = 0, uid = 0, euid = 0, gid = 0, egid = 0 }
assert(devmgr.bind("c1"))
assert(devfs.exists("chat0"))
assert(devmgr.bind("c1") == nil, "already bound")
assert(devmgr.bind("c1", "fakegpu") == nil)

------------------------------------------------------------
-- removal; code is freed when the last instance goes
------------------------------------------------------------
devmgr.handleEvent("component_removed", "c1")
devmgr.handleEvent("component_removed", "c2")
assert(not devfs.exists("chat0") and not devfs.exists("chat1"))
components.c1, components.c2 = nil, nil
components.c3 = "chat_box"
devmgr.handleEvent("component_added", "c3", "chat_box")
assert(loadCount["/usr/lib/drivers/chatbox.lua"] == 2, "code reloaded after all instances went away")
assert(devfs.exists("chat0"))

-- unbind
assert(devmgr.unbind("c3"))
assert(not devfs.exists("chat0"))
assert(devmgr.unbind("c3") == nil)

------------------------------------------------------------
-- attach failure, missing module
------------------------------------------------------------
components.b1 = "broken_box"
devmgr.handleEvent("component_added", "b1", "broken_box")
components.n1 = "needy_box"
devmgr.handleEvent("component_added", "n1", "needy_box")
local states = {}
for _, e2 in ipairs(devmgr.list()) do states[e2.address] = e2 end
assert(states.b1.state == "failed" and states.b1.error:find("no hardware"))
assert(states.n1.state == "failed" and states.n1.error:find("netstack"))
assert(loadCount["/usr/lib/drivers/needy.lua"] == nil, "missing module stops loading before code runs")

-- unknown type stays unbound
components.u1 = "mystery"
devmgr.handleEvent("component_added", "u1", "mystery")
for _, e2 in ipairs(devmgr.list()) do states[e2.address] = e2 end
assert(states.u1.state == "unbound")

-- driver listing
local names = {}
for _, d in ipairs(devmgr.drivers()) do names[d.name] = d end
assert(names.chatbox and not names.chatbox.loaded and names.spy.loaded)

print("devmgr tests passed")
