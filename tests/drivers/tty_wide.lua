-- TTY and VT with UTF-8 and double-width characters (IME input through
-- text_input): one cell per column, the line editor moving and deleting
-- whole characters, wide characters wrapping as a unit.
-- Run from the Nexus directory: lua tests/drivers/tty_wide.lua
local driverPath = "root/usr/lib/modules/system/kernel/drivers/tty/"
local W, H = 10, 6
local frames = { [0] = {}, [1] = {} }
local active, fgc, bgc = 0, 0xFFFFFF, 0
local bufferColors = {}
local function key(x, y) return x .. ":" .. y end

local function wide(ch)
    local cp = utf8.codepoint(ch)
    return (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xFF00 and cp <= 0xFF60)
end
-- unicode.charWidth as OpenComputers provides it
unicode = { charWidth = function(ch) return wide(ch) and 2 or 1 end }

-- A GPU that draws like OpenComputers: one character per cell, a wide
-- character in its cell and the next (kept as "" there).
local gpu
gpu = {
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
        for _, cp in utf8.codes(text) do
            local ch = utf8.char(cp)
            frames[active][key(x, y)] = { ch, bgc }
            if wide(ch) then
                x = x + 1
                frames[active][key(x, y)] = { "", bgc }
            end
            x = x + 1
        end
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

local devfsEnv = setmetatable({ vfsk = { createVNode = function() return {} end } }, { __index = _G })
assert(loadfile("src/fs/devfs.lua", "t", devfsEnv))()
local vt
local apis = {
    devfs = devfsEnv.devfs,
    filesystem = { open = function() return nil end },
    component = { list = function() return function() return "gpu" end end, proxy = function() return gpu end },
    computer = { uptime = function() return 0 end },
    event = { pull = coroutine.yield, setForeground = function() end, getForeground = function() return 2 end },
    process = { get = function(pid) return pid == 2 and { instance = 1, signals = {} } or nil end,
                getCurrentPID = function() return 2 end,
                blockIO = function() coroutine.yield() end, wakeIO = function() end },
    module = { require = function() return vt.module end },
    system = { config = {}, createKernelThread = function(fn) vt.repaint = coroutine.create(fn) end },
}
local env = setmetatable({ require = function(name) return assert(apis[name], name) end }, { __index = _G })
vt = assert(loadfile(driverPath .. "vt.lua", "t", env))()
vt.load()
local tty = assert(loadfile(driverPath .. "tty.lua", "t", env))().module
local term = tty.new(0)
local dev = term.device

local function paint() assert(coroutine.resume(vt.repaint)) end
local function row(y)
    local t = {}
    for x = 1, W do
        local c = frames[0][key(x, y)]
        t[#t + 1] = c and c[1] or " "
    end
    return (table.concat(t):gsub("%s+$", ""))
end
local function cursorCell()
    for y = 1, H do for x = 1, W do
        local c = frames[0][key(x, y)]
        if c and c[2] == 0xFFFFFF then return x, y end
    end end
end
local function firstRow()
    for y = 1, H do if row(y) ~= "" then return y end end
end

local K = { left = 203, right = 205, home = 199, ["end"] = 207, delete = 211 }
local function reading()
    local result
    local co = coroutine.create(function() result = term:read("*l") end)
    assert(coroutine.resume(co))
    local f = {}
    local function step()
        if coroutine.status(co) == "suspended" then assert(coroutine.resume(co)) end
    end
    -- IME text arrives as text_input, one committed string at a time
    function f.text(s) term:signal("text_input", "kb", s, "p"); step() end
    function f.send(char, code)
        term:signal("key_down", "kb", char, code)
        step()
        term:signal("key_up", "kb", char, code)
        step()
    end
    function f.key(name, n) for _ = 1, n or 1 do f.send(0, K[name]) end end
    function f.bs(n) for _ = 1, n or 1 do f.send(8, 14) end end
    function f.enter() f.send(13, 28) end
    function f.result() return result end
    return f
end

-- 1. VT cells: a wide character takes two columns and the next character
-- follows it on screen.
term:write("ab")
term:write("あい\n")
paint()
assert(row(1) == "abあい", row(1))
assert(#dev.buf[1].cells == 6, "a b あ (2) い (2)")

-- 2. Typing, moving and deleting go by character, not by byte.
term:write("$ ")
local r = reading()
r.text("あ"); r.text("い"); r.text("x"); r.text("う")
paint()
assert(row(2) == "$ あいxう", row(2))
assert(select(1, cursorCell()) == 10, "cursor after う: " .. tostring(cursorCell()))
r.key("left", 2)
paint()
assert(select(1, cursorCell()) == 7, "cursor on x: " .. tostring(cursorCell()))
r.bs()               -- removes い, not one of its bytes
paint()
assert(row(2) == "$ あxう", row(2))
r.key("home"); r.key("delete")
r.key("end"); r.text("_|")
r.enter()
assert(r.result() == "xう_|", r.result())

-- 3. A wide character that does not fit at the end of a row starts the
-- next row; the editor's cursor follows it and erasing joins the rows.
term:write("> ")
r = reading()
r.text("1234567")    -- "> 1234567" fills nine of ten columns
r.text("漢")
paint()
local y = firstRow() and select(2, cursorCell())
assert(row(y - 1) == "> 1234567", row(y - 1))
assert(row(y) == "漢", "the wide character wrapped whole: " .. row(y))
assert(select(1, cursorCell()) == 3, "cursor after 漢")
r.key("left")
paint()
assert(select(1, cursorCell()) == 1 and select(2, cursorCell()) == y, "cursor on 漢")
r.key("end"); r.bs()
paint()
assert(row(y - 1) == "> 1234567" and row(y) == "", "erased back across the wrap")
r.text("字")
r.enter()
assert(r.result() == "1234567字", r.result())

-- 4. Overwriting half of a wide character blanks the other half.
term:write("いろ\r")
term:write("x")
term:write("\n")
paint()
local rows = {}
for yy = 1, H do rows[#rows + 1] = row(yy) end
assert(table.concat(rows, "/"):find("x ろ", 1, true), table.concat(rows, "/"))

-- 5. Scrollback keeps wide characters (serialized and read back).
for i = 1, 12 do term:write("行" .. i .. "\n") end
paint()
local lines = {}
for _, line in ipairs(dev.buf) do lines[#lines + 1] = table.concat(line.cells) end
assert(table.concat(lines, "/"):find("行12", 1, true), table.concat(lines, "/"))

print("tty wide character tests passed")
