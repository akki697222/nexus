-- Module loader: modules.idx lookup, dependencies, version, ABI and cycle
-- checks, trust, unload refusals, dry runs and driver file rules. The
-- kernel's module.lua runs against stubs for the rest of the kernel.
-- Run from the Nexus directory: lua tests/kernel/module_loader.lua
local kernel = dofile("tests/lib/kernel.lua")

local logs = {}        -- printk lines
local order = {}       -- load / unload calls, in order
local files = {}       -- path -> { src, uid, mode }
local dirAttr = {}     -- directory path -> { uid, mode }
local idx = { version = 2, abi = 1, modules = {} }
local DIR_ATTR = { uid = 0, mode = 755 }
local bound = {}       -- driver name -> bound device count
local torn = {}        -- teardownDriver calls

LOG = order
printk = function(msg) logs[#logs + 1] = tostring(msg) end
panic = function(err, reason) error("PANIC " .. tostring(err) .. ": " .. tostring(reason), 0) end
process = { current = -1 }
vfs = {
    resolve = function(p) return p end,
    attributes = function(p)
        local f = files[p]
        if f then
            return { uid = f.uid or 0, mode = f.mode or 644, size = #f.src }
        end
        return dirAttr[p] or DIR_ATTR
    end,
}
createModuleEnv = function() return setmetatable({}, { __index = _G }) end
loadfile = function(path, mode, env)
    if path == "/usr/lib/modules/modules.idx" then
        return function() return idx end
    end
    local f = files[path]
    if not f then return nil, path .. ": No such file or directory" end
    return load(f.src, "=" .. path, "t", env)
end

local chunk = assert(load(kernel.read("module"), "=module.lua", "t"))
chunk()

local function joined(t) return table.concat(t, ",") end

-- calls fn(...) and checks it returned nil and the error text
local function expectErr(want, fn, ...)
    local ok, err = fn(...)
    assert(ok == nil and err == want, "expected nil, " .. want .. "; got " .. tostring(ok) .. ", " .. tostring(err))
end

-- a module or driver source; `o.driver` gives it a driver table
local function source(name, o)
    local deps = {}
    for i, d in ipairs(o.depends or {}) do
        if type(d) == "table" then
            deps[i] = string.format("{ %q, %d }", d[1], d[2])
        else
            deps[i] = string.format("%q", d)
        end
    end
    local driver = ""
    if o.driver then
        driver = 'driver = { match = { "internet" }, priority = 0, class = "network", '
            .. 'node = "eth", mode = 660, group = "ethernet", access = {} },'
    end
    return string.format([[
return {
    manifest = { name = %q, desc = "test", version = "0.1.0", version_n = %d, abi = %s, depends = { %s } },
    load = function() LOG[#LOG + 1] = "load %s" end,
    unload = function() LOG[#LOG + 1] = "unload %s" end,
    module = {},
    %s
}
]], name, o.version_n or 1, tostring(o.abi), table.concat(deps, ", "), name, name, driver)
end

-- writes a file and its index entry; returns the path
local function def(name, o)
    o = o or {}
    local kind = o.driver and "driver" or "module"
    local dir = o.dir or (kind == "driver"
        and "/usr/lib/modules/system/kernel/drivers/net/"
        or "/usr/lib/modules/system/kernel/")
    local path = dir .. name .. (kind == "driver" and ".drv.lua" or ".lua")
    local src = source(name, o)
    files[path] = { src = src, uid = o.uid, mode = o.mode }
    local deps = {}
    for i, d in ipairs(o.depends or {}) do
        deps[i] = type(d) == "table" and d or { d }
    end
    local entry = { path = path, kind = kind, desc = "test", version = "0.1.0",
        version_n = o.version_n or 1, abi = o.abi, size = #src, depends = deps }
    if kind == "driver" then
        entry.driver = { match = { "internet" }, priority = 0, class = "network",
            node = "eth", mode = 660, group = "ethernet", access = {} }
    end
    idx.modules[name] = entry
    return path
end

local function state(name)
    for _, m in ipairs(module.list()) do
        if m.name == name then return m.state end
    end
end

-- graph: top -> mid (needs base) -> base
def("base", { version_n = 1 })
def("mid", { version_n = 2, depends = { "base" } })
def("top", { depends = { { "mid", 2 } } })

------------------------------------------------------------
-- dry run: the order, nothing loaded
------------------------------------------------------------
local plan = assert(module.load("top", true, { dryRun = true }))
assert(joined(plan) == "base,mid,top", joined(plan))
assert(not module.exists("base") and not module.exists("top") and #order == 0)

------------------------------------------------------------
-- load by name: dependencies first, auto-loaded ones marked as such
------------------------------------------------------------
local top = assert(module.load("top", true))
assert(joined(order) == "load base,load mid,load top", joined(order))
assert(module.get("top") == top and module.require("top") ~= nil)
assert(module.entry("base").auto == true and module.entry("top").auto == false)
assert(joined(module.entry("base").usedBy) == "mid")
assert(module.load("top", true) == top and #order == 3, "loaded returns the module")

def("solo")
assert(state("solo") == "available" and state("top") == "loaded")

------------------------------------------------------------
-- in use by: a module something loads cannot go, and nothing is unloaded
------------------------------------------------------------
expectErr("in use by top", module.unload, "mid", true)
expectErr("in use by mid", module.unload, "base", true)
assert(module.exists("base") and module.exists("mid") and #order == 3)

-- dry run of a recursive unload: deepest-first order, nothing unloaded
local uplan = assert(module.unload("top", true, { recursive = true, dryRun = true }))
assert(joined(uplan) == "top,mid,base", joined(uplan))
assert(module.exists("top") and module.exists("base") and #order == 3)

assert(module.unload("top", true, { recursive = true }))
assert(joined(order) == "load base,load mid,load top,unload top,unload mid,unload base", joined(order))
assert(not module.exists("top") and not module.exists("mid") and not module.exists("base"))
expectErr("Unknown module", module.unload, "top", true)

------------------------------------------------------------
-- version requirement: the dependency is too old, nothing is loaded
------------------------------------------------------------
def("need", { depends = { { "mid", 3 } } })
expectErr("mid: version 3 required", module.load, "need", true)
assert(not module.exists("mid") and not module.exists("need"))

------------------------------------------------------------
-- missing dependency
------------------------------------------------------------
def("orphan", { depends = { "ghost" } })
expectErr("ghost: not found", module.load, "orphan", true)

------------------------------------------------------------
-- circular dependency: refused before any load() runs
------------------------------------------------------------
def("c1", { depends = { "c2" } })
def("c2", { depends = { "c1" } })
local before = #order
expectErr("circular dependency: c1 -> c2 -> c1", module.load, "c1", true)
assert(#order == before and not module.exists("c1") and not module.exists("c2"))
local dryOrder, dryErr = module.load("c1", true, { dryRun = true })
assert(dryOrder == nil and dryErr == "circular dependency: c1 -> c2 -> c1", tostring(dryErr))

------------------------------------------------------------
-- ABI: a mismatch is refused; a missing abi is only a warning
------------------------------------------------------------
def("abi9", { abi = 9 })
expectErr("abi9: ABI 9 required, kernel has 1", module.load, "abi9", true)
def("noabi", { abi = nil })
assert(module.load("noabi", true) and module.exists("noabi"))
local warned = false
for _, l in ipairs(logs) do
    if l:find("noabi: no abi", 1, true) then warned = true end
end
assert(warned, "missing abi warns")

------------------------------------------------------------
-- driver files: .drv.lua needs a driver table; the name must match the file
------------------------------------------------------------
local nodrv = "/usr/lib/modules/system/kernel/drivers/net/nodrv.drv.lua"
files[nodrv] = { src = source("nodrv", {}) }
expectErr("nodrv: driver file must define a driver table", module.load, nodrv, true)

local plaindrv = "/usr/lib/modules/system/kernel/plaindrv.lua"
files[plaindrv] = { src = source("plaindrv", { driver = true }) }
expectErr("plaindrv: driver table in a non-.drv.lua file", module.load, plaindrv, true)

local rightDrv = "/usr/lib/modules/system/kernel/drivers/net/right.drv.lua"
files[rightDrv] = { src = source("wrong", { driver = true }) }
expectErr("wrong: driver name must match file name", module.load, rightDrv, true)

------------------------------------------------------------
-- trust: a file or directory not owned by root, or writable by others, is refused
------------------------------------------------------------
def("rogue", { uid = 1000 })
expectErr("untrusted module file", module.load, "rogue", true)
def("gwrite", { dir = "/usr/lib/modules/system/kernel/open/" })
dirAttr["/usr/lib/modules/system/kernel/open"] = { uid = 0, mode = 775 }
expectErr("untrusted module file", module.load, "gwrite", true)
assert(not module.exists("rogue") and not module.exists("gwrite"))

------------------------------------------------------------
-- drivers: a driver with bound devices is refused unless forced
------------------------------------------------------------
def("internet", { driver = true })
assert(module.load("internet", true))
assert(state("internet") == "loaded")
devmgr = {
    boundCount = function(n) return bound[n] or 0 end,
    teardownDriver = function(n, reason)
        torn[#torn + 1] = n .. ":" .. reason
        bound[n] = 0
    end,
}
bound.internet = 1
expectErr("in use by device", module.unload, "internet", true)
assert(module.exists("internet") and #torn == 0)
assert(module.unload("internet", true, { force = true }))
assert(joined(torn) == "internet:unload" and not module.exists("internet"))
devmgr = nil

io.write("module loader tests passed\n")
