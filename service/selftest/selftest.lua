-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Phase 1 completion check: spawn -> IPC send/recv -> kill.
local results = {}

local function check(name, cond, detail)
    results[#results + 1] = { name, cond }
    if cond then
        log.info("[selftest] PASS %s", name)
    else
        log.error("[selftest] FAIL %s %s", name, detail or "")
    end
end

log.info("[selftest] start")

-- 1. core services running (they are started by the scheduler, so wait for them)
local t_wait = computer.uptime()
while computer.uptime() - t_wait < 5 do
    if service_manager.all_running() then break end
    scheduler.sleep(0.1)
end
for _, id in ipairs({ "storage", "filesystem", "module" }) do
    check("service " .. id .. " running", service_manager.is_running(id))
end

-- 2. spawn
local child = process_manager.spawn({ path = "System://Services/selftest_child.lua" })
check("spawn returns pid", type(child) == "number")
check("child alive", ipc.is_alive(child))

-- 3. IPC round trip
scheduler.sleep(0.2)
ipc.send(child, { type = "request", payload = "ping" })
local reply = event.pull("ipc", 3.0)
check("ipc reply received", reply ~= nil, "(timeout)")
check("ipc payload echoed", reply ~= nil and reply.data.payload == "ping" and reply.from == child)

-- 4. sleep accuracy
local t0 = computer.uptime()
scheduler.sleep(0.5)
local dt = computer.uptime() - t0
check("sleep(0.5) took >=0.5s", dt >= 0.5, string.format("(dt=%.2f)", dt))

-- 5. kill + process_died event
process_manager.kill(child)
local died = event.pull("process_died", 2.0, function(e) return e.pid == child end)
check("process_died event", died ~= nil and died.pid == child, "(timeout)")
check("child dead", not ipc.is_alive(child))

-- 6. event.pull timeout returns nil
local t1 = computer.uptime()
local none = event.pull("never_happens", 0.3)
local dt1 = computer.uptime() - t1
check("pull timeout -> nil", none == nil and dt1 >= 0.25, string.format("(result=%s dt=%.4f)", tostring(none), dt1))

-- ------------------------------------------------------------
--  Phase 2: storage / VFS / stream / require
-- ------------------------------------------------------------
local vols = storage.list_volumes()
check("alias System mounted", vols.System ~= nil)
check("storage.resolve", storage.resolve("System://Exec/../x.txt"):match("^/Volumes/[^/]+/System/x%.txt$") ~= nil)
check("path escape rejected", select(1, pcall(storage.resolve, "System://../x")) == false)

local base = vols.Temp and "Temp://" or "System://"
local f = fs.open(base .. "nexus_selftest/a.txt", "w")
check("fs.open(w)", f ~= nil)
if f then
    f:write("line1\nline2\n")
    f:write("tail")
    f:close()
    check("stream invalid after close", not capability.is_valid(f))
end
local r = fs.open(base .. "nexus_selftest/a.txt")
check("fs.open(r)", r ~= nil)
if r then
    check("read *l", r:read("*l") == "line1")
    check("read n", r:read(3) == "lin")
    check("read rest", r:read("a") == "e2\ntail")
    check("read eof", r:read("l") == nil)
    r:close()
end
check("fs.read_file", fs.read_file(base .. "nexus_selftest/a.txt") == "line1\nline2\ntail")
local st = fs.stat(base .. "nexus_selftest/a.txt")
check("fs.stat size", st ~= nil and st.size == 16 and not st.is_dir)
local names = fs.list(base .. "nexus_selftest")
check("fs.list", names ~= nil and #names == 1 and names[1] == "a.txt")
check("fs.open missing -> nil", fs.open(base .. "nexus_selftest/none.txt") == nil)

-- big file: crosses the 2048-byte read/write chunk boundary
local big = string.rep("0123456789abcdef", 600)
check("write big", fs.write_file(base .. "nexus_selftest/big.txt", big))
check("read big", fs.read_file(base .. "nexus_selftest/big.txt") == big)

-- streams are closed when their owner dies
local leak_pid = process_manager.spawn({ path = "System://Services/selftest_leak.lua", args = { base .. "nexus_selftest/a.txt" } })
event.pull("process_died", 2.0, function(e) return e.pid == leak_pid end)
check("leaked stream revoked", rawget(_G, "selftest_leaked") ~= nil and not capability.is_valid(selftest_leaked))
selftest_leaked = nil

-- require
local mod_dir = "System://Library/"
fs.write_file(mod_dir .. "nexus_selftest_mod.lua", "return { n = 42 }")
local m1 = require("nexus_selftest_mod")
local m2 = require("nexus_selftest_mod")
check("require", type(m1) == "table" and m1.n == 42)
check("require cached (same object)", m1 == m2)
check("require missing errors", select(1, pcall(require, "nexus_no_such_mod")) == false)
fs.remove(mod_dir .. "nexus_selftest_mod.lua")

fs.remove(base .. "nexus_selftest")
check("cleanup", not fs.exists(base .. "nexus_selftest"))

-- ------------------------------------------------------------
--  Phase 3: exit codes, stdio, devices, service restart
-- ------------------------------------------------------------
local pipe = stdio.pipe()
local epid = process_manager.spawn({ path = "System://Services/selftest_exit.lua", stdout = pipe })
local ecode = process_manager.wait(epid, 3)
check("process.exit code", ecode == 7, "(code=" .. tostring(ecode) .. ")")
check("stdout redirected to pipe", pipe:read("a") == "hello from child\n")

check("terminal service", term ~= nil)

local has_gpu = false
for _, hnd in pairs(capability.list_devices()) do
    if hnd.nexus_type == "display" then has_gpu = true end
end
if has_gpu then
    local narrow = system.open("display", { "set" })
    check("system.open(display) narrowed", narrow ~= nil and narrow.set ~= nil and narrow.fill == nil)
    local grp = system.open("display", "graphics")
    check("system.open group", grp ~= nil and grp.fill ~= nil and grp.depth == nil)
end

-- input routing: input events reach only watching processes (uses "scroll"
-- so an interactive shell reading the keyboard ignores these fake events)
local me = process_manager.self()
router.push({ type = "scroll", data = { "scroll", "kbd", 97, 30 } })
check("input not delivered without watch", event.pull("scroll", 0.3) == nil)
router.watch_input(me)
router.push({ type = "scroll", data = { "scroll", "kbd", 98, 48 } })
local kd = event.pull("scroll", 1.0)
check("input delivered while watching", kd ~= nil and kd.data[3] == 98)
router.watch_input(me, function(e) return e.data[3] == 3 end)
router.push({ type = "scroll", data = { "scroll", "kbd", 99, 46 } })
router.push({ type = "scroll", data = { "scroll", "kbd", 3, 46 } })
local cc = event.pull("scroll", 1.0)
check("input filter (Ctrl+C only)", cc ~= nil and cc.data[3] == 3)
router.unwatch_input(me)

selftest_crash_runs = 0
service_manager.register({ id = "selftest_crashy", path = "System://Services/selftest_crashy.lua", kind = "system", deps = {} })
service_manager.start("selftest_crashy")
local t_crash = computer.uptime()
while computer.uptime() - t_crash < 6 and not service_manager.is_running("selftest_crashy") do
    scheduler.sleep(0.2)
end
check("service restarted after crash", service_manager.is_running("selftest_crashy") and selftest_crash_runs == 2,
    "(runs=" .. tostring(selftest_crash_runs) .. ")")
service_manager.unregister("selftest_crashy")
selftest_crash_runs = nil

local failed = 0
for _, r in ipairs(results) do
    if not r[2] then failed = failed + 1 end
end
log.info("[selftest] done: %d/%d passed, free mem=%d", #results - failed, #results, computer.freeMemory())
print(string.format("selftest: %d/%d passed%s", #results - failed, #results, failed > 0 and " (see debug.log)" or ""))
log.flush()
