-- Run from the Nexus directory: lua tests/tty_cursor.lua
local driverPath = "root/usr/lib/modules/system/kernel/drivers/tty/"
local now, foreground = 0, -1
local owner = { instance = 10 }
local active, background = 0, 0
local frames = { [0] = {}, [1] = {} }
local fullFrames = 0
local repaint

local function key(x, y) return x .. ":" .. y end
local gpu = {
    freeAllBuffers = function() frames[1] = {} end,
    allocateBuffer = function() return 1 end,
    maxResolution = function() return 20, 5 end,
    setResolution = function() end,
    setViewport = function() end,
    setForeground = function() end,
    getBackground = function() return background, false end,
    setBackground = function(color) background = color end,
    getActiveBuffer = function() return active end,
    setActiveBuffer = function(buffer) active = buffer end,
    set = function(x, y, text) frames[active][key(x, y)] = { text, background } end,
    fill = function(x, y, w, h, text)
        for sy = y, y + h - 1 do
            for sx = x, x + w - 1 do frames[active][key(sx, sy)] = { text, background } end
        end
    end,
    bitblt = function(to, x, y, w, h, from, sx, sy)
        if w > 1 then fullFrames = fullFrames + 1 end
        for dy = 0, h - 1 do
            for dx = 0, w - 1 do
                frames[to][key(x + dx, y + dy)] = frames[from][key(sx + dx, sy + dy)]
            end
        end
    end,
}

local vt
local devfsEnv = setmetatable({
    vfsk = { createVNode = function() return {} end },
}, { __index = _G })
assert(loadfile("src/devfs.lua", "t", devfsEnv))()
local devfs = devfsEnv.devfs
local apis = {
    devfs = devfs,
    filesystem = { open = function() return nil end },
    component = { list = function() return function() return "gpu" end end, proxy = function() return gpu end },
    computer = { uptime = function() return now end },
    event = {
        pull = coroutine.yield,
        setForeground = function(pid) foreground = pid end,
        getForeground = function() return foreground end,
    },
    process = { get = function(pid) return pid == 2 and owner or nil end, getCurrentPID = function() return 2 end },
    module = { require = function() return vt.module end },
    system = { config = {}, createKernelThread = function(fn) repaint = coroutine.create(fn) end },
}
local env = setmetatable({ require = function(name) return assert(apis[name], name) end }, { __index = _G })
vt = assert(loadfile(driverPath .. "vt.lua", "t", env))()
vt.load()
local tty = assert(loadfile(driverPath .. "tty.lua", "t", env))().module
local terminal = tty.new(0)
terminal:write("$ ")

local function tick() assert(coroutine.resume(repaint)) end
local function cellBackground(x, y) return frames[0][key(x, y)][2] end
local text
local input = assert(devfs.open("/tty0", "r"))
local reader = coroutine.create(function() text = devfs.read(input, "*l") end)
assert(coroutine.resume(reader))
tick()
assert(cellBackground(3, 1) == 0xFFFFFF)
local framesBeforeIdle = fullFrames
now = 0.5
tick()
assert(cellBackground(3, 1) == 0)
now = 1.0
tick()
assert(cellBackground(3, 1) == 0xFFFFFF and fullFrames == framesBeforeIdle)

now = 1.6
assert(coroutine.resume(reader, "key_down", "keyboard", string.byte("A"), 30))
tick()
assert(frames[0][key(3, 1)][1] == "A" and cellBackground(3, 1) == 0)
assert(cellBackground(4, 1) == 0xFFFFFF)
assert(coroutine.resume(reader, "key_down", "keyboard", 13, 28))
tick()
assert(text == "A" and cellBackground(4, 1) == 0)
devfs.close(input)

reader = coroutine.create(function() terminal:read("*l") end)
assert(coroutine.resume(reader))
tick()
assert(cellBackground(1, 2) == 0xFFFFFF)
foreground = 5
tick()
assert(cellBackground(1, 2) == 0)
foreground = 2
tick()
assert(cellBackground(1, 2) == 0xFFFFFF)
owner = { instance = 11 }
tick()
assert(cellBackground(1, 2) == 0)
print("TTY cursor blink tests passed")

local ttyOutput = assert(devfs.open("/tty0", "w"))
local vtOutput = assert(devfs.open("/ttyv0", "w"))
assert(devfs.write(ttyOutput, "tty pipe test\n"))
assert(devfs.write(vtOutput, "vt pipe test\n"))
devfs.close(ttyOutput)
devfs.close(vtOutput)
tick()
assert(frames[0][key(1, 2)][1] == "t")
assert(frames[0][key(1, 3)][1] == "v")
print("TTY device file I/O tests passed")
