-- TTY line editing, history, completion and raw mode on a real VT.
-- Run from the Nexus directory: lua tests/tty_lineedit.lua
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

local devfsEnv = setmetatable({ vfsk = { createVNode = function() return {} end } }, { __index = _G })
assert(loadfile("src/devfs.lua", "t", devfsEnv))()
local vt
local signals = {}
local apis = {
    devfs = devfsEnv.devfs,
    filesystem = { open = function() return nil end },
    component = { list = function() return function() return "gpu" end end, proxy = function() return gpu end },
    computer = { uptime = function() return 0 end },
    event = { pull = coroutine.yield, setForeground = function() end, getForeground = function() return 2 end },
    process = { get = function(pid) return pid == 2 and { instance = 1, signals = signals } or nil end,
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

local K = { left = 203, right = 205, up = 200, down = 208, home = 199, ["end"] = 207, delete = 211 }
-- Starts a read and returns a feeder: feed("text"), feed{key="left"}, ...
local function reading(...)
    local result
    local args = table.pack(...)
    local co = coroutine.create(function() result = table.pack(term:read(table.unpack(args, 1, args.n))) end)
    assert(coroutine.resume(co))
    local feeder = {}
    -- keys go through the tty's input layer, as the kernel hook delivers them
    function feeder.send(char, code)
        assert(coroutine.status(co) == "suspended", "reader already finished")
        term:signal("key_down", "kb", char, code or 0)
        assert(coroutine.resume(co))
        term:signal("key_up", "kb", char, code or 0)
        if coroutine.status(co) == "suspended" then assert(coroutine.resume(co)) end
    end
    function feeder.type(text) for i = 1, #text do feeder.send(text:byte(i), 30) end end
    function feeder.key(name, times) for _ = 1, times or 1 do feeder.send(0, K[name]) end end
    function feeder.ctrl(letter) feeder.send(letter:byte() - 96, 30) end
    function feeder.enter() feeder.send(13, 28) end
    function feeder.result() return result and table.unpack(result, 1, result.n) end
    return feeder
end

-- 1. Insert in the middle, move, delete.
term:write("$ ")
local r = reading("*l")
r.type("hello")
r.key("left", 2)
r.type("XY")
paint()
assert(row(1) == "$ helXYlo", row(1))
assert(select(1, cursorCell()) == 8, "cursor after XY")
r.key("home"); r.key("delete")
r.key("end"); r.send(8, 14)
paint()
assert(row(1) == "$ elXYl", row(1))
r.enter()
assert(r.result() == "elXYl")

-- 2. History: up/down, and the line being typed comes back.
local history = {}
for _, line in ipairs({ "one", "two" }) do
    term:write("$ ")
    r = reading("*l", { history = history })
    r.type(line); r.enter()
end
assert(#history == 2 and history[2] == "two")
term:write("$ ")
r = reading("*l", { history = history })
r.type("dr")
r.key("up"); paint(); assert(lastRow() == "$ two", "up shows the last entry: " .. lastRow())
r.key("up"); r.key("up")
r.key("down")
r.key("down")
paint()
assert(lastRow() == "$ dr", "draft restored: " .. lastRow())
r.key("up"); r.enter()
assert(r.result() == "two")
assert(#history == 2, "repeating the last entry is not stored twice")

-- 3. Ctrl+U / Ctrl+W.
term:write("$ ")
r = reading("*l")
r.type("cp a.txt b.txt")
r.ctrl("w")
r.type("c.txt")
r.key("left", 5)
r.ctrl("u")
r.enter()
assert(r.result() == "c.txt", tostring(r.result()))

-- 4. Editing a line that wraps across rows.
term:write("$ ")
r = reading("*l")
local long = "abcdefghijklmnopqrstuvwxyz0123"
r.type(long)
r.key("left", 25)
r.type("_")
paint()
do
    -- the two rows holding the input read back as prompt + edited text
    local rows = {}
    for y = 1, H do rows[#rows + 1] = row(y) end
    local joined
    for y = 1, H - 1 do
        if rows[y]:sub(1, 2) == "$ " and #rows[y] == W then joined = rows[y] .. rows[y + 1] end
    end
    assert(joined == "$ abcde_fghijklmnopqrstuvwxyz0123", tostring(joined))
end
r.enter()
assert(r.result() == "abcde_fghijklmnopqrstuvwxyz0123", r.result())

-- 5. Completion inserts at the cursor; masked input stays out of history.
term:write("$ ")
r = reading("*l", { history = history, complete = function(before)
    if before == "ech" then return { "echo" } end
    return {}
end })
r.type("ech"); r.send(9, 15); r.type(" hi"); r.enter()
assert(r.result() == "echo hi")
term:write("pw: ")
r = reading("*l", "*", { history = history })
r.type("secret"); paint()
assert(lastRow():find("pw: %*%*%*%*%*%*"), "mask shown: " .. lastRow())
r.enter()
assert(r.result() == "secret" and history[#history] == "echo hi", "masked input must not enter history")

-- 6. Raw mode: no echo, special keys as escape sequences, held keys repeat.
paint()
local before = lastRow()
r = reading(3, { raw = true })
r.key("up")
assert(r.result() == "\27[A")
r = reading(1, { raw = true })
r.type("q")
assert(r.result() == "q")
paint()
assert(lastRow() == before, "raw input is not echoed")

io.write("tty line edit tests passed\n")
