-- edit: the full-screen editor on a real tty/vt.
-- Run from the Nexus directory: lua tests/edit.lua
local driverPath = "root/usr/lib/modules/system/kernel/drivers/tty/"
local W, H = 40, 10
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


-- in-memory filesystem for the editor
local files = {}
local fsmock = {}
function fsmock.exists(p) return files[p] ~= nil end
function fsmock.isDirectory() return false end
function fsmock.concat(a, b) return (a .. "/" .. b):gsub("//+", "/") end
function fsmock.open(p, mode)
    if mode == "r" then
        if not files[p] then return nil, "no such file" end
        local data = files[p]
        return { read = function() local d = data; data = nil; return d end, close = function() end }
    end
    if files[p] == "READONLY" then return nil, "permission denied" end
    local parts = {}
    return { write = function(_, s) parts[#parts + 1] = s end,
             close = function() files[p] = table.concat(parts) end }
end

local source = assert(io.open("root/usr/bin/edit.lua")):read("a")
local function startEditor(...)
    local editorEnv = setmetatable({
        require = function(name)
            if name == "filesystem" then return fsmock end
            if name == "process" then return { cwd = function() return "/home" end } end
            error(name)
        end,
        component = { list = function() return function() return "gpu" end end,
                      proxy = function() return { getViewport = function() return W, H end } end },
        io = { read = function(...) return term:read(...) end,
               write = function(...) term:write(table.concat({ ... })) end,
               isatty = function() return true end,
               stderr = { write = function(_, s) error("stderr: " .. s) end } },
    }, { __index = _G })
    local chunk = assert(load(source, "=edit", "t", editorEnv))
    local co = coroutine.create(chunk)
    local result
    local args = table.pack(...)
    local function step(...)
        local r = table.pack(coroutine.resume(co, ...))
        assert(r[1], r[2])
        if coroutine.status(co) == "dead" then result = r[2] end
    end
    step(table.unpack(args, 1, args.n))
    local ed = {}
    local codes = { up = 200, down = 208, left = 203, right = 205, home = 199, ["end"] = 207, delete = 211 }
    function ed.send(char, code)
        assert(coroutine.status(co) == "suspended", "editor exited")
        step("key_down", "kb", char, code or 30)
        if coroutine.status(co) == "suspended" then step("key_up", "kb", char, code or 30)
        else term.pressing[code or 30] = false end
    end
    function ed.type(text) for i = 1, #text do ed.send(text:byte(i), 30) end end
    function ed.key(name, n) for _ = 1, n or 1 do ed.send(0, codes[name]) end end
    function ed.ctrl(letter) ed.send(letter:byte() - 96, 31) end
    function ed.enter() ed.send(13, 28) end
    function ed.done() return coroutine.status(co) == "dead", result end
    return ed
end

local function screenRows()
    paint()
    local rows = {}
    for y = 1, H do rows[y] = row(y) end
    return rows
end

term:write("before$ ")
paint()
local shellRow = lastRow()

-- 1. New file: typing, auto-indent, save.
local ed = startEditor("notes.txt")
local rows = screenRows()
assert(rows[H]:find("New file"), rows[H])
ed.type("hello"); ed.enter()
ed.type("  world"); ed.enter()
ed.type("x")
ed.ctrl("s")
assert(files["/home/notes.txt"] == "hello\n  world\n  x\n", files["/home/notes.txt"])
rows = screenRows()
assert(rows[1] == "hello" and rows[2] == "  world" and rows[3] == "  x", rows[3])
assert(rows[H]:find("Saved 3 lines"), rows[H])

-- 2. Cut / paste lines, delete, navigation.
ed.key("up", 2); ed.key("home")
ed.ctrl("k")                    -- cut "hello"
ed.key("down"); ed.ctrl("u")    -- paste above "  x"; the cursor ends below it
ed.key("home"); ed.key("delete")  -- deletes the first blank of "  x"
ed.ctrl("s")
assert(files["/home/notes.txt"] == "  world\nhello\n x\n", files["/home/notes.txt"])

-- 3. Find.
ed.ctrl("f"); ed.type("x"); ed.enter()
rows = screenRows()
assert(rows[H]:find("Ln 3, Col 2"), rows[H])

-- 4. Closing with unsaved changes needs a second ^W; the shell comes back.
ed.type("!")
ed.ctrl("w")
assert(not ed.done(), "first ^W must not discard changes")
assert(screenRows()[H]:find("Unsaved!"), screenRows()[H])
ed.ctrl("w")
local finished = ed.done()
assert(finished, "second ^W closes")
assert(files["/home/notes.txt"] == "  world\nhello\n x\n", "discarded edit was not saved")
paint()
assert(lastRow() == shellRow, "main screen restored: " .. lastRow())

-- 5. Read-only mode and long lines.
files["/etc/motd"] = ("abcdefghij"):rep(6) .. "\nsecond\n"
ed = startEditor("-r", "/etc/motd")
ed.type("zzz"); ed.ctrl("k")
ed.key("end")
rows = screenRows()
assert(rows[1] == ("abcdefghij"):rep(6):sub(-W + 1), "horizontal scroll: " .. rows[1])
assert(rows[H]:find("%[ro%]"))
ed.ctrl("s")
assert(screenRows()[H]:find("Read%-only"))
ed.ctrl("w")
assert(ed.done(), "unmodified file closes at once")
assert(files["/etc/motd"] == ("abcdefghij"):rep(6) .. "\nsecond\n")

io.write("edit tests passed\n")
