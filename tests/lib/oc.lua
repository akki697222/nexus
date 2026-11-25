-- tests/lib/oc.lua - an OpenComputers machine for host tests of code that
-- runs without an OS (the installer): filesystems in memory, a GPU whose
-- screen can be read back, an internet card serving a table, a data card,
-- and a signal queue fed by the test.
--
--   local oc = dofile("tests/lib/oc.lua")
--   local disk = oc.filesystem("disk-a", { label = "a" })
--   local m = oc.machine({ boot = disk, components = { disk, oc.gpu() } })
--   m.keys("hello", "enter")      -- queues key_down signals
--   local ok, why = m.run(source, ...)  -- runs a chunk with m.env as _ENV
--   why == "reboot" / "poweroff" when the chunk called computer.shutdown

local oc = {}

local function norm(path)
    path = ("/" .. path):gsub("//+", "/")
    if #path > 1 then path = path:gsub("/$", "") end
    return path
end

local function parentOf(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir == nil or dir == "" then return "/" end
    return dir
end

-- An in-memory filesystem component. Reads return at most 2048 bytes, as
-- OC's do. t.files[path] is the content, t.dirs[path] true.
function oc.filesystem(address, opts)
    opts = opts or {}
    local t = { address = address, type = "filesystem", files = {}, dirs = { ["/"] = true },
        label = opts.label, readOnly = opts.readOnly or false, total = opts.total or 4 * 1024 * 1024 }
    local handles, nh = {}, 0
    local p = { address = address, type = "filesystem" }
    t.proxy = p
    local function used()
        local n = 0
        for _, data in pairs(t.files) do n = n + #data end
        return n
    end
    function p.spaceTotal() return t.total end
    function p.spaceUsed() return used() end
    function p.isReadOnly() return t.readOnly end
    function p.getLabel() return t.label end
    function p.setLabel(label) t.label = label return label end
    function p.exists(path) path = norm(path) return t.files[path] ~= nil or t.dirs[path] == true end
    function p.isDirectory(path) return t.dirs[norm(path)] == true end
    function p.size(path) return #(t.files[norm(path)] or "") end
    function p.lastModified(path) return p.exists(path) and 1767225600000 or 0 end
    function p.makeDirectory(path)
        path = norm(path)
        if t.readOnly or t.files[path] or t.dirs[path] then return false end
        local d = path
        while d ~= "/" do
            if t.files[d] then return false end
            t.dirs[d] = true
            d = parentOf(d)
        end
        return true
    end
    function p.list(path)
        path = norm(path)
        if not t.dirs[path] then return nil, "no such directory" end
        local out = {}
        for f in pairs(t.files) do if f ~= path and parentOf(f) == path then out[#out + 1] = f:match("[^/]+$") end end
        for d in pairs(t.dirs) do if d ~= path and parentOf(d) == path then out[#out + 1] = d:match("[^/]+$") .. "/" end end
        table.sort(out)
        return out
    end
    function p.remove(path)
        path = norm(path)
        if t.readOnly then return false end
        if t.files[path] then t.files[path] = nil return true end
        if t.dirs[path] and path ~= "/" then
            local prefix = path .. "/"
            for f in pairs(t.files) do if f:sub(1, #prefix) == prefix then t.files[f] = nil end end
            for d in pairs(t.dirs) do if d:sub(1, #prefix) == prefix then t.dirs[d] = nil end end
            t.dirs[path] = nil
            return true
        end
        return false
    end
    function p.rename(from, to)
        from, to = norm(from), norm(to)
        if t.readOnly or not t.files[from] or t.files[to] or t.dirs[to] or not t.dirs[parentOf(to)] then return false end
        t.files[to], t.files[from] = t.files[from], nil
        return true
    end
    function p.open(path, mode)
        path = norm(path)
        mode = mode or "r"
        if mode:find("[wa]") then
            if t.readOnly then return nil, "read-only" end
            if t.dirs[path] or not t.dirs[parentOf(path)] then return nil, path .. ": no such directory" end
            if mode:find("w") or not t.files[path] then t.files[path] = "" end
            if t.failWrites and path:match(t.failWrites) then return nil, "injected failure" end
        elseif not t.files[path] then
            return nil, path
        end
        nh = nh + 1
        handles[nh] = { path = path, pos = mode:find("a") and #t.files[path] or 0, mode = mode }
        return nh
    end
    function p.read(h, n)
        local o = handles[h]
        if not o then return nil, "bad handle" end
        local data = t.files[o.path]
        if o.pos >= #data then return nil end
        n = math.min(n == math.huge and 2048 or n, 2048)
        local chunk = data:sub(o.pos + 1, o.pos + n)
        o.pos = o.pos + #chunk
        return chunk
    end
    function p.write(h, data)
        local o = handles[h]
        if not o then return nil, "bad handle" end
        local cur = t.files[o.path]
        t.files[o.path] = cur:sub(1, o.pos) .. data .. cur:sub(o.pos + #data + 1)
        o.pos = o.pos + #data
        return true
    end
    function p.seek(h, whence, offset)
        local o = handles[h]
        local base = whence == "set" and 0 or whence == "end" and #t.files[o.path] or o.pos
        o.pos = base + (offset or 0)
        return o.pos
    end
    function p.close(h) handles[h] = nil end
    -- test helpers
    function t.put(path, data)
        path = norm(path)
        p.makeDirectory(parentOf(path))
        t.files[path] = data
    end
    function t.get(path) return t.files[norm(path)] end
    return t
end

-- A GPU and screen; t.text(y) is a row of the screen, t.dump() all rows.
function oc.gpu(opts)
    opts = opts or {}
    local W, H = opts.w or 80, opts.h or 25
    local depth = opts.depth or 8
    local t = { address = "gpu", type = "gpu", rows = {} }
    local p = { address = "gpu", type = "gpu" }
    t.proxy = p
    local function blank()
        for y = 1, H do
            t.rows[y] = {}
            for x = 1, W do t.rows[y][x] = " " end
        end
    end
    blank()
    function p.bind() return true end
    function p.maxResolution() return W, H end
    function p.getResolution() return t.w or W, t.h or H end
    function p.setResolution(w, h) t.w, t.h = w, h return true end
    function p.getDepth() return depth end
    function p.setForeground() end
    function p.setBackground() end
    function p.set(x, y, s)
        if not t.rows[y] then return end
        local i = 0
        for _, c in utf8.codes(s) do
            if t.rows[y][x + i] then t.rows[y][x + i] = utf8.char(c) end
            i = i + 1
        end
    end
    function p.fill(x, y, w, h, c)
        for row = y, y + h - 1 do
            for col = x, x + w - 1 do
                if t.rows[row] and t.rows[row][col] then t.rows[row][col] = c end
            end
        end
    end
    function t.text(y) return table.concat(t.rows[y]) end
    function t.dump()
        local out = {}
        for y = 1, H do out[y] = t.text(y) end
        return table.concat(out, "\n")
    end
    function t.find(s) return t.dump():find(s, 1, true) ~= nil end
    return t
end

function oc.screen()
    return { address = "screen", type = "screen", proxy = { address = "screen", type = "screen" } }
end

-- An internet card; pages[url] is the body (a missing url answers 404).
function oc.internet(pages)
    local t = { address = "inet", type = "internet", pages = pages, requests = {} }
    local p = { address = "inet", type = "internet" }
    t.proxy = p
    function p.request(url)
        t.requests[#t.requests + 1] = url
        local body = pages[url]
        local pos = 0
        local h = {}
        function h.finishConnect() return true end
        function h.response() if body then return 200, "OK" end return 404, "Not Found" end
        function h.read(n)
            if not body then return nil, "404" end
            if pos >= #body then return nil end
            local chunk = body:sub(pos + 1, pos + math.min(n, 4096))
            pos = pos + #chunk
            return chunk
        end
        function h.close() end
        return h
    end
    return t
end

function oc.data(inflate)
    local t = { address = "data", type = "data", calls = 0 }
    t.proxy = { address = "data", type = "data", inflate = function(z)
        t.calls = t.calls + 1
        return inflate(z)
    end }
    return t
end

local CODES = { enter = 28, esc = 1, up = 200, down = 208, left = 203, right = 205, tab = 15,
    back = 14, space = 57, home = 199, ["end"] = 207 }

-- A machine: env is the global environment a BIOS-booted chunk sees.
-- opts.boot: the boot filesystem; opts.components: everything attached;
-- opts.os: also give require/io/print (a program run by an OS).
function oc.machine(opts)
    local m = { signals = {}, bootAddress = opts.boot.address, tmp = oc.filesystem("tmpfs") }
    local list = { opts.boot, m.tmp }
    for _, c in ipairs(opts.components or {}) do
        if c ~= opts.boot then list[#list + 1] = c end
    end
    m.components = list
    local byAddress = {}
    for _, c in ipairs(list) do byAddress[c.address] = c end
    local component = {}
    function component.list(kind)
        local i = 0
        return function()
            while true do
                i = i + 1
                local c = list[i]
                if not c then return nil end
                if not kind or c.type == kind then return c.address, c.type end
            end
        end
    end
    function component.proxy(address)
        local c = byAddress[address]
        return c and c.proxy
    end
    function component.type(address)
        local c = byAddress[address]
        return c and c.type
    end
    function component.invoke(address, method, ...)
        local c = byAddress[address]
        if not c then error("no such component " .. tostring(address)) end
        return c.proxy[method](...)
    end
    local computer = {}
    local uptime = 0
    function computer.uptime() uptime = uptime + 0.05 return uptime end
    function computer.getBootAddress() return m.bootAddress end
    function computer.setBootAddress(a) m.bootAddress = a end
    function computer.tmpAddress() return m.tmp.address end
    function computer.freeMemory() return 1024 * 1024 end
    function computer.totalMemory() return 2 * 1024 * 1024 end
    -- Queued keys answer the waits for input (no timeout) only: the user
    -- types when asked, not while the installer polls during its work.
    function computer.pullSignal(timeout)
        if timeout ~= nil then return nil end
        local s = table.remove(m.signals, 1)
        if s then return table.unpack(s, 1, s.n) end
        error({ waiting = true }, 0)
    end
    function computer.shutdown(reboot) error({ shutdown = reboot and "reboot" or "poweroff" }, 0) end
    function computer.beep() end
    m.component, m.computer = component, computer

    local env = {}
    for _, name in ipairs({ "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "select",
        "tonumber", "tostring", "type", "rawequal", "rawget", "rawlen", "rawset", "setmetatable",
        "getmetatable", "load", "string", "table", "math", "utf8", "coroutine", "os", "debug" }) do
        env[name] = _G[name]
    end
    env._G = env
    env.component, env.computer = component, computer
    env.unicode = { len = utf8.len, sub = string.sub }
    if opts.os then
        local loaded = { component = component, computer = computer }
        env.require = function(name)
            if loaded[name] then return loaded[name] end
            error("module '" .. name .. "' not found")
        end
        env.package = { loaded = loaded }
        env.io = opts.io or io
        env.print = opts.print or print
        if opts.noRawApi then
            env.component, env.computer = nil, nil
            loaded.component, loaded.computer = nil, nil
        end
    end
    m.env = env

    -- queues key presses: strings are typed, names are keys
    function m.keys(...)
        for _, k in ipairs({ ... }) do
            if CODES[k] then
                m.signals[#m.signals + 1] = table.pack("key_down", "kbd", 0, CODES[k], "player")
            else
                for i = 1, #k do
                    m.signals[#m.signals + 1] = table.pack("key_down", "kbd", k:byte(i), 0, "player")
                end
            end
        end
    end

    -- Runs source in env. Returns true and the results, or false and
    -- "reboot"/"poweroff"/"waiting" or the error.
    function m.run(source, ...)
        local chunk = assert(load(source, opts.chunkname or "=nexus-install.lua", "t", env))
        local r = table.pack(xpcall(chunk, function(e)
            if type(e) == "table" then return e end
            return debug.traceback(tostring(e), 2)
        end, ...))
        if r[1] then return true, table.unpack(r, 2, r.n) end
        local e = r[2]
        if type(e) == "table" and e.shutdown then return false, e.shutdown end
        if type(e) == "table" and e.waiting then return false, "waiting" end
        return false, e
    end
    return m
end

return oc
