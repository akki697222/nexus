-- device manager
-- Binds drivers (/usr/lib/drivers/<name>.lua) to OC components as they
-- appear and disappear. Matching uses the build-time index drivers.idx
-- (tools/depmod.lua); driver code never runs just to decide a match.
--
-- A driver runs in a sandbox: it sees the proxy of the device it is bound
-- to, a log function, the modules it declared in info.depends, and a few
-- harmless libraries. It cannot reach `component`, `computer` or other
-- devices.
--
-- Userland reaches a bound device only through device.open(path, mode),
-- which returns a handle carrying the ops the node's permissions and the
-- driver's info.access allow.

---@class devmgr
devmgr = {}

devmgr.indexPath = "/usr/lib/drivers/drivers.idx"

do

-- Types the kernel and its modules drive themselves.
local CORE_TYPES = {
    filesystem = true, gpu = true, screen = true,
    keyboard = true, eeprom = true, computer = true,
}
devmgr.coreTypes = CORE_TYPES

---@class devmgr_entry
---@field name string
---@field path string
---@field match string[]
---@field class? string
---@field depends? string[]
---@field desc? string
---@field node? string
---@field mode? integer
---@field group? string
---@field access? table<string, string>

---@type devmgr_entry[]
local index = {}
---@type table<string, devmgr_entry> type -> first matching driver
local byType = {}
---@type table<string, devmgr_entry>
local byName = {}

-- loaded driver code: name -> { drv = table, refs = integer }
local loaded = {}

---@class devmgr_binding
---@field address string
---@field type string
---@field driver? string
---@field node? string
---@field state string "bound" | "failed" | "unbound"
---@field error? string
---@field inst? any
---@field handles? table<table, boolean>

---@type table<string, devmgr_binding>
local bindings = {}

local ready = false

local function log(msg)
    printk("devmgr: " .. msg)
end

local function short(addr)
    return tostring(addr):sub(1, 8)
end

------------------------------------------------------------
-- index
------------------------------------------------------------

local function readFile(path)
    local f, e = vfs.open(path, "r")
    if not f then return nil, e end
    local data = f:readAll()
    f:close()
    return data
end

local function loadIndex()
    index, byType, byName = {}, {}, {}
    local data, e = readFile(devmgr.indexPath)
    if not data then
        return nil, e or "not found"
    end
    local chunk, err = load(data, "=drivers.idx", "t", {})
    if not chunk then return nil, err end
    local ok, idx = pcall(chunk)
    if not ok then return nil, idx end
    if type(idx) ~= "table" or type(idx.drivers) ~= "table" then
        return nil, "invalid index"
    end
    for _, entry in ipairs(idx.drivers) do
        if type(entry) == "table" and type(entry.name) == "string"
            and type(entry.path) == "string" and type(entry.match) == "table" then
            index[#index + 1] = entry
            byName[entry.name] = entry
            for _, t in ipairs(entry.match) do
                if not CORE_TYPES[t] and not byType[t] then
                    byType[t] = entry
                end
            end
        end
    end
    return true
end

------------------------------------------------------------
-- sandbox
------------------------------------------------------------

local function readonly(tbl, name)
    return setmetatable({}, {
        __index = tbl,
        __newindex = function() error(name .. " is read-only", 2) end,
        __metatable = name,
    })
end

local function overlay(tbl, name)
    return setmetatable({}, { __index = tbl, __metatable = name })
end

---@param entry devmgr_entry
local function newDriverEnv(entry)
    local declared = {}
    for _, m in ipairs(entry.depends or {}) do declared[m] = true end
    local name = entry.name
    local env = {
        assert = assert, error = error, ipairs = ipairs, pairs = pairs,
        next = next, pcall = pcall, xpcall = xpcall, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        rawequal = rawequal, rawget = rawget, rawlen = rawlen, rawset = rawset,
        setmetatable = setmetatable, getmetatable = getmetatable,
        checkArg = checkArg,
        string = overlay(string, "string"),
        table = overlay(table, "table"),
        math = overlay(math, "math"),
        utf8 = overlay(utf8, "utf8"),
        coroutine = overlay(coroutine, "coroutine"),
        computer = readonly({ uptime = computer.uptime }, "computer"),
        devfs = readonly({ exists = devfs.exists, list = devfs.list }, "devfs"),
    }
    function env.log(...)
        local parts = table.pack(...)
        for i = 1, parts.n do parts[i] = tostring(parts[i]) end
        printk(name .. ": " .. table.concat(parts, " "))
    end
    function env.require(modname)
        if not declared[modname] then
            error("module '" .. tostring(modname) .. "' is not declared in info.depends", 2)
        end
        local m = module.require(modname)
        if not m then error("module '" .. modname .. "' is not loaded", 2) end
        return m
    end
    env._G = env
    return env
end

---@param entry devmgr_entry
local function acquire(entry)
    local slot = loaded[entry.name]
    if slot then
        slot.refs = slot.refs + 1
        return slot.drv
    end
    for _, m in ipairs(entry.depends or {}) do
        if not module.exists(m) then
            return nil, "required module '" .. m .. "' is not loaded"
        end
    end
    local chunk, e = loadfile(entry.path, "t", newDriverEnv(entry))
    if not chunk then return nil, e or "cannot load" end
    local ok, drv = xpcall(chunk, debug.traceback)
    if not ok then return nil, drv end
    if type(drv) ~= "table" or type(drv.attach) ~= "function" then
        return nil, "not a driver (attach missing)"
    end
    loaded[entry.name] = { drv = drv, refs = 1 }
    return drv
end

local function releaseCode(name)
    local slot = loaded[name]
    if not slot then return end
    slot.refs = slot.refs - 1
    if slot.refs <= 0 then loaded[name] = nil end
end

------------------------------------------------------------
-- nodes
------------------------------------------------------------

local nodeOwner = {} -- node name -> address

local function allocNode(prefix, address, entry)
    local mode = tonumber(entry.mode) or 600
    local gid = 0
    if entry.group then
        local g = group.getGroup(entry.group)
        if g then
            gid = g.gid
        else
            log("group '" .. entry.group .. "' not found for " .. entry.name .. ", using root")
        end
    end
    for i = 0, 255 do
        local name = prefix .. i
        if not nodeOwner[name] and not devfs.exists(name) then
            local ok, _, vnode = devfs.create(name, {}, false, mode)
            if ok then
                if vnode then vnode.gid = gid end
                nodeOwner[name] = address
                return name
            end
        end
    end
    return nil
end

local function freeNode(name)
    if not name then return end
    nodeOwner[name] = nil
    devfs.unregister(name)
end

------------------------------------------------------------
-- bind / unbind
------------------------------------------------------------

local function revokeHandles(b)
    if b.handles then
        for h in pairs(b.handles) do h.valid = false end
    end
    b.handles = nil
end

---@param b devmgr_binding
---@param state string
---@param reason? string
local function teardown(b, state, reason)
    revokeHandles(b)
    local slot = b.driver and loaded[b.driver]
    if slot and slot.drv.detach and b.inst ~= nil then
        local ok, e = xpcall(slot.drv.detach, debug.traceback, b.inst)
        if not ok then log(b.driver .. ": detach failed: " .. tostring(e)) end
    end
    freeNode(b.node)
    local wasBound = b.state == "bound"
    if b.driver and wasBound then releaseCode(b.driver) end
    local node, driverName = b.node, b.driver
    b.inst, b.node = nil, nil
    b.state, b.error = state, reason
    if wasBound then
        computer.pushSignal("device_detached", b.address, b.type, driverName, node)
    end
end

---@param address string
---@param ctype string
---@param entry devmgr_entry
local function bindTo(address, ctype, entry)
    local b = bindings[address]
    if not b then
        b = { address = address, type = ctype, state = "unbound" }
        bindings[address] = b
    end
    b.driver = entry.name
    local drv, e = acquire(entry)
    if not drv then
        b.state, b.error = "failed", e
        log(entry.name .. ": cannot load for " .. short(address) .. ": " .. tostring(e))
        return nil, e
    end
    local proxy = component.proxy(address)
    local dev = {
        address = address,
        type = ctype,
        proxy = proxy,
    }
    function dev.emit(name, ...)
        checkArg(1, name, "string")
        computer.pushSignal(name, address, ...)
    end
    dev = readonly(dev, "device")
    local ok, inst = xpcall(drv.attach, debug.traceback, dev)
    if not ok or inst == nil then
        releaseCode(entry.name)
        b.state = "failed"
        b.error = ok and "attach returned nil" or tostring(inst)
        log(entry.name .. ": attach failed for " .. short(address) .. ": " .. b.error)
        return nil, b.error
    end
    b.inst = inst
    b.state, b.error = "bound", nil
    b.handles = {}
    if entry.node then
        b.node = allocNode(entry.node, address, entry)
        if not b.node then
            log(entry.name .. ": no free /dev/" .. entry.node .. "N node")
        end
    end
    log(entry.name .. " bound to " .. short(address)
        .. (b.node and (" as /dev/" .. b.node) or ""))
    computer.pushSignal("device_attached", address, ctype, entry.name, b.node)
    return true
end

-- Called when a component appears (or at coldplug).
---@param address string
---@param ctype string
function devmgr.probe(address, ctype)
    if CORE_TYPES[ctype] then return nil, "core type" end
    local b = bindings[address]
    if b and b.state == "bound" then return true end
    local entry = byType[ctype]
    if not entry then
        bindings[address] = { address = address, type = ctype, state = "unbound" }
        return nil, "no driver"
    end
    return bindTo(address, ctype, entry)
end

-- Called when a component disappears.
---@param address string
function devmgr.release(address)
    local b = bindings[address]
    if not b then return end
    if b.state == "bound" then
        teardown(b, "unbound")
        log((b.driver or "?") .. " released " .. short(address))
    end
    bindings[address] = nil
end

-- Detach after a driver error; the component stays known as failed.
local function fail(b, reason)
    if b.state ~= "bound" then return end
    log((b.driver or "?") .. ": " .. short(b.address) .. " failed: " .. tostring(reason))
    teardown(b, "failed", tostring(reason))
end

function devmgr.init()
    local ok, e = loadIndex()
    if not ok then
        log("no driver index (" .. tostring(e) .. "); automatic driver loading disabled")
    else
        log(#index .. " driver(s) indexed")
    end
    ready = true
    return ok, e
end

function devmgr.coldplug()
    if not ready then return end
    local list = {}
    for address, ctype in component.list() do
        list[#list + 1] = { address, ctype }
    end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    for _, item in ipairs(list) do devmgr.probe(item[1], item[2]) end
end

function devmgr.handleEvent(name, address, ctype)
    if not ready then return end
    if name == "component_added" and type(ctype) == "string" then
        devmgr.probe(address, ctype)
    elseif name == "component_removed" then
        devmgr.release(address)
    end
end

-- Manual control (devctl). Kernel callers only; userland gets root-checked
-- wrappers.
---@param address string
---@param driverName? string
function devmgr.bind(address, driverName)
    local b = bindings[address]
    local ctype = b and b.type or component.type(address)
    if not ctype then return nil, "no such device" end
    if CORE_TYPES[ctype] then return nil, "core device" end
    if b and b.state == "bound" then return nil, "already bound" end
    local entry
    if driverName then
        entry = byName[driverName]
        if not entry then return nil, "no such driver" end
        local matches = false
        for _, t in ipairs(entry.match) do if t == ctype then matches = true end end
        if not matches then return nil, "driver does not match " .. ctype end
    else
        entry = byType[ctype]
        if not entry then return nil, "no driver" end
    end
    return bindTo(address, ctype, entry)
end

function devmgr.unbind(address)
    local b = bindings[address]
    if not b or b.state ~= "bound" then return nil, "not bound" end
    teardown(b, "unbound")
    log((b.driver or "?") .. " unbound from " .. short(address))
    return true
end

function devmgr.rescan()
    local ok, e = loadIndex()
    if not ok then return nil, e end
    devmgr.coldplug()
    return true
end

---@return table[]
function devmgr.list()
    local out = {}
    for address, b in pairs(bindings) do
        out[#out + 1] = {
            address = address, type = b.type, driver = b.driver,
            node = b.node, state = b.state, error = b.error,
        }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

---@return table[]
function devmgr.drivers()
    local out = {}
    for _, e in ipairs(index) do
        local slot = loaded[e.name]
        out[#out + 1] = {
            name = e.name, match = util.copyTable(e.match), class = e.class,
            desc = e.desc, loaded = slot ~= nil, refs = slot and slot.refs or 0,
        }
    end
    return out
end

------------------------------------------------------------
-- userland handles: device.open / device.close
------------------------------------------------------------

-- process pid -> set of handles
local owned = {}

local function nodeVNode(name)
    return vfsk.lookup("/dev/" .. name)
end

local function inGroup(proc, gid)
    if (proc.egid or proc.gid) == gid then return true end
    local g = group.getGroupByGID(gid)
    if not g then return false end
    local u = user.getUserByUID(proc.euid or proc.uid)
    if not u then return false end
    for _, m in ipairs(g.members or {}) do
        if m == u.name then return true end
    end
    return false
end

local function allowed(vnode, proc, action)
    if (proc.euid or proc.uid) == 0 then return true end
    local mode = vnode.mode or 600
    if vnode.uid == (proc.euid or proc.uid) then
        return action == "r" and permission.canOwnerRead(mode) or action == "w" and permission.canOwnerWrite(mode)
    elseif inGroup(proc, vnode.gid) then
        return action == "r" and permission.canGroupRead(mode) or action == "w" and permission.canGroupWrite(mode)
    end
    return action == "r" and permission.canOtherRead(mode) or action == "w" and permission.canOtherWrite(mode)
end

local function bindingForNode(name)
    local address = nodeOwner[name]
    return address and bindings[address]
end

---@param path string
---@param mode? string "r" | "w" | "rw"
---@return table|nil, string|nil
function device.open(path, mode)
    checkArg(1, path, "string")
    mode = mode or "r"
    if mode ~= "r" and mode ~= "w" and mode ~= "rw" then
        return nil, "invalid mode"
    end
    local name = vfs.resolve(path):match("^/dev/([^/]+)$")
    if not name then return nil, "not a device" end
    local b = bindingForNode(name)
    if not b or b.state ~= "bound" then return nil, "No such device" end
    local vnode = nodeVNode(name)
    if not vnode then return nil, "No such device" end
    local proc = process.getCurrent() or { uid = 0, euid = 0, gid = 0, egid = 0, pid = 0 }
    local wantR, wantW = mode:find("r", 1, true) ~= nil, mode:find("w", 1, true) ~= nil
    if (wantR and not allowed(vnode, proc, "r")) or (wantW and not allowed(vnode, proc, "w")) then
        return nil, "Permission denied"
    end
    local entry = byName[b.driver]
    local slot = loaded[b.driver]
    if not entry or not slot then return nil, "No such device" end
    local isRoot = (proc.euid or proc.uid) == 0
    local state = { valid = true, binding = b, pid = proc.pid }
    local ops = {}
    local impl = slot.drv.ops or {}
    for op, need in pairs(entry.access or {}) do
        local f = impl[op]
        local permitted = (need == "r" and wantR) or (need == "w" and wantW) or (need == "root" and isRoot)
        if type(f) == "function" and permitted then
            ops[op] = function(...)
                if not state.valid then return nil, "device removed" end
                local res = table.pack(xpcall(f, debug.traceback, b.inst, ...))
                if not res[1] then
                    fail(b, res[2])
                    return nil, "device error"
                end
                return table.unpack(res, 2, res.n)
            end
        end
    end
    local handle = setmetatable({}, {
        __index = ops,
        __newindex = function() error("device handle is read-only", 2) end,
        __metatable = "device handle",
    })
    b.handles[state] = true
    local set = owned[state.pid]
    if not set then
        set = {}
        owned[state.pid] = set
    end
    set[handle] = state
    return handle
end

---@param handle table
---@return boolean|nil, string|nil
function device.close(handle)
    local proc = process.getCurrent()
    local pid = proc and proc.pid or 0
    local set = owned[pid]
    local state = set and set[handle]
    if not state then return nil, "bad handle" end
    set[handle] = nil
    if next(set) == nil then owned[pid] = nil end
    state.valid = false
    if state.binding.handles then state.binding.handles[state] = nil end
    return true
end

-- Process exit: drop every handle the process still holds.
function devmgr.reap(pid)
    local set = owned[pid]
    if not set then return end
    for _, state in pairs(set) do
        state.valid = false
        if state.binding.handles then state.binding.handles[state] = nil end
    end
    owned[pid] = nil
end
end
