-- VT clear and the GPU color cache. OpenComputers keeps the foreground and
-- background color per buffer (the screen and each video RAM buffer), so a
-- color set on one buffer says nothing about another. Clearing must not
-- leave the view showing scrollback read back from /tmp/vtbuf either.
-- Run from the Nexus directory: lua tests/drivers/vt_clear.lua
local driverPath = "root/usr/lib/modules/system/kernel/drivers/tty/"
local W, H = 16, 5
local frames = { [0] = {}, [1] = {} }
local colors = { [0] = { fg = 0xFFFFFF, bg = 0 }, [1] = { fg = 0xFFFFFF, bg = 0 } }
local active = 0
local function key(x, y) return x .. ":" .. y end
local fileReads = 0

local gpu = {
    freeAllBuffers = function() frames[1] = {}; colors[1] = { fg = 0xFFFFFF, bg = 0 } end,
    allocateBuffer = function() return 1 end,
    maxResolution = function() return W, H end,
    setResolution = function() end,
    setViewport = function() end,
    setForeground = function(c) colors[active].fg = c end,
    getBackground = function() return colors[active].bg, false end,
    setBackground = function(c) colors[active].bg = c end,
    getActiveBuffer = function() return active end,
    setActiveBuffer = function(b) active = b end,
    set = function(x, y, text)
        for i = 1, #text do frames[active][key(x + i - 1, y)] = { text:sub(i, i), colors[active].bg } end
    end,
    fill = function(x, y, w, h, ch)
        for sy = y, y + h - 1 do for sx = x, x + w - 1 do
            frames[active][key(sx, sy)] = { ch, colors[active].bg }
        end end
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

-- /tmp/vtbuf in memory
local vtbuf = ""
local function file(mode)
    local pos = 0
    if mode == "w" then vtbuf = "" end
    return {
        seek = function(_, whence, offset)
            if whence == "end" then pos = #vtbuf + (offset or 0) else pos = offset or 0 end
            return pos
        end,
        read = function(_, n)
            fileReads = fileReads + 1
            local s = vtbuf:sub(pos + 1, pos + n)
            pos = pos + #s
            return s
        end,
        write = function(_, s) vtbuf = vtbuf .. s end,
        close = function() end,
    }
end

local devfsEnv = setmetatable({ vfsk = { createVNode = function() return {} end } }, { __index = _G })
assert(loadfile("src/fs/devfs.lua", "t", devfsEnv))()
local vt
local apis = {
    devfs = devfsEnv.devfs,
    filesystem = { open = function(_, mode) return file(mode) end, size = function() return #vtbuf end },
    component = { list = function() return function() return "gpu" end end, proxy = function() return gpu end },
    computer = { uptime = function() return 0 end },
    event = { pull = coroutine.yield, setForeground = function() end, getForeground = function() return 2 end },
    process = { get = function(pid) return pid == 2 and { instance = 1 } or nil end, getCurrentPID = function() return 2 end,
                getCurrent = function() return nil end },
    module = { require = function(name) return name == "vt" and vt.module or nil end },
    -- the debug module draws a red DEBUG label in the bottom right corner
    system = { config = { debug = true }, createKernelThread = function(fn) vt.repaint = coroutine.create(fn) end },
}
local env = setmetatable({ require = function(name) return assert(apis[name], name) end }, { __index = _G })
vt = assert(loadfile(driverPath .. "vt.lua", "t", env))()
vt.load()
-- development builds only: release branches drop the debug module
local debugChunk = loadfile("root/usr/lib/modules/system/kernel/debug.lua", "t", env)
local debugModule = debugChunk and debugChunk()
if debugModule then debugModule.load() end
local dev = vt.module.new(0)
dev:setInputCursor(2)

local function paint() assert(coroutine.resume(vt.repaint)) end
local function redCells()
    local n = 0
    for y = 1, H do for x = 1, W do
        local c = frames[0][key(x, y)]
        -- the DEBUG label itself is red
        if c and c[2] == 0xFF0000 and not (y == H and x >= W - 4) then n = n + 1 end
    end end
    return n
end
local function row(y)
    local t = {}
    for x = 1, W do local c = frames[0][key(x, y)]; t[x] = c and c[1] or " " end
    return (table.concat(t):gsub("%s+$", ""))
end

-- Enough output to push lines into the scrollback file.
for i = 1, 12 do dev:write("line " .. i .. "\n") end
paint()
assert(redCells() == 0, "only the label is red before clear")

-- clear, as /usr/bin/clear does (from a process, between two repaints)
dev:clear()
dev:write("$ ")
paint()
assert(redCells() == 0, "red background after clear: " .. redCells() .. " cells")
assert(row(1) == "$", "clear leaves the prompt at the top: [" .. row(1) .. "]")
for y = 2, H - 1 do assert(row(y) == "", "row " .. y .. " is empty after clear: " .. row(y)) end

-- Repaints after clear do not read the scrollback file over and over.
local before = fileReads
for i = 1, 3 do dev:write("x"); paint() end
assert(fileReads == before, "repaints read the scrollback file " .. (fileReads - before) .. " times")

-- ESC[2J blanks the screen but keeps the scrollback; ESC[3J drops it.
for i = 1, 12 do dev:write("more " .. i .. "\n") end
paint()
dev:write("\27[H\27[2J")
dev:write("top")
paint()
assert(row(1) == "top" and row(2) == "", "2J: " .. row(1) .. "/" .. row(2))
assert(#dev.line_positions > 0, "2J keeps the scrollback")
assert(redCells() == 0, "red after 2J")
dev:write("\27[3J")
assert(#dev.line_positions == 0, "3J drops the scrollback")

-- Scrolled back, rows from the file are read once, not on every repaint.
for i = 1, 20 do dev:write("old " .. i .. "\n") end
paint()
dev:scroll(-3)
paint()
before = fileReads
dev:write("y"); paint()
dev:write("z"); paint()
assert(fileReads - before <= 1, "scrolled-back rows are cached: " .. (fileReads - before) .. " reads")
assert(redCells() == 0, "red while scrolled back")

-- The DEBUG label is the debug module's: unloading it leaves the corner blank.
if debugModule then
    debugModule.unload()
    dev:write("w")
    paint()
    assert(row(H):sub(W - 4) ~= "DEBUG", "no label without the debug module")
end

print("vt clear tests passed")
