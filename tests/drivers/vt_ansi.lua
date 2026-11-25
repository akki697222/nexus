-- VT escape sequences used by full-screen programs (edit).
-- Run from nexus with: lua tests/drivers/vt_ansi.lua
local VT = "root/usr/lib/modules/system/kernel/drivers/tty/vt.lua"

-- Loads a vt.lua implementation against mock OC components and counts calls.
local H = {}

function H.load(path, opts)
    opts = opts or {}
    local W, HH = opts.width or 80, opts.height or 25
    local calls = { gpu = {}, fs = {} }
    local function count(kind, name) calls[kind][name] = (calls[kind][name] or 0) + 1 end
    local function newBuf(w, h)
        local b = { w = w, h = h, cells = {} }
        for y = 1, h do
            b.cells[y] = {}
            for x = 1, w do b.cells[y][x] = { " ", 0xFFFFFF, 0x000000 } end
        end
        return b
    end
    local buffers = { [0] = newBuf(W, HH) }
    local active, fgc, bgc, nextBuf = 0, 0xFFFFFF, 0x000000, 1
    local gpu = {}
    local function put(b, x, y, ch)
        if x >= 1 and x <= b.w and y >= 1 and y <= b.h then b.cells[y][x] = { ch, fgc, bgc } end
    end
    local G = {
        freeAllBuffers = function() for k in pairs(buffers) do if k ~= 0 then buffers[k] = nil end end active = 0 end,
        allocateBuffer = function() local n = nextBuf; nextBuf = nextBuf + 1; buffers[n] = newBuf(W, HH); return n end,
        maxResolution = function() return W, HH end,
        setResolution = function() return true end,
        setViewport = function() return true end,
        getActiveBuffer = function() return active end,
        setActiveBuffer = function(n) active = n; return true end,
        setForeground = function(c) local o = fgc; fgc = c; return o end,
        setBackground = function(c) local o = bgc; bgc = c; return o end,
        getBackground = function() return bgc, false end,
        fill = function(x, y, w, h, ch)
            local b = buffers[active]
            for yy = y, y + h - 1 do for xx = x, x + w - 1 do put(b, xx, yy, ch) end end
            return true
        end,
        set = function(x, y, s)
            local b = buffers[active]
            for i = 1, #s do put(b, x + i - 1, y, s:sub(i, i)) end
            return true
        end,
        copy = function(x, y, w, h, tx, ty)
            local b = buffers[active]
            local snap = {}
            for yy = y, y + h - 1 do
                snap[yy] = {}
                for xx = x, x + w - 1 do
                    if b.cells[yy] and b.cells[yy][xx] then snap[yy][xx] = b.cells[yy][xx] end
                end
            end
            for yy, row in pairs(snap) do
                for xx, cell in pairs(row) do
                    local ny, nx = yy + ty, xx + tx
                    if ny >= 1 and ny <= b.h and nx >= 1 and nx <= b.w then b.cells[ny][nx] = cell end
                end
            end
            return true
        end,
        bitblt = function(dst, col, row, w, h, src, fromCol, fromRow)
            local d, s = buffers[dst or 0], buffers[src]
            for dy = 0, h - 1 do
                for dx = 0, w - 1 do
                    local sy, sx = (fromRow or 1) + dy, (fromCol or 1) + dx
                    local ty, tx = row + dy, col + dx
                    if s.cells[sy] and s.cells[sy][sx] and ty >= 1 and ty <= d.h and tx >= 1 and tx <= d.w then
                        d.cells[ty][tx] = s.cells[sy][sx]
                    end
                end
            end
            return true
        end,
    }
    for name, fn in pairs(G) do gpu[name] = function(...) count("gpu", name) return fn(...) end end

    local files = {}
    local fsmock = {}
    function fsmock.open(path, mode)
        count("fs", "open")
        if mode == "r" and not files[path] then return nil, "no such file" end
        if mode == "w" then files[path] = "" end
        files[path] = files[path] or ""
        local pos = (mode == "a") and #files[path] or 0
        local f = {}
        function f:seek(whence, off)
            count("fs", "seek")
            if whence == "set" then pos = off elseif whence == "end" then pos = #files[path] + (off or 0) else pos = pos + (off or 0) end
            return pos
        end
        function f:read(n)
            count("fs", "read")
            if pos >= #files[path] then return nil end
            local s = files[path]:sub(pos + 1, pos + n); pos = pos + #s; return s
        end
        function f:write(s)
            count("fs", "write")
            files[path] = files[path]:sub(1, pos) .. s .. files[path]:sub(pos + #s + 1); pos = pos + #s; return true
        end
        function f:close() count("fs", "close") end
        return f
    end
    function fsmock.size(path) return #(files[path] or "") end

    local now = 0
    local env = {}
    local modules = {
        devfs = { create = function() end },
        module = {},
        filesystem = fsmock,
        component = { proxy = function() return gpu end, list = function() return function() return "gpu" end end },
        system = { config = { debug = opts.debug ~= false, console_vt_debug = opts.vtdebug or false },
                   createKernelThread = function() end },
        computer = { uptime = function() return now end },
        event = { getForeground = function() return env.fg end },
        process = { get = function(pid) if pid then return { instance = 1 } end end },
    }
    local sandbox = setmetatable({ require = function(n) return assert(modules[n], n) end }, { __index = _G })
    local chunk = assert(loadfile(path, "t", sandbox))
    local mod = chunk()
    local dev = mod.module.new(0)
    return {
        dev = dev, calls = calls, screen = buffers[0], buffers = buffers,
        setTime = function(t) now = t end, env = env,
        reset = function() calls.gpu, calls.fs = {}, {} end,
        total = function()
            local t = 0
            for _, k in pairs({ "gpu", "fs" }) do for _, v in pairs(calls[k]) do t = t + v end end
            return t
        end,
    }
end

function H.dump(screen)
    local rows = {}
    for y = 1, screen.h do
        local r = {}
        for x = 1, screen.w do local c = screen.cells[y][x]; r[x] = c[1] .. string.format("%06X%06X", c[2], c[3]) end
        rows[y] = table.concat(r, "|")
    end
    return rows
end


local function rowText(screen, y)
    local t = {}
    for x = 1, screen.w do t[x] = screen.cells[y][x][1] end
    return (table.concat(t):gsub("%s+$", ""))
end

local vt = H.load(VT, { width = 30, height = 8, debug = false })
local dev, scr = vt.dev, vt.screen
for i = 1, 5 do dev:write("line " .. i .. "\n") end
dev:write("$ ")
dev:update()
assert(rowText(scr, 1) == "line 1" and rowText(scr, 6) == "$")

-- alternate screen: blank canvas, absolute positioning, no autowrap
dev:write("\27[?1049h\27[2J")
dev:write("\27[3;5Hhello")
dev:write("\27[1;1H\27[7m status \27[0m")
dev:write("\27[8;25H" .. ("x"):rep(20)) -- clipped at the right edge
dev:update()
assert(rowText(scr, 1) == " status", rowText(scr, 1))
assert(scr.cells[1][2][3] == 0xFFFFFF and scr.cells[1][2][2] == 0x000000, "inverse video")
assert(rowText(scr, 3) == "    hello", rowText(scr, 3))
assert(rowText(scr, 8) == (" "):rep(24) .. ("x"):rep(6), "no wrap on the alternate screen")
assert(rowText(scr, 6) == "", "main screen hidden")

-- overwrite in place and erase to end of line
dev:write("\27[3;7HL\27[K")
dev:update()
assert(rowText(scr, 3) == "    heL", rowText(scr, 3))

-- leaving restores the main screen and its cursor
dev:write("\27[?1049l")
dev:update()
assert(rowText(scr, 1) == "line 1" and rowText(scr, 6) == "$", rowText(scr, 6))
dev:write("ok")
dev:update()
assert(rowText(scr, 6) == "$ ok")

-- carriage return overwrites (progress lines)
dev:write("\n50%\r100%\n")
dev:update()
assert(rowText(scr, 7) == "100%", rowText(scr, 7))

-- an unterminated sequence does not hang
dev:write("\27[12")
io.write("vt ansi tests passed\n")
