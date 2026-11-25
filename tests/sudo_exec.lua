-- Standalone regression tests for exec credential transitions and argv isolation.
-- Run from the nexus repository root with: lua tests/sudo_exec.lua
local process_source = dofile("tests/lib/kernel.lua").source("process")
local file = assert(io.open("src/sec/permission.lua", "r"))
local permission_source = file:read("*a")
file:close()

local function fresh()
    local programs, attrs, process_errors = {}, {}, {}
    local old_loadfile = loadfile
    local globals = {}
    local keys = { "util", "vfs", "vfsk", "permission", "event", "printk", "process", "processes", "signals" }
    for _, key in ipairs(keys) do globals[key] = _G[key] end
    util = { createEnv = function() return { fresh = true } end, copyTable = function(t)
        local r = {}; for k, v in pairs(t or {}) do r[k] = v end; return r
    end }
    vfs = {
        resolve = function(path) return path end,
        attributes = function(path) return attrs[path] or { mode = 0, uid = 0, gid = 0 } end,
        exists = function(path) return programs[path] ~= nil end,
        can = function() return true end
    }
    vfsk = { root = function() return {} end, consoleFds = function() return {} end,
        inheritFds = function() return {} end, closeAllFds = function() end }
    permission = assert(load(permission_source .. "\nreturn permission", "permission.lua"))()
    event = { removeQueue = function() end }
    printk = function(message) process_errors[#process_errors + 1] = tostring(message) end
    loadfile = function(path)
        if not programs[path] then return nil, "missing test program: " .. path end
        return programs[path]
    end
    assert(load(process_source .. "\nevent = _G.event", "process.lua"))()
    local api = process
    local function add(path, fn, attr) programs[path] = fn; attrs[path] = attr end
    local function spawn(path, args, nice, env, uid, gid)
        local pid, err = api.exec(path, args, nice, env, nil, uid, gid)
        assert(pid > 0, err)
        return pid
    end
    local function tick(ev)
        local snapshot, dead = {}, {}
        for _, p in ipairs(api.getRunQueue()) do snapshot[#snapshot + 1] = p end
        for _, p in ipairs(snapshot) do
            if api.get(p.pid) then if api.resume(p, ev) then dead[#dead + 1] = p.pid end end
        end
        for _, pid in ipairs(dead) do if api.get(pid) then api.kill(pid) end end
        api.current = -1
        assert(#process_errors == 0, "unexpected process error: " .. table.concat(process_errors, "\n"))
    end
    local function cleanup()
        loadfile = old_loadfile
        for _, key in ipairs(keys) do _G[key] = globals[key] end
    end
    return api, add, spawn, tick, cleanup
end

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then io.stderr:write("FAIL ", name, "\n", err, "\n"); os.exit(1) end
    print("ok - " .. name)
end

local setuid_attr = { mode = 4755, uid = 0, gid = 0 }
local function caller_setup(api, uid, gid)
    local ok, err = api.setuser({ uid = uid, gid = gid })
    assert(ok, err)
end

test("setuid exec preserves caller and creates isolated root credentials and argv", function()
    local api, add, spawn, tick, cleanup = fresh()
    local caller_pid, child_pid, observed
    add("/caller", function()
        caller_setup(api, 100, 100)
        local original = { "before" }
        local env = setmetatable({ caller = true }, { __index = function() error("caller env index") end })
        child_pid = assert(api.exec("/sudo", original, nil, env))
        original[1] = "after"
        local caller = api.get(caller_pid)
        assert(caller.uid == 100 and caller.euid == 100 and caller.suid == 100)
        assert(caller.gid == 100 and caller.egid == 100 and caller.sgid == 100)
    end)
    add("/sudo", function(...) observed = { ... } end, setuid_attr)
    caller_pid = spawn("/caller")
    tick()
    local child = api.get(child_pid)
    assert(child, "child should still be registered before next tick")
    assert(child.uid == 100 and child.euid == 0 and child.suid == 0)
    assert(child.gid == 100 and child.egid == 100 and child.sgid == 100)
    assert(child.env.fresh == true and child.env.caller == nil)
    assert(child.arguments[1] == "before")
    tick()
    assert(observed and observed[1] == "before")
    cleanup()
end)

test("privileged argv copying never invokes caller metatable callbacks", function()
    local api, add, spawn, tick, cleanup = fresh()
    local callback_count, child_pid = 0, nil
    add("/caller", function()
        caller_setup(api, 100, 100)
        local args = setmetatable({ [1] = "safe" }, {
            __len = function() callback_count = callback_count + 1; error("len callback") end,
            __index = function() callback_count = callback_count + 1; error("index callback") end,
            __pairs = function() callback_count = callback_count + 1; error("pairs callback") end
        })
        child_pid = assert(api.exec("/sudo", args))
    end)
    add("/sudo", function() end, setuid_attr)
    spawn("/caller"); tick()
    assert(callback_count == 0)
    local child = assert(api.get(child_pid))
    assert(child.arguments[1] == "safe" and getmetatable(child.arguments) == nil)
    tick()
    assert(callback_count == 0)
    cleanup()
end)

test("privileged exec rejects malformed argument lists and invalid nice values", function()
    local api, add, spawn, tick, cleanup = fresh()
    local results = {}
    add("/caller", function()
        caller_setup(api, 100, 100)
        local malformed = {
            { [1] = "x", [3] = "z" },
            { [1] = "x", [2] = false },
            { [0] = "x", [1] = "y" },
            { [1] = "x", extra = "y" },
            { [1] = "x", [65537] = "y" }
        }
        for i, args in ipairs(malformed) do results[i] = api.exec("/sudo", args) end
        results[6] = api.exec("/sudo", { "x" }, {})
        results[7] = api.exec("/sudo", "not a table")
    end)
    add("/sudo", function() error("invalid input was executed") end, setuid_attr)
    spawn("/caller"); tick()
    for i = 1, 7 do assert(results[i] == -1, "case " .. i .. " must be rejected") end
    assert(api.getRunQueue()[1] == nil, "rejected execs must not enqueue children")
    cleanup()
end)

test("root sudo parent creates root child while its own credentials stay caller-owned", function()
    local api, add, spawn, tick, cleanup = fresh()
    local sudo_pid, child_pid, observed, caller_credentials
    add("/caller", function()
        caller_setup(api, 100, 100)
        sudo_pid = assert(api.exec("/sudo", {}))
        api.wait(sudo_pid)
        local me = api.get(api.current)
        caller_credentials = { me.uid, me.euid, me.suid, me.gid, me.egid, me.sgid }
    end)
    add("/sudo", function()
        assert(api.setuser({ uid = 0, gid = 0 }))
        local me = api.get(sudo_pid)
        assert(me.uid == 0 and me.euid == 0 and me.suid == 0)
        assert(me.gid == 0 and me.egid == 0 and me.sgid == 0)
        child_pid = assert(api.exec("/command", {}))
    end, setuid_attr)
    add("/command", function()
        local me = api.get(api.current)
        observed = { me.uid, me.euid, me.suid, me.gid, me.egid, me.sgid }
    end)
    spawn("/caller")
    tick(); tick(); tick()
    assert(child_pid and observed)
    for i = 1, 6 do assert(observed[i] == 0, "child credential field " .. i .. " should be root") end
    assert(caller_credentials)
    for i = 1, 6 do assert(caller_credentials[i] == 100, "caller credential field " .. i .. " changed") end
    cleanup()
end)

print("all process.exec privilege tests passed")
