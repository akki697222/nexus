-- kdebug.lua - kernel debugging aids for development builds
--
-- Release branches leave this file out of properties.includes; the kernel
-- only uses it after checking that `kdebug` exists. Switched on in
-- /boot/config.lua:
--   debug = true        kdebug.print reaches the console
--   loop_stats = true   every 2s of activity, one debug line in klog
--                       (dmesg) with passes, game ticks, signals and the
--                       CPU time spent in processes and kernel threads

---@class kdebug
kdebug = {}

function kdebug.print(...)
    if config.debug then
        print(...)
    end
end

-- Counters for the kernel loop, or nil when config.loop_stats is off. The
-- loop calls pass(ev) after pulling a signal, processesDone() after the
-- processes ran and threadsDone() after the kernel threads.
function kdebug.loopStats()
    if not config.loop_stats then return nil end
    local s = {
        since = computer.uptime(), passes = 0, ticks = 0, signals = 0, keys = 0,
        maxPerTick = 0, inTick = 0, lastTick = nil, proc = 0, kthr = 0, cpu = os.clock(),
    }
    local t0, t1
    local function report(now)
        local cpu = os.clock() - s.cpu
        if s.signals > 0 then
            printk(string.format(
                "loop: %.1fs %d passes %d ticks, %d signals (%d keys, max %d/tick), cpu %dms (proc %dms kthr %dms)",
                now - s.since, s.passes, s.ticks, s.signals, s.keys, s.maxPerTick,
                cpu * 1000, s.proc * 1000, s.kthr * 1000), "debug")
        end
        s.since, s.passes, s.ticks, s.signals, s.keys = now, 0, 0, 0, 0
        s.maxPerTick, s.proc, s.kthr, s.cpu = 0, 0, 0, os.clock()
    end

    local stats = {}
    function stats.pass(ev)
        local now = computer.uptime()
        s.passes = s.passes + 1
        if now ~= s.lastTick then
            s.ticks, s.lastTick, s.inTick = s.ticks + 1, now, 0
        end
        if ev.n > 0 then
            s.signals = s.signals + 1
            if ev[1] == "key_down" or ev[1] == "key_up" then s.keys = s.keys + 1 end
            s.inTick = s.inTick + 1
            if s.inTick > s.maxPerTick then s.maxPerTick = s.inTick end
        end
        t0 = os.clock()
    end
    function stats.processesDone()
        t1 = os.clock()
    end
    function stats.threadsDone()
        local t2 = os.clock()
        s.proc, s.kthr = s.proc + (t1 - t0), s.kthr + (t2 - t1)
        local now = computer.uptime()
        if now - s.since >= 2 then report(now) end
    end
    return stats
end
