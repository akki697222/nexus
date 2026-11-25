-- debugcon: kernel debug consoles, output only (like Linux earlycon and
-- netconsole). Every kernel log line (printk, system.log, panics) also goes
-- to each console that is present:
--
--   ocelot  the Ocelot card's log window (Ocelot Desktop, component "ocelot")
--   serial  a serial port (component "serial": tools/headless)
--   tcp     a TCP server through an internet card (tools/debugserver)
--
-- Configured by debug_console in /boot/config.lua. A console that appears
-- later (hotplug, or a TCP connection that just came up) first gets the
-- lines still held in the klog ring, so it sees the boot from the start.

---@class debugcon
debugcon = {}

-- one block: the kernel is a single chunk, which allows 200 locals in all
do

-- Bytes waiting for the TCP server, at most this many (oldest dropped).
debugcon.TCP_BUFFER = 16384
-- Seconds between connection attempts after a failure.
debugcon.TCP_RETRY = 5
-- Seconds a connection may take. The internet card closes a socket it could
-- not connect (a refused port, a filtered address) without an error, and
-- finishConnect only keeps answering false then.
debugcon.TCP_CONNECT_TIMEOUT = 10

local consoles = {}     -- address or "tcp" -> { kind, write = function(text) }
local emitting = false  -- set while a line goes out
local warnings = {}     -- console failures while emitting, logged after it

local function settings()
    local c = config and config.debug_console
    if c == false then return { ocelot = false, serial = false } end
    if type(c) ~= "table" then c = {} end
    return {
        ocelot = c.ocelot ~= false,
        serial = c.serial ~= false,
        tcp = type(c.tcp) == "string" and c.tcp ~= "" and c.tcp or nil,
        level = klog.LEVELS[c.level] or klog.LEVELS.debug,
    }
end

---@param e klog_entry
local function format(e)
    local who = e.tag .. (e.pid and ("[" .. e.pid .. "]") or "")
    return string.format("[%8.2f] %-7s %s: %s\n", e.uptime, e.level, who, e.msg)
end

local function wanted(e)
    return (klog.LEVELS[e.level] or 6) <= settings().level
end

-- Logs a console failure; while a line is going out it waits until the
-- line is done, so it reaches the consoles that still work.
local function warn(msg)
    if emitting then
        warnings[#warnings + 1] = msg
    else
        klog.record("warning", "kernel", msg)
    end
end

-- Writes text to one console; a console that fails is dropped.
local function send(key, text)
    local con = consoles[key]
    if not con then return end
    local ok, err = pcall(con.write, text)
    if not ok then
        consoles[key] = nil
        if con.close then pcall(con.close) end
        warn("debugcon: " .. con.kind .. " dropped: " .. tostring(err))
    end
end

-- Every line held in the klog ring, for a console that just came up.
local function replay(key)
    local entries = klog.read(0)
    local parts = {}
    for _, e in ipairs(entries) do
        if wanted(e) then parts[#parts + 1] = format(e) end
    end
    if #parts > 0 then send(key, table.concat(parts)) end
end

-- Called by klog for each new entry.
---@param e klog_entry
function debugcon.emit(e)
    if emitting or not next(consoles) or not wanted(e) then return end
    emitting = true
    local text = format(e)
    for key in pairs(consoles) do send(key, text) end
    emitting = false
    while #warnings > 0 do klog.record("warning", "kernel", table.remove(warnings, 1)) end
end

-- ---------------------------------------------------------------- ocelot, serial

local function attachComponent(address, kind)
    if consoles[address] then return end
    local method = kind == "ocelot" and "log" or "write"
    local con = { kind = kind }
    if kind == "ocelot" then
        -- one log entry per line, without the newline
        con.write = function(text)
            for line in text:gmatch("[^\n]+") do component.invoke(address, method, line) end
        end
    else
        con.write = function(text) component.invoke(address, method, text) end
    end
    consoles[address] = con
    replay(address)
end

-- ---------------------------------------------------------------- tcp

local tcp = nil   -- { host, port, socket, connected, buffer, retryAt }

local function tcpTarget(spec)
    local host, port = spec:match("^(.+):(%d+)$")
    port = tonumber(port)
    if not host or not port then return nil end
    return host, port
end

local function tcpClose(reason)
    if not tcp then return end
    if tcp.socket then pcall(tcp.socket.close) end
    if tcp.connected then
        consoles.tcp = nil
        warn("debugcon: tcp " .. tcp.host .. ":" .. tcp.port .. " lost: " .. tostring(reason))
    elseif tostring(reason) ~= tcp.lastError then
        -- a failed attempt is logged once per reason, not every retry
        warn("debugcon: tcp " .. tcp.host .. ":" .. tcp.port .. ": " .. tostring(reason))
    end
    tcp.lastError = tostring(reason)
    tcp.socket, tcp.connected = nil, false
    tcp.retryAt = computer.uptime() + debugcon.TCP_RETRY
end

local function tcpAppend(text)
    local buffer = tcp.buffer .. text
    if #buffer > debugcon.TCP_BUFFER then
        buffer = "[debugcon: output dropped]\n" .. buffer:sub(-debugcon.TCP_BUFFER)
    end
    tcp.buffer = buffer
end

-- Connects, then sends what is buffered. Called every kernel loop pass and
-- by flush(); socket calls are not direct, so each one takes a tick.
local function tcpTick()
    if not tcp then return end
    if not tcp.socket then
        if computer.uptime() < tcp.retryAt then return end
        local inet = component.list("internet")()
        if not inet then return end
        local ok, socket = pcall(component.invoke, inet, "connect", tcp.host, tcp.port)
        if not ok or not socket then
            tcpClose(ok and "connect failed" or socket)
            return
        end
        tcp.socket, tcp.connected = socket, false
        tcp.deadline = computer.uptime() + debugcon.TCP_CONNECT_TIMEOUT
    end
    if not tcp.connected then
        local ok, done = pcall(tcp.socket.finishConnect)
        if not ok then tcpClose(done) return end
        if not done then
            if computer.uptime() >= tcp.deadline then tcpClose("no connection (refused or not allowed)") end
            return
        end
        tcp.connected = true
        tcp.buffer = ""
        consoles.tcp = { kind = "tcp", write = tcpAppend }
        replay("tcp")
    end
    while #tcp.buffer > 0 do
        local ok, n = pcall(tcp.socket.write, tcp.buffer:sub(1, 4096))
        if not ok then tcpClose(n) return end
        if not n or n <= 0 then return end
        tcp.buffer = tcp.buffer:sub(n + 1)
    end
end

-- ---------------------------------------------------------------- kernel hooks

-- Attaches the consoles that are present (at boot, after the device list).
function debugcon.probe()
    local s = settings()
    if s.ocelot then
        for address in component.list("ocelot", true) do attachComponent(address, "ocelot") end
    end
    if s.serial then
        for address in component.list("serial", true) do attachComponent(address, "serial") end
    end
    if s.tcp and not tcp then
        local host, port = tcpTarget(s.tcp)
        if host then
            tcp = { host = host, port = port, buffer = "", connected = false, retryAt = 0 }
        else
            printk("debugcon: bad tcp target '" .. s.tcp .. "' (host:port expected)", "warning")
        end
    end
end

-- component_added / component_removed from the kernel loop.
function debugcon.handleEvent(name, address, kind)
    if name == "component_added" and (kind == "ocelot" or kind == "serial") then
        if settings()[kind] then attachComponent(address, kind) end
    elseif name == "component_removed" and consoles[address] then
        consoles[address] = nil
    elseif name == "component_removed" and kind == "internet" and tcp and tcp.socket then
        tcpClose("internet card removed")
    end
end

-- Every kernel loop pass.
function debugcon.tick()
    tcpTick()
end

-- Tries for up to `seconds` to get buffered output out (before a halt).
-- Socket calls take a tick each, so the clock moves while there is a
-- socket; without one nothing would, so give up at once then.
function debugcon.flush(seconds)
    if not tcp then return end
    local deadline = computer.uptime() + (seconds or 1)
    tcp.retryAt = 0
    for _ = 1, 20 * (seconds or 1) + 10 do
        tcpTick()
        if not tcp.socket or (tcp.connected and #tcp.buffer == 0) then return end
        if computer.uptime() >= deadline then return end
    end
end

-- Names of the attached consoles (dmesg-style status for debugging).
function debugcon.list()
    local out = {}
    for key, con in pairs(consoles) do out[#out + 1] = con.kind .. (key ~= con.kind and (" " .. key) or "") end
    table.sort(out)
    return out
end
end
