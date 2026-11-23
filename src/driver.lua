-- component driver layer
-- Builds the wrapped `component` / `computer` libraries handed to userland
-- and kernel modules through their env. Neither ever receives a raw OC proxy
-- or the raw libraries: every method is a closure that checks the caller's
-- tier ("user" or "module") against a per-component-type policy.
-- Only boot code (init.lua, kernel.lua) uses the raw OC APIs.

---@class driver
driver = {}

---@alias driver_policy
---| '"all"'    # callable from any tier by anyone
---| '"root"'   # userland: euid 0 only; modules: allowed
---| '"module"' # kernel modules only

---@class driver_def
---@field methods table<string, driver_policy>
---@field default? driver_policy policy for unlisted methods (nil = not exported)

---@type table<string, driver_def>
local defs = {}

---@param ctype string
---@param def driver_def
function driver.register(ctype, def)
    defs[ctype] = def
end

-- Filesystem contents are reachable only through the VFS (which enforces
-- permissions and hides .meta), so file I/O is never exported to any tier.
driver.register("filesystem", {
    methods = {
        getLabel = "all",
        isReadOnly = "all",
        spaceTotal = "all",
        spaceUsed = "all",
        setLabel = "root",
    },
})

driver.register("debug", { methods = {}, default = "root" })

-- The boot ROM can be rewritten through this.
driver.register("eeprom", { methods = {}, default = "root" })

-- The console (tty/vt modules) owns the GPU and screen; userland may query them.
driver.register("gpu", {
    methods = {
        getResolution = "all",
        maxResolution = "all",
        getDepth = "all",
        maxDepth = "all",
        getScreen = "all",
        getViewport = "all",
    },
    default = "module",
})
driver.register("screen", {
    methods = { getAspectRatio = "all", getKeyboards = "all", isOn = "all" },
    default = "root",
})

-- Sound output is an ordinary user facility: the OCCE audio card ("audio")
-- and the sound card ("sound") are usable by every process.
driver.register("audio", { methods = {}, default = "all" })
driver.register("sound", { methods = {}, default = "all" })

-- fallback for component types without a dedicated definition
local generic = { methods = {}, default = "root" }

---@param tier '"user"'|'"module"'
---@param policy driver_policy|nil
---@return boolean exported, boolean needsRoot
local function evaluate(tier, policy)
    if not policy then return false, false end
    if tier == "module" then return true, false end
    if policy == "module" then return false, false end
    return true, policy == "root"
end

local function isRoot()
    local proc = process.getCurrent()
    return proc ~= nil and proc.euid == 0
end

-- Returns an empty proxy over `tbl`: __newindex only fires for absent keys,
-- so the real fields must never live in the table handed out.
local function readonly(tbl, name)
    return setmetatable({}, {
        __metatable = name,
        __index = tbl,
        __newindex = function() error(name .. " is read-only", 2) end,
        __pairs = function() return next, tbl, nil end,
    })
end

---@param tier '"user"'|'"module"'
---@param addr string
---@return string|nil ctype
---@return table|nil def
local function lookup(tier, addr)
    if type(addr) ~= "string" then return nil end
    local ctype = component.type(addr)
    if not ctype then return nil end
    return ctype, defs[ctype] or generic
end

-- Returns the policy for `method` as seen by `tier`, or nil if not exported.
local function access(tier, def, method)
    local exported, needsRoot = evaluate(tier, def.methods[method] or def.default)
    if exported then return needsRoot end
end

---@param tier '"user"'|'"module"'
---@param addr string
---@return table|nil
---@return string|nil
local function wrapProxy(tier, addr)
    local ctype, def = lookup(tier, addr)
    if not ctype then return nil, "no such component" end

    local obj = { address = addr, type = ctype, slot = component.slot(addr) }
    for name in pairs(component.methods(addr)) do
        local needsRoot = access(tier, def, name)
        if needsRoot ~= nil then
            obj[name] = function(...)
                if needsRoot and not isRoot() then
                    error("permission denied: " .. ctype .. "." .. name, 2)
                end
                return component.invoke(addr, name, ...)
            end
        end
    end
    return readonly(obj, "component proxy")
end

-- Same shape as the bare-metal OC `component` API; only methods the tier may
-- use are visible, and none of the returned objects is a raw proxy.
---@param tier '"user"'|'"module"'
---@return table component library
local function newComponentLib(tier)
    local lib = {}

    function lib.list(filter, exact)
        local found = {}
        for a, t in component.list(filter, exact) do found[a] = t end
        local key
        return setmetatable(found, {
            __call = function()
                key = next(found, key)
                if key then return key, found[key] end
            end,
        })
    end

    function lib.type(addr)
        local ctype = lookup(tier, addr)
        if not ctype then return nil, "no such component" end
        return ctype
    end

    function lib.slot(addr)
        if not lookup(tier, addr) then return nil, "no such component" end
        return component.slot(addr)
    end

    function lib.proxy(addr)
        return wrapProxy(tier, addr)
    end

    function lib.methods(addr)
        local ctype, def = lookup(tier, addr)
        if not ctype then return nil, "no such component" end
        local out = {}
        for name, direct in pairs(component.methods(addr)) do
            if access(tier, def, name) ~= nil then out[name] = direct end
        end
        return out
    end

    function lib.doc(addr, method)
        local ctype, def = lookup(tier, addr)
        if not ctype then return nil, "no such component" end
        if access(tier, def, method) == nil then return nil end
        return component.doc(addr, method)
    end

    function lib.invoke(addr, method, ...)
        local ctype, def = lookup(tier, addr)
        if not ctype then error("no such component", 2) end
        local needsRoot = access(tier, def, method)
        if needsRoot == nil then
            error("no such method: " .. ctype .. "." .. tostring(method), 2)
        end
        if needsRoot and not isRoot() then
            error("permission denied: " .. ctype .. "." .. tostring(method), 2)
        end
        return component.invoke(addr, method, ...)
    end

    return readonly(lib, "component")
end

---@type table<string, driver_policy>
local computerPolicy = {
    address = "all",
    tmpAddress = "all",
    freeMemory = "all",
    totalMemory = "all",
    energy = "all",
    maxEnergy = "all",
    uptime = "all",
    realTime = "all",
    isRunning = "all",
    getArchitecture = "all",
    getArchitectures = "all",
    getBootAddress = "all",
    getDeviceInfo = "all",
    getProgramLocations = "all",
    users = "all",
    beep = "all",
    shutdown = "root",
    pushSignal = "root",
    setArchitecture = "root",
    setBootAddress = "root",
    addUser = "root",
    removeUser = "root",
}

---@param tier '"user"'|'"module"'
---@return table computer library
local function newComputerLib(tier)
    local lib = {}
    for name, policy in pairs(computerPolicy) do
        local raw = computer[name]
        local exported, needsRoot = evaluate(tier, policy)
        if exported and type(raw) == "function" then
            lib[name] = function(...)
                if needsRoot and not isRoot() then
                    error("permission denied: computer." .. name, 2)
                end
                return raw(...)
            end
        end
    end
    -- The kernel owns the signal queue; processes receive signals via event.
    lib.pullSignal = function(timeout)
        return event.pull(timeout)
    end
    return readonly(lib, "computer")
end

local libs = {}

---@param tier '"user"'|'"module"'
---@return table component, table computer
function driver.libraries(tier)
    assert(tier == "user" or tier == "module", "bad tier")
    local l = libs[tier]
    if not l then
        l = { newComponentLib(tier), newComputerLib(tier) }
        libs[tier] = l
    end
    return l[1], l[2]
end
