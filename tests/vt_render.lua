-- VT rendering: what reaches the screen, and how many component calls it
-- takes. Run from nexus with: lua tests/vt_render.lua
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

for _, size in ipairs({ { 80, 25 }, { 160, 50 } }) do
    local w, h = size[1], size[2]
    local vt = H.load(VT, { width = w, height = h, debug = true })
    local dev = vt.dev

    -- 1. Output fills the screen and scrolls; the window shows the last rows.
    for l = 1, h + 5 do dev:write(("\27[3%dmline %03d\27[0m\n"):format(l % 7 + 1, l)) end
    dev:write("\27[32muser@nexus\27[0m:~$ ")
    dev:update()
    local first = (h + 6) - h + 1 -- logical lines: h+5 output + prompt
    assert(rowText(vt.screen, 1) == ("line %03d"):format(first), rowText(vt.screen, 1))
    assert(rowText(vt.screen, h - 1) == ("line %03d"):format(h + 5))
    assert(rowText(vt.screen, h):find("^user@nexus:~%$"), rowText(vt.screen, h))
    assert(vt.screen.cells[1][1][2] == ({ [1]=0xFF0000,[2]=0x00FF00,[3]=0xFFFF00,[4]=0x0000FF,[5]=0xFF00FF,[6]=0x00FFFF,[7]=0xFFFFFF })[first % 7 + 1],
        "colors must survive")
    assert(rowText(vt.screen, h):sub(-5) == "DEBUG", "debug marker on the last row")

    -- 2. Typing costs a handful of calls per key, not a screen redraw.
    local worst = 0
    for i = 1, 30 do
        vt.reset()
        dev:write(string.char(97 + i % 26))
        dev:update()
        worst = math.max(worst, vt.total())
    end
    assert(worst <= 25, "a keystroke took " .. worst .. " component calls")
    assert(rowText(vt.screen, h):find("~%$ bcdefghijklmnopqrstuvwxyzabcde"), rowText(vt.screen, h))
    vt.reset()
    dev:backspace(3)
    dev:update()
    assert(vt.total() <= 25)
    assert(rowText(vt.screen, h):find("~%$ bcdefghijklmnopqrstuvwxyzab%s"), rowText(vt.screen, h))

    -- 3. A new output line scrolls with a buffer copy, not a full redraw.
    vt.reset()
    dev:write("\nnext\n")
    dev:update()
    assert((vt.calls.gpu.copy or 0) >= 1 and vt.total() <= 40, "scroll took " .. vt.total() .. " calls")
    assert(rowText(vt.screen, h - 1) == "next")

    -- 4. Scrollback shows older lines read from /tmp/vtbuf, and returns.
    dev:scroll(5)
    dev:update()
    assert(rowText(vt.screen, 1) == ("line %03d"):format(first - 3), rowText(vt.screen, 1))
    dev:scroll(-100)
    dev:update()
    assert(rowText(vt.screen, h - 1) == "next")

    -- 5. Idle updates cost nothing.
    vt.reset()
    dev:update()
    assert(vt.total() == 0, "idle update made " .. vt.total() .. " calls")
end

io.write("vt render tests passed\n")
