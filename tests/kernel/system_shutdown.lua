-- Standalone kernel shutdown API regression tests. Run with:
--   lua tests/kernel/system_shutdown.lua
local source_file = assert(io.open("src/kernel/system.lua", "r"))
local system_source = source_file:read("*a")
source_file:close()

local function fresh(save)
    local caller = { pid = 2, euid = 0 }
    local current_pid = 2
    local calls = {}
    local env = setmetatable({
        config = {},
        process = {
            current = -1,
            getCurrent = function() return caller end,
            getCurrentPID = function() return current_pid end,
        },
        vfs = { saveMetadata = save or function() calls[#calls + 1] = "flush"; return true end },
        computer = {
            shutdown = function(reboot)
                calls[#calls + 1] = reboot and "reboot" or "poweroff"
                return true
            end,
        },
    }, { __index = _G })
    assert(load(system_source, "system.lua", "t", env))()
    return env.system, caller, calls, function(pid) current_pid = pid end
end

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then io.stderr:write("FAIL ", name, "\n", err, "\n"); os.exit(1) end
    print("ok - " .. name)
end

test("root request is first-wins and PID 1 reads it", function()
    local system, caller, _, set_pid = fresh()
    caller.euid = 1000
    local ok, err = system.requestShutdown(false)
    assert(ok == nil and err == "Permission denied")
    caller.euid = 0
    assert(system.requestShutdown(false))
    assert(system.requestShutdown(true))
    local denied, reason = system.shutdownRequested()
    assert(denied == nil and reason == "Permission denied")
    set_pid(1)
    assert(system.shutdownRequested() == false)
end)

test("finish flushes before issuing poweroff", function()
    local system, _, calls, set_pid = fresh()
    assert(system.requestShutdown(false))
    set_pid(1)
    assert(system.finishShutdown())
    assert(table.concat(calls, ",") == "flush,poweroff")
    assert(system.shutdownRequested() == nil)
end)

test("failed final flush clears request for retry", function()
    local system, _, calls, set_pid = fresh(function() return nil, "disk full" end)
    assert(system.requestShutdown(true))
    set_pid(1)
    local ok, err = system.finishShutdown()
    assert(ok == nil and err == "disk full")
    assert(system.shutdownRequested() == nil)
    assert(#calls == 0)
end)

test("finish waits for periodic sync before the final flush", function()
    local system, _, calls, set_pid = fresh()
    local active_sync = coroutine.create(function()
        assert(system._syncMetadata(function()
            coroutine.yield("periodic")
            calls[#calls + 1] = "periodic-done"
            return true
        end))
    end)
    local resumed, yielded = coroutine.resume(active_sync)
    assert(resumed and yielded == "periodic")
    assert(system.requestShutdown(true))
    set_pid(1)
    local result
    local finish = coroutine.create(function() result = system.finishShutdown() end)
    local finish_ok = coroutine.resume(finish)
    assert(finish_ok and coroutine.status(finish) == "suspended")
    assert(coroutine.resume(active_sync))
    assert(coroutine.resume(finish))
    assert(result == true)
    assert(table.concat(calls, ",") == "periodic-done,flush,reboot")
end)

print("all system shutdown tests passed")
