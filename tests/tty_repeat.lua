-- TTY key repeat: the tty repeats held keys on its own timer and ignores
-- OC's repeated key_down events.
-- Run from the Nexus directory: lua tests/tty_repeat.lua
local driverPath = "root/usr/lib/modules/system/kernel/drivers/tty/"
local W, H = 20, 6
local frames = { [0] = {}, [1] = {} }
local active, fgc, bgc = 0, 0xFFFFFF, 0
local function key(x, y) return x .. ":" .. y end
local gpu = {
    freeAllBuffers = function() frames[1] = {} end,
    allocateBuffer = function() return 1 end,
    maxResolution = function() return W, H end,
    setResolution = function() end,
    setViewport = function() end,
    setForeground = function(c) fgc = c end,
    getBackground = function() return bgc, false end,
    setBackground = function(c) bgc = c end,
    getActiveBuffer = function() return active end,
    setActiveBuffer = function(b) active = b end,
    set = function(x, y, text)
        for i = 1, #text do frames[active][key(x + i - 1, y)] = { text:sub(i, i), bgc } end
    end,
    fill = function(x, y, w, h, ch)
        for sy = y, y + h - 1 do for sx = x, x + w - 1 do frames[active][key(sx, sy)] = { ch, bgc } end end
    end,
    copy = function(x, y, w, h, tx, ty)
        local f, snap = frames[active], {}
        for sy = y, y + h - 1 do for sx = x, x + w - 1 do snap[key(sx + tx, sy + ty)] = f[key(sx, sy)] end end
        for k, v in pairs(snap) do f[k] = v end
    end,
    bitblt = function(to, x, y, w, h, from, sx, sy)
        for dy = 0, h - 1 do for dx = 0, w - 1 do
            frames[to][key(x + dx, y + dy)] = frames[from][key(sx + dx, sy + dy)]
        end end
    end,
}

local now = 0
local devfsEnv = setmetatable({ vfsk = { createVNode = function() return {} end } }, { __index = _G })
assert(loadfile("src/devfs.lua", "t", devfsEnv))()
local vt
local signals = {}
local apis = {
    devfs = devfsEnv.devfs,
    filesystem = { open = function() return nil end },
    component = { list = function() return function() return "gpu" end end, proxy = function() return gpu end },
    computer = { uptime = function() return now end },
    event = { pull = coroutine.yield, setForeground = function() end, getForeground = function() return 2 end },
    process = { get = function(pid) return pid == 2 and { instance = 1, signals = signals } or nil end,
                getCurrentPID = function() return 2 end },
    module = { require = function() return vt.module end },
    system = { config = {}, createKernelThread = function(fn) vt.repaint = coroutine.create(fn) end },
}
local env = setmetatable({ require = function(name) return assert(apis[name], name) end }, { __index = _G })
vt = assert(loadfile(driverPath .. "vt.lua", "t", env))()
vt.load()
local tty = assert(loadfile(driverPath .. "tty.lua", "t", env))().module
local term = tty.new(0)

local function paint() assert(coroutine.resume(vt.repaint)) end
local function row(y)
    local t = {}
    for x = 1, W do local c = frames[0][key(x, y)]; t[x] = c and c[1] or " " end
    return (table.concat(t):gsub("%s+$", ""))
end
local function lastRow()
    for y = H, 1, -1 do if row(y) ~= "" then return row(y) end end
    return ""
end
local function cursorCell()
    for y = 1, H do for x = 1, W do
        local c = frames[0][key(x, y)]
        if c and c[2] == 0xFFFFFF then return x, y end
    end end
end


local LEFT, RIGHT, A = 203, 205, 30
-- A read driven by hand: each step resumes the reader with an event, or
-- with nothing (the pull timed out). `waits` is the timeout it asked for.
local function reading(...)
    local args = table.pack(...)
    local r = {}
    local co = coroutine.create(function(...)
        r.result = table.pack(term:read(table.unpack(args, 1, args.n)))
    end)
    local function step(...)
        local ok, timeout = coroutine.resume(co, ...)
        assert(ok, timeout)
        r.wait = timeout
    end
    step()
    function r.ev(...) assert(coroutine.status(co) == "suspended", "reader finished"); step(...) end
    function r.tick(t) now = t; r.ev() end
    function r.done() return coroutine.status(co) == "dead" end
    function r.lastWait() return r.wait end
    return r
end

-- column of the line editor's cursor ("$ " prompt), independent of blinking
local function cursorX() return term.pos + 3 end

-- 1. Canonical mode: OC's own repeats are ignored; the tty repeats after
-- the delay, once per interval, and stops on key_up.
term:write("$ ")
local r = reading("*l")
for _, c in ipairs({ "a", "b", "c", "d", "e", "f", "g", "h" }) do
    r.ev("key_down", "kb", c:byte(), A); r.ev("key_up", "kb", c:byte(), A)
end
assert(cursorX() == 11)
now = 1
r.ev("key_down", "kb", 0, LEFT)
assert(cursorX() == 10, "first press moves once")
assert(math.abs(r.lastWait() - 0.4) < 1e-9, "waits for the repeat delay, got " .. tostring(r.lastWait()))
for _ = 1, 5 do r.ev("key_down", "kb", 0, LEFT) end  -- OC repeats: ignored
assert(cursorX() == 10, "OC repeat events do not move the cursor")
r.tick(1.4)
assert(cursorX() == 9, "first repeat after the delay")
r.tick(1.45); r.tick(1.5)
assert(cursorX() == 7, "then one per interval")
r.ev("key_up", "kb", 0, LEFT)
assert(r.lastWait() == nil, "nothing held: wait without a timeout")
r.tick(2)
assert(cursorX() == 7, "no repeat after key_up")

-- printable keys do not repeat in canonical mode
r.ev("key_down", "kb", ("z"):byte(), A)
r.tick(3)
paint()
assert(row(1) == "$ abcdzefgh", row(1))
r.ev("key_up", "kb", ("z"):byte(), A)

-- 2. A lost key_up: without OC's repeats for a while the key counts as up.
now = 10
r.ev("key_down", "kb", 0, RIGHT)
local x = cursorX()
r.tick(10.4); r.tick(10.45)
assert(cursorX() == x + 2)
r.ev("key_down", "kb", 0, RIGHT)   -- OC still repeating at 10.45
r.tick(11.3)
assert(cursorX() == x + 3, "still held")
r.tick(11.5)                        -- > 1 s since OC's last repeat
assert(cursorX() == x + 3, "stale key stops repeating")
assert(r.lastWait() == nil)
assert(not term.pressing[RIGHT], "and is marked released")
r.ev("key_down", "kb", 13, 28)
term.pressing[28] = false
assert(r.done() and r.result[1] == "abcdzefgh")

-- 3. Raw mode: every key repeats, across separate reads, as sequences.
now = 20
local function rawRead()
    local rr = reading(1, { raw = true })
    return rr
end
local rr = rawRead()
rr.ev("key_down", "kb", 0, LEFT)
assert(rr.done() and rr.result[1] == "\27", "first byte of the sequence")
local rest = term:read(2, { raw = true })
assert(rest == "[D")
rr = rawRead()
rr.tick(20.2)
assert(not rr.done(), "not yet due")
rr.tick(20.4)
assert(rr.done(), "repeat delivered to the next read")
assert(term:read(2, { raw = true }) == "[D")
rr = rawRead()
rr.ev("key_down", "kb", 0, LEFT)   -- OC repeat: ignored
assert(not rr.done())
rr.tick(20.45)
assert(rr.done())
assert(term:read(2, { raw = true }) == "[D")
rr = rawRead()
rr.ev("key_up", "kb", 0, LEFT)
rr.tick(21)
assert(not rr.done(), "released: no more repeats")
rr.ev("key_down", "kb", ("q"):byte(), 16)
assert(rr.done() and rr.result[1] == "q")

print("tty repeat tests passed")
