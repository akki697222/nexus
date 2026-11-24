-- TTY input layer: key state, the tty's own key repeat, the input queue
-- (type-ahead), Ctrl+C without a reader.
-- Run from the Nexus directory: lua tests/tty_repeat.lua
local driverPath = "root/usr/lib/modules/system/kernel/drivers/tty/"
local W, H = 20, 6
local frames = { [0] = {}, [1] = {} }
local active, fgc, bgc = 0, 0xFFFFFF, 0
local bufferColors = {}
local function key(x, y) return x .. ":" .. y end
local gpu = {
    freeAllBuffers = function() frames[1] = {}; bufferColors[1] = nil end,
    allocateBuffer = function() return 1 end,
    maxResolution = function() return W, H end,
    setResolution = function() end,
    setViewport = function() end,
    setForeground = function(c) fgc = c end,
    getBackground = function() return bgc, false end,
    setBackground = function(c) bgc = c end,
    getActiveBuffer = function() return active end,
    -- colors belong to the active buffer, as in OpenComputers
    setActiveBuffer = function(b)
        bufferColors[active] = { fgc, bgc }
        active = b
        local c = bufferColors[b] or { 0xFFFFFF, 0 }
        fgc, bgc = c[1], c[2]
    end,
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
local wakes, foreground = 0, 2
local devfsEnv = setmetatable({ vfsk = { createVNode = function() return {} end } }, { __index = _G })
assert(loadfile("src/devfs.lua", "t", devfsEnv))()
local vt
local signals = {}
local apis = {
    devfs = devfsEnv.devfs,
    filesystem = { open = function() return nil end },
    component = { list = function() return function() return "gpu" end end, proxy = function() return gpu end },
    computer = { uptime = function() return now end },
    event = { pull = coroutine.yield, setForeground = function() end, getForeground = function() return foreground end },
    process = { get = function(pid) return pid == 2 and { instance = 1, signals = signals, pgid = 7 } or nil end,
                kill = function(pid, sig) signals[#signals + 1] = { pid, sig } end,
                getCurrentPID = function() return 2 end, getCurrent = function() return { pid = 2, tty = 0 } end,
                blockIO = function() coroutine.yield() end, wakeIO = function() wakes = wakes + 1 end },
    module = { require = function() return vt.module end },
    system = { config = { key_repeat_delay = 0.4, key_repeat_rate = 20 }, createKernelThread = function(fn) vt.repaint = coroutine.create(fn) end },
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


local LEFT, RIGHT, A, ENTER, SHIFT = 203, 205, 30, 28, 42
local function down(char, key) term:signal("key_down", "kb", char, key) end
local function up(char, key) term:signal("key_up", "kb", char, key) end
local function queued() return #term.queue end
local function tokens()
    local out = {}
    for i, t in ipairs(term.queue) do out[i] = t.paste or (t.char ~= 0 and string.char(t.char)) or ("k" .. t.key) end
    return table.concat(out, ",")
end
local function clear() term.queue = {} end

-- 1. One token per press; OC's repeat events are ignored; modifiers give
-- nothing; every push wakes the readers.
down(("a"):byte(), A)
down(("a"):byte(), A); down(("a"):byte(), A)
assert(tokens() == "a", tokens())
assert(wakes == 1)
up(("a"):byte(), A)
down(0, SHIFT); up(0, SHIFT)
assert(queued() == 1, "modifiers do not produce input")
clear()

-- 2. The tty repeats a held key itself: after the delay, then at the rate,
-- for any key (Enter too), until key_up.
now = 1
down(13, ENTER)
tty.tick(1.2)
assert(queued() == 1, "not before the delay")
tty.tick(1.4)
assert(queued() == 2, "first repeat after the delay")
tty.tick(1.45); tty.tick(1.5)
assert(queued() == 4, "then one per 0.05 s")
up(13, ENTER)
tty.tick(2)
assert(queued() == 4, "no repeat after key_up")
clear()

-- 3. Late passes: the due repeats are queued together (capped), and a rate
-- above 20/s gives more than one repeat in a tick.
now = 3
down(0, LEFT)
tty.tick(3.4)
assert(queued() == 2)
tty.tick(3.55)
assert(queued() == 5, "three were due: " .. queued())
now = 4.9; down(0, LEFT)          -- OC still repeating
tty.tick(5)
assert(queued() == 9, "capped burst: " .. queued())
up(0, LEFT)
clear()
apis.system.config.key_repeat_rate = 30
now = 6
down(0, RIGHT)
for _, t in ipairs({ 6.4, 6.45, 6.5, 6.55, 6.6, 6.65, 6.7 }) do tty.tick(t) end
-- press + repeats at 6.4 + i/30 up to 6.7: 10 of them
assert(queued() == 11, "30/s: " .. queued())
up(0, RIGHT)
apis.system.config.key_repeat_rate = 20
clear()

-- 4. A lost key_up: without OC repeat events for 1 s the key counts as up.
now = 10
down(0, RIGHT)
tty.tick(10.4); tty.tick(10.45)
assert(queued() == 3)
now = 10.45; down(0, RIGHT)       -- OC still repeating
tty.tick(11.3)
assert(queued() > 3, "still held")
local n = queued()
tty.tick(11.5)
assert(queued() == n and not term.keys[RIGHT] and term.held == nil, "stale key released")
clear()

-- 5. Ctrl+C and Ctrl+D do not repeat.
down(4, 32); tty.tick(20); up(4, 32)
assert(queued() == 1, "Ctrl+D once: " .. queued())
clear()

-- 6. Type-ahead: keys typed while nobody reads wait for the next read.
term:write("$ ")
for _, c in ipairs({ "l", "s", "\r" }) do
    down(c:byte(), c == "\r" and ENTER or A); up(c:byte(), c == "\r" and ENTER or A)
end
local co = coroutine.create(function() return term:read("*l") end)
local ok, line = coroutine.resume(co)
assert(ok and coroutine.status(co) == "dead" and line == "ls", tostring(line))
paint()
assert(row(1) == "$ ls", row(1))

-- 7. Ctrl+C (SIGINT) and Ctrl+\ (SIGQUIT) go to the foreground process
-- group whether or not anything reads, and drop pending input; a line
-- being read ends empty so the shell prompts again.
local function lastKill() local k = signals[#signals]; return k and (k[1] .. ":" .. k[2]) end
down(("x"):byte(), A); up(("x"):byte(), A)
foreground = 2
local before = #signals
down(3, 46); up(3, 46)
assert(lastKill() == "-7:2" and #signals == before + 1 and queued() == 0, tostring(lastKill()))
now = 25; down(3, 46); tty.tick(26); up(3, 46)
assert(#signals == before + 2, "Ctrl+C does not repeat")
down(28, 43); up(28, 43)
assert(lastKill() == "-7:3" and queued() == 0, "Ctrl+\\ is SIGQUIT")
term:write("$ ")
co = coroutine.create(function() return term:read("*l") end)
assert(coroutine.resume(co))
assert(coroutine.status(co) == "suspended", "blocks with an empty queue")
down(("y"):byte(), A); assert(coroutine.resume(co)); up(("y"):byte(), A)
down(3, 46)
local okc, got = coroutine.resume(co)
up(3, 46)
assert(okc and coroutine.status(co) == "dead" and got == "", "the line ends empty: " .. tostring(got))
assert(lastKill() == "-7:2" and #signals == before + 4)
paint()
assert(row(2) == "$ y^C", row(2))

-- 7b. A program that reads raw keys gets Ctrl+C as input, also between its
-- reads; it stays raw until something reads in canonical mode again.
before = #signals
co = coroutine.create(function() return term:read(1, { raw = true }) end)
assert(coroutine.resume(co))
down(3, 46); up(3, 46)
local _, rawc = coroutine.resume(co)
assert(rawc == "\3" and #signals == before, "raw read: Ctrl+C is input")
down(3, 46); up(3, 46)
assert(#signals == before and queued() == 1, "between raw reads too")
assert(term:read(1, { raw = true }) == "\3")
co = coroutine.create(function() return term:read("*l") end)
assert(coroutine.resume(co))
down(3, 46); assert(coroutine.resume(co)); up(3, 46)
assert(#signals == before + 1, "canonical again: Ctrl+C signals")

-- 8. Raw reads take one key each; repeats keep coming across reads.
now = 30
co = coroutine.create(function() return term:read(1, { raw = true }) end)
assert(coroutine.resume(co))
down(0, LEFT)
local _, b1 = coroutine.resume(co)
assert(b1 == "\27" and term:read(2, { raw = true }) == "[D")
tty.tick(30.4)
assert(term:read(3, { raw = true }) == "\27[D", "a repeat with no reader waiting is kept")
up(0, LEFT)

-- 9. The queue is bounded.
clear()
for i = 1, 300 do down(("q"):byte(), 16); up(("q"):byte(), 16) end
assert(queued() == 256)
clear()

-- 9b. A process that took the foreground to read key events itself gets
-- them alone; the tty does not queue them for its next read.
foreground = 99
down(("g"):byte(), 34); tty.tick(100); up(("g"):byte(), 34)
assert(queued() == 0, "keys for another foreground process are not queued")
foreground = 2
down(("h"):byte(), 35); up(("h"):byte(), 35)
assert(queued() == 1)
clear()

-- 10. tty.signal feeds the active tty.
tty.signal({ "key_down", "kb", ("z"):byte(), 44, n = 4 })
assert(tokens() == "z")
tty.signal({ "key_up", "kb", ("z"):byte(), 44, n = 4 })
assert(tty.isKeyPressing(44) == false)
clear()

-- 11. text_input (OpenComputers: Rebooted). Keys it has a code for send
-- key_down with the character and then text_input; keys it has none for
-- (JIS _ and |) send text_input alone, or their character rides on a
-- queued Shift key_down. Each character is typed exactly once.
local function text(s) term:signal("text_input", "kb", s, "player") end
local function texts()
    local out = {}
    for i, t in ipairs(term.queue) do
        out[i] = t.text or t.paste or (t.char ~= 0 and string.char(t.char)) or ("k" .. t.key)
    end
    return table.concat(out, ",")
end
now = 40
down(("a"):byte(), A); text("a"); up(("a"):byte(), A)
assert(texts() == "a", "the first text_input after its key_down is not doubled: " .. texts())
down(("b"):byte(), 48); text("b"); up(("b"):byte(), 48)
assert(texts() == "a,b", texts())
down(("_"):byte(), SHIFT); text("_"); up(0, SHIFT)
down(0, SHIFT); text("|"); up(0, SHIFT)
assert(texts() == "a,b,_,|", "characters without a key code: " .. texts())
down(13, ENTER); up(13, ENTER)
down(8, 14); up(8, 14)
assert(texts() == "a,b,_,|,\r,\b", "control keys still come from key_down: " .. texts())
clear()
-- the OS repeats printable keys through text_input; the tty does not
down(("c"):byte(), 46); text("c")
tty.tick(41); text("c"); text("c")
assert(texts() == "c,c,c", texts())
up(("c"):byte(), 46)
clear()
-- a line read takes the typed text
co = coroutine.create(function() return term:read("*l") end)
assert(coroutine.resume(co))
for ch in ("x_y|z"):gmatch(".") do text(ch) end
down(13, ENTER)
local _, line = coroutine.resume(co)
up(13, ENTER)
assert(line == "x_y|z", tostring(line))
clear()

print("tty input tests passed")
