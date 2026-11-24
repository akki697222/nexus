-- process / module environments
-- Builds the Lua environments for userland processes ("user" tier) and kernel
-- modules ("module" tier). Neither tier can reach the raw OC APIs or kernel
-- objects that hold them (vnodes, process entries): every kernel API is handed
-- out read-only (metatables locked), and `component`/`computer` come from the
-- policy layer.

---@param tbl table
---@param name string
---@return table
-- Returns an empty proxy over `tbl`: __newindex only fires for absent keys,
-- so the real fields must never live in the table handed out.
local function lock(tbl, name)
    return setmetatable({}, {
        __metatable = name,
        __index = tbl,
        __newindex = function() error(name .. " is read-only", 2) end,
        __pairs = function() return next, tbl, nil end,
    })
end

-- shallow copy of the functions in `src`, minus `exclude`
local function functions(src, exclude)
    local out = {}
    for k, v in pairs(src or {}) do
        if type(v) == "function" and not (exclude and exclude[k]) then
            out[k] = v
        end
    end
    return out
end

-- Per-environment shallow copy: reads fall through to `orig`, writes stay in
-- the copy, so one process cannot alter a library table another one uses.
---@param orig table
---@param name string
---@return table
local function overlay(orig, name)
    return setmetatable({}, {
        __index = orig,
        __metatable = name,
        __pairs = function(t)
            local own, k = true, nil
            return function()
                if own then
                    k = next(t, k)
                    if k ~= nil then return k, rawget(t, k) end
                    own = false
                end
                repeat k = next(orig, k) until k == nil or rawget(t, k) == nil
                if k ~= nil then return k, orig[k] end
            end, t, nil
        end,
    })
end

------------------------------------------------------------
-- process
------------------------------------------------------------

local PROC_FIELDS = {
    "pid", "instance", "tid", "pgid", "path", "nice", "parent", "status", "uid", "gid",
    "euid", "suid", "egid", "sgid", "tty", "err",
}

-- user tier: a detached snapshot
local function snapshot(p)
    if not p then return nil end
    local s = {}
    for _, k in ipairs(PROC_FIELDS) do s[k] = p[k] end
    s.arguments = util.copyTable(p.arguments)
    s.signals = util.copyTable(p.signals)
    s.environ = util.copyTable(p.environ)
    return s
end

-- module tier: a live view; drivers may deliver signals and set the tty
local MODULE_WRITABLE = { tty = true, nice = true }
local MODULE_READABLE = { arguments = true, signals = true, environ = true }
for _, k in ipairs(PROC_FIELDS) do MODULE_READABLE[k] = true end

local function liveView(p)
    if not p then return nil end
    return setmetatable({}, {
        __metatable = "process",
        __index = function(_, k)
            if MODULE_READABLE[k] then return p[k] end
        end,
        __newindex = function(_, k, v)
            if not MODULE_WRITABLE[k] then error("process." .. tostring(k) .. " is read-only", 2) end
            p[k] = v
        end,
    })
end

local function newProcessApi(tier)
    local view = tier == "module" and liveView or snapshot
    local api = functions(process, {
        getRunQueue = true,
        resume = true,
        dispatchWaiting = true,
        -- IO waits are for kernel modules (the tty input queue)
        blockIO = tier == "user" or nil,
        wakeIO = tier == "user" or nil,
        get = true,
        getCurrent = true,
        getParent = true,
        cwd = true,
    })
    function api.get(pid) return view(process.get(pid)) end

    function api.getCurrent() return view(process.getCurrent()) end

    function api.getParent()
        local cur = process.getCurrent()
        return cur and view(process.get(cur.parent)) or nil
    end

    function api.cwd(path) return process.cwd(path) end

    -- kill(2) permission: privileged, or the sender's real/effective uid
    -- matches the target's real/saved uid; init cannot be stopped
    local function maySignal(pid)
        local target = process.get(pid)
        if not target then return false, "No such process" end
        if target.pid == 1 then return false, "Operation not permitted" end
        local cur = process.getCurrent()
        if not cur or cur.euid == 0 then return true end
        if cur.uid == target.uid or cur.uid == target.suid
            or cur.euid == target.uid or cur.euid == target.suid then
            return true
        end
        return false, "Operation not permitted"
    end
    for _, name in ipairs({ "suspend", "resume_handle" }) do
        local f = process[name]
        api[name] = function(pid, ...)
            local ok, e = maySignal(pid)
            if not ok then return false, e end
            return f(pid, ...)
        end
    end
    -- kill(2) on a group: every member the caller may signal; fails only
    -- when there is none (EPERM if members exist but none is allowed)
    function api.killpg(pgid, sig)
        local found, sent, err = false, false, "No such process"
        for _, info in ipairs(process.list()) do
            local p = process.get(info.pid)
            if p and p.pgid == pgid and p.tid == p.pid then
                found = true
                local ok, e = maySignal(p.pid)
                if ok then
                    process.kill(p.pid, sig)
                    sent = true
                else
                    err = e
                end
            end
        end
        if sent then return true end
        return false, found and err or "No such process"
    end
    function api.kill(pid, sig)
        if math.type(pid) == "integer" and pid < 0 then
            if sig ~= nil and (math.type(sig) ~= "integer" or sig < 1 or sig > 31) then
                return false, "Invalid signal"
            end
            return api.killpg(-pid, sig or 9)
        end
        local ok, e = maySignal(pid)
        if not ok then return false, e end
        return process.kill(pid, sig)
    end
    return api
end

-- only the caller itself or one of its children may be switched (login(1))
local function newUserApi()
    local api = functions(user)
    function api.switchprocuser(username, password, pid)
        local cur = process.getCurrent()
        local target = process.get(pid)
        if not (cur and target and (target.pid == cur.pid or target.parent == cur.pid)) then
            return nil, "Operation not permitted"
        end
        return user.switchprocuser(username, password, pid)
    end

    return api
end

------------------------------------------------------------
-- environments
------------------------------------------------------------

-- module(7) for processes: root may load modules from /usr/lib/modules
-- and unload them; the module objects themselves stay in the kernel.
local MODULE_DIR = "/usr/lib/modules/"

local function newModuleApi()
    local api = functions(module, { autoload = true, load = true, unload = true, get = true })
    local function isRoot()
        local cur = process.getCurrent()
        return cur ~= nil and cur.euid == 0
    end
    function api.load(path)
        checkArg(1, path, "string")
        if not isRoot() then return nil, "Permission denied" end
        local real = vfs.resolve(path)
        if not real or real:sub(1, #MODULE_DIR) ~= MODULE_DIR then
            return nil, "modules must be under " .. MODULE_DIR
        end
        local mod, e = module.load(real, true)
        if not mod then return nil, e end
        return true, mod.manifest.name
    end
    function api.unload(name)
        checkArg(1, name, "string")
        if not isRoot() then return nil, "Permission denied" end
        local e = module.unload(name, true)
        if e then return nil, e end
        return true
    end
    return api
end

local function newApis(tier)
    local component, computer = policy.libraries(tier)
    local devfsapi = { exists = devfs.exists, list = devfs.list, isDirectory = devfs.isDirectory }
    local systemapi = functions(system, {
        _syncMetadata = true,
        createKernelThread = tier == "user" or nil,
        setConsole = tier == "user" or nil,
    })
    systemapi.config = lock(util.copyTable(system.config), "system.config")
    if tier == "module" then
        systemapi.console = system.console
        function devfsapi.create(name, ops, block, perm)
            local ok, e = devfs.create(name, ops, block, perm)
            return ok, e
        end
    end
    local apis = {
        -- vfs returns only plain data (stat copies, mount info, closure-backed
        -- file objects), so a read-only view of it is enough
        filesystem = lock(vfs, "filesystem"),
        component  = component,
        computer   = computer,
        event      = functions(event, tier == "user" and { addHook = true, removeHook = true } or nil),
        unicode    = functions(unicode),
        permission = functions(permission),
        module     = newModuleApi(),
        process    = newProcessApi(tier),
        devfs      = devfsapi,
        sha2       = { sha256 = sha256, sha512 = sha512 },
        system     = systemapi,
        user       = newUserApi(),
        group      = functions(group),
        device     = functions(device, { init = true, handleEvent = true, register = true }),
        util       = {
            encodeTable = util.encodeTable,
            copyTable = util.copyTable,
            createEnv = function()
                return util.createEnv()
            end
        },
    }
    for name, api in pairs(apis) do
        if getmetatable(api) == nil then apis[name] = lock(api, name) end
    end
    return apis
end

local function newBaseEnv(tier)
    local apis = newApis(tier)
    local base = {
        coroutine = coroutine,
        -- Only .traceback is exposed; OC's debug also has getupvalue,
        -- getinfo and getlocal, which are dropped here -- see the comment
        -- at the top of newEnv (NV-2026-001 / NX-17).
        debug = { traceback = debug.traceback },
        io = io,
        math = math,
        os = os,
        shell = shell,
        package = package,
        table = table,
        string = string,
        utf8 = utf8,
        unicode = apis.unicode,
        assert = assert,
        collectgarbage = function()
            -- do nothing
        end,
        getmetatable = getmetatable,
        setmetatable = setmetatable,
        ipairs = ipairs,
        pairs = pairs,
        print = print,
        next = next,
        pcall = pcall,
        xpcall = xpcall,
        rawequal = rawequal,
        rawget = rawget,
        rawlen = rawlen,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        error = error,
        type = type,
        checkArg = checkArg,
        _VERSION = _VERSION,
        _OSVERSION = _OSVERSION,
        _OSVERSIONNUMBER = _OSVERSIONNUMBER,
        _OSDIST = _OSDIST,
        _NEXUS = true,
    }
    return lock(base, "env"), apis
end

local baseEnvs = {}

---@param tier '"user"'|'"module"'
---@return table
-- NV-2026-001 / NX-17: process.getCurrent() (and the rest of `apis`: user,
-- filesystem, ...) is a single table shared by every process of this tier,
-- built once and cached below. Reusing it is safe, and cheap, as long as it
-- really is read-only to the code it's handed to:
--   - lock() below makes ordinary writes (api.x = y) error. That alone is
--     not enough: Lua's rawset() plants a key directly on the proxy table,
--     bypassing __newindex entirely and shadowing __index for every other
--     reader of that *same table* from then on -- including an unrelated,
--     later-exec'd setuid-root process such as sudo.lua, since it reads the
--     identical cached object. This is why `rawset` (along with the rest of
--     the raw* family that can reach a shared table) is not in the globals
--     below: with no way to call it, lock()'s __newindex guard holds.
--   - OpenComputers' debug library has no setmetatable/setupvalue/setlocal,
--     so it can't rewrite a locked proxy the way rawset could. But
--     debug.getupvalue can still read a closure's upvalues, and every
--     api.* closure here (e.g. api.getCurrent above) closes over the real,
--     un-lock()'d kernel module table (`process`, not a proxy of it) --
--     reading that reference out and assigning to it directly (no rawset
--     needed; it has no __newindex guard at all) would corrupt the one
--     real kernel object, worse than corrupting the proxy. debug is cut
--     down to just .traceback, dropping getupvalue/getinfo/getlocal, for
--     exactly this reason: see newBaseEnv.
-- If either restriction is ever loosened, this table must go back to being
-- built fresh per process (see git history) rather than shared again.
local function newEnv(tier)
    local entry = baseEnvs[tier]
    if not entry then
        local base, apis = newBaseEnv(tier)
        entry = { base = base, apis = apis }
        baseEnvs[tier] = entry
    end
    local apis = entry.apis
    local e = setmetatable({}, { __index = entry.base, __metatable = "env" })
    e._G = e

    for _, name in ipairs({ "string", "table", "math", "os", "coroutine", "utf8", "debug" }) do
        e[name] = overlay(entry.base[name], name)
    end
    local eio = overlay(io, "io")
    for _, name in ipairs({ "stdin", "stdout", "stderr" }) do
        rawset(eio, name, overlay(io[name], "file"))
    end
    e.io = eio

    -- Each process has its own module cache, as separate address spaces would.
    local pkg = overlay(package, "package")
    rawset(pkg, "loaded", {})
    rawset(pkg, "preload", {})
    e.package = pkg
    e.require = function(name)
        checkArg(1, name, "string")
        local api = apis[name]
        if api ~= nil then return api end
        local loaded = pkg.loaded
        if loaded[name] ~= nil then return loaded[name] end
        local loader, where = pkg.preload[name], ":preload:"
        if not loader then
            local path, err = package.searchpath(name, pkg.path)
            if not path then error("module '" .. name .. "' not found:" .. err, 2) end
            local chunk, lerr = loadfile(path, "bt", e)
            if not chunk then error(lerr, 2) end
            loader, where = chunk, path
        end
        local result = loader(name, where)
        if result ~= nil then
            loaded[name] = result
        elseif loaded[name] == nil then
            loaded[name] = true
        end
        return loaded[name]
    end

    -- chunks loaded without an explicit env must stay in this environment,
    -- not fall through to the kernel's global table
    e.load = function(ld, source, mode, env)
        return load(ld, source, mode, env or e)
    end
    e.loadfile = function(filename, mode, env)
        return loadfile(filename, mode, env or e)
    end
    e.dofile = function(filename)
        local chunk, err = loadfile(filename, "bt", e)
        if not chunk then
            error(err or "failed to load file", 2)
        end
        return chunk()
    end
    return e
end

---@return table
util.createEnv = function()
    return newEnv("user")
end

---@return table
createModuleEnv = function()
    return newEnv("module")
end
