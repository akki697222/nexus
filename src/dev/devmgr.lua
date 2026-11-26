-- device manager
-- Binds driver modules to OC components as they appear and disappear.
-- Candidates come from the module index (modules.idx, see tools/depmod.lua):
-- every kind == "driver" entry whose driver.match names the component type,
-- highest priority first. A candidate is loaded with module.load only when it
-- is tried for a component, so a driver that matches nothing never runs.
--
-- A driver is a normal kernel module. attach(dev) receives a read-only device
-- table: dev.proxy wraps the component proxy and raises "device removed" once
-- the binding is torn down.
--
-- Bound drivers stay resident. A driver that was auto-loaded for an attempt
-- and bound nothing is unloaded again at once. module.unload of a driver with
-- bound devices is refused unless forced; a forced unload calls
-- devmgr.teardownDriver first.
--
-- Userland reaches a bound device only through device.open(path, mode), which
-- returns a handle carrying the ops that the node's permissions and the
-- driver's access table allow.

---@class devmgr
devmgr = {}

do
    -- Types the kernel and its modules drive themselves.
    local CORE_TYPES = {
        filesystem = true,
        gpu = true,
        screen = true,
        keyboard = true,
        eeprom = true,
        computer = true,
    }
    devmgr.coreTypes = CORE_TYPES

    ---@class devmgr_candidate
    ---@field name string
    ---@field path string
    ---@field desc? string
    ---@field meta table the driver table of the index entry
    ---@field priority integer

    ---@class devmgr_binding
    ---@field address string
    ---@field type string
    ---@field state string "bound" | "unbound" | "failed"
    ---@field driver? string
    ---@field drv? table the driver table of the loaded module
    ---@field meta? table
    ---@field inst? any
    ---@field ctx? table liveness flag shared with dev.proxy
    ---@field node? string
    ---@field error? string
    ---@field handles? table<table, boolean>

    ---@type devmgr_candidate[] sorted by priority desc, then name asc
    local index = {}
    ---@type table<string, devmgr_candidate[]> component type -> candidates
    local byType = {}
    ---@type table<string, devmgr_candidate> driver name -> candidate
    local byName = {}
    ---@type table<string, devmgr_binding> component address -> binding
    local bindings = {}
    ---@type table<string, string> node name -> address
    local nodeOwner = {}
    local ready = false
    local subs = {}
    local nextToken = 0

    local function log(msg, level)
        printk("devmgr: " .. msg, level)
    end

    local function short(addr)
        return tostring(addr):sub(1, 8)
    end

    local function readonly(tbl, name)
        return setmetatable({}, {
            __index = tbl,
            __newindex = function() error(name .. " is read-only", 2) end,
            __metatable = name,
        })
    end

    local function matches(list, ctype)
        for _, t in ipairs(list or {}) do
            if t == ctype then return true end
        end
        return false
    end

    ------------------------------------------------------------
    -- index
    ------------------------------------------------------------

    -- Rebuilds the candidate lists from module.index(). Returns the number of
    -- driver entries.
    local function buildIndex()
        local idx = module.index()
        local list = {}
        for name, entry in pairs(idx.modules) do
            if entry.kind == "driver" and type(entry.driver) == "table" then
                list[#list + 1] = {
                    name = name,
                    path = entry.path,
                    desc = entry.desc,
                    meta = entry.driver,
                    priority = tonumber(entry.driver.priority) or 0,
                }
            end
        end
        table.sort(list, function(a, b)
            if a.priority ~= b.priority then return a.priority > b.priority end
            return a.name < b.name
        end)
        byType, byName = {}, {}
        for _, cand in ipairs(list) do
            byName[cand.name] = cand
            for _, t in ipairs(cand.meta.match or {}) do
                if not CORE_TYPES[t] then
                    local l = byType[t]
                    if not l then
                        l = {}
                        byType[t] = l
                    end
                    l[#l + 1] = cand
                end
            end
        end
        index = list
        return #list
    end

    ------------------------------------------------------------
    -- bindings and subscribers
    ------------------------------------------------------------

    local function record(address, ctype)
        local b = bindings[address]
        if not b then
            b = { address = address, type = ctype, state = "unbound" }
            bindings[address] = b
        end
        b.type = ctype
        return b
    end

    local function boundCount(name)
        local n = 0
        for _, b in pairs(bindings) do
            if b.state == "bound" and b.driver == name then n = n + 1 end
        end
        return n
    end

    local function notify(event, info)
        local tokens = {}
        for token in pairs(subs) do tokens[#tokens + 1] = token end
        table.sort(tokens)
        for _, token in ipairs(tokens) do
            local fn = subs[token]
            if fn then
                local ok, e = pcall(fn, event, info)
                if not ok then log("subscriber failed: " .. tostring(e), "err") end
            end
        end
    end

    ------------------------------------------------------------
    -- nodes
    ------------------------------------------------------------

    -- System groups for driver-declared node groups take the lowest free gid
    -- in 100..999.
    local function createGroup(name)
        for gid = 100, 999 do
            if not group.getGroupByGID(gid) then
                local ok, e = group.create(name, gid)
                if ok == nil and e then
                    log("cannot create group '" .. name .. "': " .. tostring(e), "warning")
                    return nil
                end
                local g = group.getGroup(name)
                if g then log("created group " .. name .. " (gid " .. gid .. ")") end
                return g
            end
        end
    end

    local function allocNode(prefix, address, meta, name)
        local mode = tonumber(meta.mode) or 600
        local gid = 0
        if meta.group then
            local g = group.getGroup(meta.group) or createGroup(meta.group)
            if g then
                gid = g.gid
            else
                log("cannot create group '" .. meta.group .. "' for " .. name .. ", using root", "warning")
            end
        end
        for i = 0, 255 do
            local nodeName = prefix .. i
            if not nodeOwner[nodeName] and not devfs.exists(nodeName) then
                local ok, _, vnode = devfs.create(nodeName, {}, false, mode)
                if ok then
                    if vnode then vnode.gid = gid end
                    nodeOwner[nodeName] = address
                    return nodeName
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
    -- attach / teardown
    ------------------------------------------------------------

    -- The dev table handed to probe and attach. dev.proxy raises once ctx
    -- is no longer alive.
    local function makeDev(address, ctype, ctx)
        local raw = component.proxy(address)
        local proxy = setmetatable({}, {
            __index = function(_, k)
                local v = raw[k]
                if type(v) ~= "function" then return v end
                return function(...)
                    if not ctx.alive then error("device removed", 2) end
                    return v(...)
                end
            end,
            __newindex = function() error("device proxy is read-only", 2) end,
            __metatable = "device proxy",
        })
        return readonly({
            address = address,
            type = ctype,
            slot = component.slot(address),
            name = ctype,
            proxy = proxy,
            pushSignal = function(sig, ...)
                checkArg(1, sig, "string")
                if not ctx.alive then error("device removed", 2) end
                computer.pushSignal(sig, address, ...)
            end,
        }, "device")
    end

    -- Tears a bound device down. reason is "removed", "unload" or "failed".
    -- Handles die, detach runs, /dev node goes, every process holding a handle
    -- gets SIGDEV once, and device_detached is pushed.
    ---@param b devmgr_binding
    ---@param reason string
    ---@param err? string
    local function teardown(b, reason, err)
        local ctx, drv, inst = b.ctx, b.drv, b.inst
        local node, driverName, ctype, address = b.node, b.driver, b.type, b.address
        if ctx then ctx.alive = false end

        local holders, seen = {}, {}
        for st in pairs(b.handles or {}) do
            st.valid = false
            if not seen[st.pid] then
                seen[st.pid] = true
                holders[#holders + 1] = st.pid
            end
        end
        table.sort(holders)
        b.handles = nil

        if drv and drv.detach and inst ~= nil then
            local ok, e = xpcall(drv.detach, debug.traceback, inst)
            if not ok then log(driverName .. ": detach failed: " .. tostring(e), "err") end
        end
        freeNode(node)

        for _, pid in ipairs(holders) do
            local paths = {}
            if node then paths[1] = "/dev/" .. node end
            process.sendDevSignal(pid, reason, paths)
        end

        b.inst, b.drv, b.meta, b.ctx, b.node = nil, nil, nil, nil, nil
        b.state = reason == "failed" and "failed" or "unbound"
        b.error = err
        if reason ~= "failed" then b.driver = nil end
        computer.pushSignal("device_detached", address, ctype, driverName, node, reason)
        notify("detach", { address = address, type = ctype, driver = driverName, node = node, reason = reason })
    end

    -- A driver raised while bound (ops or a probe); the device is cut off.
    local function fail(b, reason)
        if b.state ~= "bound" then return end
        log((b.driver or "?") .. ": " .. short(b.address) .. " failed: " .. tostring(reason), "err")
        teardown(b, "failed", tostring(reason))
    end

    -- Probes and attaches with one loaded candidate. Returns true when bound,
    -- nil when refused (probe false, attach nil), or nil plus an error text
    -- when a driver raised.
    local function bindOne(address, ctype, cand, drv)
        if type(drv) ~= "table" or type(drv.attach) ~= "function" then
            return nil, cand.name .. ": not a driver (attach missing)"
        end
        local ctx = { alive = true }
        local dev = makeDev(address, ctype, ctx)

        if drv.probe ~= nil then
            local ok, res = xpcall(drv.probe, debug.traceback, dev)
            if not ok then
                ctx.alive = false
                log(cand.name .. ": probe failed for " .. short(address) .. ": " .. tostring(res), "err")
                return nil, "probe failed: " .. tostring(res)
            end
            if res == false then
                ctx.alive = false
                return nil
            end
        end

        local ok, inst = xpcall(drv.attach, debug.traceback, dev)
        if not ok then
            ctx.alive = false
            log(cand.name .. ": attach failed for " .. short(address) .. ": " .. tostring(inst), "err")
            return nil, "attach failed: " .. tostring(inst)
        end
        if inst == nil then
            ctx.alive = false
            return nil
        end

        local b = record(address, ctype)
        b.state, b.error = "bound", nil
        b.driver, b.drv, b.meta, b.inst, b.ctx = cand.name, drv, cand.meta, inst, ctx
        b.handles = {}
        b.node = nil
        if cand.meta.node then
            b.node = allocNode(cand.meta.node, address, cand.meta, cand.name)
            if not b.node then
                log(cand.name .. ": no free /dev/" .. cand.meta.node .. "N node")
            end
        end
        log(cand.name .. " bound to " .. short(address) .. (b.node and (" as /dev/" .. b.node) or ""))
        computer.pushSignal("device_attached", address, ctype, cand.name, b.node)
        notify("attach", { address = address, type = ctype, driver = cand.name, node = b.node })
        return true
    end

    -- Unloads a driver that was loaded for an attempt and bound nothing.
    local function unloadIfUnused(name)
        if boundCount(name) > 0 then return end
        local ok, err = module.unload(name, true)
        if not ok and not (type(err) == "string" and err:find("^in use by ")) then
            panic("devmgr: cannot unload " .. name .. ": " .. tostring(err))
        end
    end

    -- Tries candidates in order. Returns true on the first bind, otherwise
    -- nil plus the last error text (nil when every candidate just refused).
    local function attemptList(address, ctype, list)
        local lastErr
        for _, cand in ipairs(list) do
            local wasLoaded = module.get(cand.name) ~= nil
            local mod, err = module.load(cand.name, true, { auto = true })
            if not mod then
                log(cand.name .. ": cannot load: " .. tostring(err), "err")
                lastErr = tostring(err)
            else
                local ok, bindErr = bindOne(address, ctype, cand, mod.driver)
                if ok then return true end
                if bindErr then lastErr = bindErr end
                if not wasLoaded then unloadIfUnused(cand.name) end
            end
        end
        return nil, lastErr
    end

    local function tryBind(address, ctype, list)
        local ok, err = attemptList(address, ctype, list)
        if ok then return true end
        local rec = record(address, ctype)
        rec.state, rec.error = err and "failed" or "unbound", err
        return nil, err or "no driver"
    end

    ------------------------------------------------------------
    -- hotplug and admin API
    ------------------------------------------------------------

    -- Called when a component appears (or at coldplug).
    ---@param address string
    ---@param ctype string
    function devmgr.probe(address, ctype)
        if CORE_TYPES[ctype] then return nil, "core type" end
        local b = bindings[address]
        if b and b.state == "bound" then return true end
        local list = byType[ctype] or {}
        if #list == 0 then
            local rec = record(address, ctype)
            rec.state, rec.error = "unbound", nil
            return nil, "no driver"
        end
        return tryBind(address, ctype, list)
    end

    -- Called when a component disappears.
    ---@param address string
    function devmgr.release(address)
        local b = bindings[address]
        if not b then return end
        if b.state == "bound" then
            log((b.driver or "?") .. " released " .. short(address))
            teardown(b, "removed")
        end
        bindings[address] = nil
    end

    function devmgr.init()
        local n = buildIndex()
        log(n .. " driver(s) indexed")
        ready = true
        return true
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

    -- Manual control (devctl). With driverName only that driver is tried.
    ---@param address string
    ---@param driverName? string
    function devmgr.bind(address, driverName)
        local b = bindings[address]
        if b and b.state == "bound" then return nil, "already bound" end
        local ctype = b and b.type or component.type(address)
        if not ctype then return nil, "no such device" end
        if CORE_TYPES[ctype] then return nil, "core device" end
        local list
        if driverName then
            local cand = byName[driverName]
            if not cand then return nil, "no such driver" end
            if not matches(cand.meta.match, ctype) then
                return nil, "driver does not match " .. ctype
            end
            list = { cand }
        else
            list = byType[ctype] or {}
            if #list == 0 then return nil, "no driver" end
        end
        return tryBind(address, ctype, list)
    end

    function devmgr.unbind(address)
        local b = bindings[address]
        if not b or b.state ~= "bound" then return nil, "not bound" end
        log((b.driver or "?") .. " unbound from " .. short(address))
        teardown(b, "removed")
        return true
    end

    -- Reloads the index and coldplugs every component that is not bound.
    function devmgr.rescan()
        module.reindex()
        buildIndex()
        devmgr.coldplug()
        return true
    end

    -- Force-unload support: tears down every device bound to a driver.
    -- Returns the number of bindings torn down.
    ---@param name string
    ---@param reason string "unload" | "removed" | "failed"
    function devmgr.teardownDriver(name, reason)
        checkArg(1, name, "string")
        if reason ~= "unload" and reason ~= "removed" and reason ~= "failed" then
            return nil, "bad reason"
        end
        local victims = {}
        for _, b in pairs(bindings) do
            if b.state == "bound" and b.driver == name then victims[#victims + 1] = b end
        end
        for _, b in ipairs(victims) do teardown(b, reason) end
        return #victims
    end

    -- Number of devices bound to a driver.
    function devmgr.boundCount(name)
        return boundCount(name)
    end

    -- Subscribers get ("attach", info) and ("detach", info) synchronously;
    -- info carries address, type, driver, node (and reason on detach).
    ---@param fn fun(event: string, info: table)
    ---@return integer token
    function devmgr.subscribe(fn)
        checkArg(1, fn, "function")
        nextToken = nextToken + 1
        subs[nextToken] = fn
        return nextToken
    end

    function devmgr.unsubscribe(token)
        subs[token] = nil
    end

    ---@return table[]
    function devmgr.list()
        local out = {}
        for address, b in pairs(bindings) do
            out[#out + 1] = {
                address = address,
                type = b.type,
                driver = b.driver,
                node = b.node,
                state = b.state,
                error = b.error,
            }
        end
        table.sort(out, function(a, b) return a.address < b.address end)
        return out
    end

    -- One entry per driver in the index.
    ---@return table[]
    function devmgr.drivers()
        local out = {}
        for _, cand in ipairs(index) do
            local meta = cand.meta
            out[#out + 1] = {
                name = cand.name,
                path = cand.path,
                desc = cand.desc,
                match = util.copyTable(meta.match or {}),
                priority = cand.priority,
                class = meta.class,
                node = meta.node,
                mode = meta.mode,
                group = meta.group,
                access = util.copyTable(meta.access or {}),
                loaded = module.get(cand.name) ~= nil,
                bound = boundCount(cand.name),
            }
        end
        return out
    end

    ------------------------------------------------------------
    -- userland administration (devctl)
    ------------------------------------------------------------

    local function callerIsRoot()
        local cur = process.getCurrent()
        return cur == nil or (cur.euid or cur.uid) == 0
    end

    -- Driver index and binding state; readable by anyone.
    function device.drivers() return devmgr.drivers() end

    function device.bindings() return devmgr.list() end

    function device.bind(address, driverName)
        checkArg(1, address, "string")
        if not callerIsRoot() then return nil, "Permission denied" end
        return devmgr.bind(address, driverName)
    end

    function device.unbind(address)
        checkArg(1, address, "string")
        if not callerIsRoot() then return nil, "Permission denied" end
        return devmgr.unbind(address)
    end

    function device.rescan()
        if not callerIsRoot() then return nil, "Permission denied" end
        return devmgr.rescan()
    end

    ------------------------------------------------------------
    -- userland handles: device.open / device.close
    ------------------------------------------------------------

    -- process pid -> handle -> state
    local owned = {}

    local function nodeVNode(name)
        return vfsk.lookup("/dev/" .. name)
    end

    local function inGroup(proc, gid)
        if (proc.egid or proc.gid) == gid then return true end
        local g = group.getGroupByGID(gid)
        if not g then return false end
        -- user entries are { username = ..., uid = ... } (src/sec/user.lua)
        local u = user.getUserByUID(proc.euid or proc.uid)
        if not u then return false end
        for _, m in ipairs(g.members or {}) do
            if m == u.username then return true end
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
        local root = (proc.euid or proc.uid) == 0
        local state = { valid = true, binding = b, pid = proc.pid }
        local ops = {}
        local impl = b.drv.ops or {}
        for op, need in pairs(b.meta.access or {}) do
            local f = impl[op]
            local permitted = need == "open"
                or (need == "r" and wantR)
                or (need == "w" and wantW)
                or (need == "root" and root)
                or (need == "rw" and wantR and wantW)
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
