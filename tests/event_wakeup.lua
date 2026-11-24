-- Event waits, wakeups and handlers. Run from nexus: lua tests/event_wakeup.lua
local now = 0
local saved = { process = process, computer = computer, event = event }
computer = { uptime = function() return now end }
process = { current = -1 }
function process.getCurrent()
    if process.current == -1 then return nil end
    return { pid = process.current }
end
assert(loadfile("src/event.lua"))()

-- A blocked pull, run the way the scheduler does: as `pid`, resumed with
-- the process start arguments.
local function blocked(pid, fn)
    local co = coroutine.create(fn)
    process.current = pid
    local ok, marker = coroutine.resume(co)
    process.current = -1
    assert(ok and marker == "__event_wait__", tostring(marker))
    local entry = { pid = pid, thread = co }
    function entry.resume()
        process.current = pid
        local result = table.pack(coroutine.resume(co, "program", "arguments"))
        process.current = -1
        assert(result[1], result[2])
        return table.unpack(result, 2, result.n)
    end
    return entry
end

-- 1. A pull timeout fires without any signal, and returns nothing.
local timed = blocked(5, function() return "done", event.pull(0.5) end)
assert(not event.wants(timed, 0.4, { n = 0 }), "woken before its deadline")
assert(event.wants(timed, 0.6, { n = 0 }), "deadline must wake the waiter while idle")
now = 0.6
local tag, value = timed.resume()
assert(tag == "done" and value == nil, "timeout must not return the start arguments: " .. tostring(value))

-- 2. A queued signal wakes its process and is what pull returns.
now = 1
local waiting = blocked(5, function() return event.pull() end)
assert(not event.wants(waiting, now, { n = 0 }))
event.dispatch(table.pack("modem_message", "addr", 42))
assert(event.wants(waiting, now, { n = 1, "modem_message" }))
local name, addr, port = waiting.resume()
assert(name == "modem_message" and addr == "addr" and port == 42, tostring(name))

-- 3. Input goes to the foreground process only; others are not woken.
local fg = blocked(5, function() return event.pull("key_down") end)
local bg = blocked(6, function() return event.pull("key_down") end)
event.setForeground(5)
event.dispatch(table.pack("key_down", "kb", 97, 30))
assert(event.wants(fg, now, { n = 1, "key_down" }))
assert(not event.wants(bg, now, { n = 1, "key_down" }), "background process must not wake on input")
assert(select(1, fg.resume()) == "key_down")

-- 4. Timers of other processes are not consumed by the kernel dispatch.
process.current = 7
local fired = 0
event.timer(0.1, function() fired = fired + 1 end, 1)
process.current = -1
now = 2
event.dispatch(table.pack("redstone_changed"))
assert(fired == 0, "timer ran in the wrong context")
local stillThere = false
for _, h in pairs(event.handlers) do if h.pid == 7 then stillThere = true end end
assert(stillThere, "kernel dispatch consumed another process's timer")
local timerWaiter = blocked(7, function() return event.pull(10) end)
assert(event.wants(timerWaiter, now, { n = 0 }), "a due timer must wake its owner")
event.dispatch(table.pack("tick"))
timerWaiter.resume()
assert(fired == 1, "timer did not run in its owner: " .. fired)
for _, h in pairs(event.handlers) do assert(h.pid ~= 7, "one-shot timer must be removed") end

-- 5. Unread queues are capped.
local spammed = blocked(8, function() return event.pull() end) -- creates pid 8's queue
for i = 1, 300 do event.dispatch(table.pack("spam", i)) end
local first = table.pack(spammed.resume())
assert(first[1] == "spam" and first[2] == 300 - 256 + 1, "oldest events are dropped first: " .. tostring(first[2]))

-- Kernel hooks see every signal before it is queued; a failing hook is
-- logged and does not stop the others or the dispatch.
checkArg = checkArg or function() end
local seen = {}
local logged = {}
printk = function(msg) logged[#logged + 1] = msg end
local bad = event.addHook(function() error("boom") end)
local good = event.addHook(function(ev) seen[#seen + 1] = ev[1] end)
event.dispatch(table.pack("key_down", "kb", 98, 48))
assert(seen[1] == "key_down" and #seen == 1)
assert(logged[1] and logged[1]:find("hook failed"), tostring(logged[1]))
event.removeHook(good)
event.removeHook(bad)
event.dispatch(table.pack("key_up", "kb", 98, 48))
assert(#seen == 1, "removed hooks are not called")

process, computer, event = saved.process, saved.computer, saved.event
io.write("event wakeup tests passed\n")
