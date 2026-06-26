---@class event
event = {}

---@class event_handler
---@field pid integer
---@field key string
---@field callback function
---@field interval number
---@field times number
---@field timeout number
---@field background boolean

---@type event_handler[]
local handlers = {}
event.handlers = handlers

local queues = {}
local foreground_pid = -1

------------------------------------------------------------
-- local event queue
------------------------------------------------------------

local function get_queue()
    local proc = process.getCurrent()
    if not proc then return nil end
    local pid = proc.pid
    local q = queues[pid]
    if not q then
        q = {}
        queues[pid] = q
    end
    return q
end

local function push_local(...)
    local q = get_queue()
    if not q then return end
    q[#q + 1] = table.pack(...)
end

local function pop_local()
    local q = get_queue()
    if not q or #q == 0 then return nil end
    local ev = q[1]
    table.remove(q, 1)
    return ev
end

------------------------------------------------------------
-- public push
------------------------------------------------------------

function event.push(...)
    push_local(...)
end

function event.clear()
    local proc = process.getCurrent()
    if proc then
        queues[proc.pid] = {}
    end
end

function event.listenBackground(on)

end

------------------------------------------------------------
-- register / listen / cancel
------------------------------------------------------------

function event.setForeground(pid)
    foreground_pid = pid
end

function event.getForeground()
    return foreground_pid
end

function event.register(key, callback, interval, times, opt_handlers)
    ---@type event_handler
    local handler = {
        pid = process.current,
        key = key,
        callback = callback,
        interval = interval or math.huge,
        times = times or 1,
        background = false,
        timeout = computer.uptime() + interval or math.huge
    }

    opt_handlers = opt_handlers or handlers

    local id = 0
    repeat
        id = id + 1
    until not opt_handlers[id]

    opt_handlers[id] = handler
    return id
end

---@param name string
---@param callback function
function event.listen(name, callback)
    for _, h in pairs(handlers) do
        if h.key == name and h.callback == callback then
            return false
        end
    end

    return event.register(name, callback, math.huge, math.huge)
end

---@param callback function
function event.listenAny(callback)
    for _, h in pairs(handlers) do
        if h.key == nil and h.callback == callback then
            return false
        end
    end
    return event.register(nil, callback, math.huge, math.huge)
end

function event.cancel(id)
    handlers[id] = nil
end

------------------------------------------------------------
-- filtering
------------------------------------------------------------

local function createPlainFilter(name, ...)
    local filter = table.pack(...)
    if name == nil and filter.n == 0 then
        return nil
    end

    return function(...)
        local signal = table.pack(...)
        if name and not (type(signal[1]) == "string" and signal[1]:match(name)) then
            return false
        end
        for i = 1, filter.n do
            if filter[i] ~= nil and filter[i] ~= signal[i + 1] then
                return false
            end
        end
        return true
    end
end

------------------------------------------------------------
-- handler dispatch
------------------------------------------------------------

local function dispatch_handlers(ev)
    local sig = ev[1]
    local now = computer.uptime()

    ---@type event_handler[]
    local copy = {}
    for id, h in pairs(handlers) do
        copy[id] = h
    end

    for id, h in pairs(copy) do
        if (h.key == nil or h.key == sig) or now >= h.timeout then
            h.times = h.times - 1
            h.timeout = h.timeout + h.interval

            if h.times <= 0 and handlers[id] == h then
                handlers[id] = nil
            end

            if h.pid == process.current or h.background then
                local ok, err = pcall(h.callback, table.unpack(ev, 1, ev.n))
                if not ok and event.onError then
                    pcall(event.onError, err)
                end
            end
        end
    end
end

------------------------------------------------------------
-- core wait primitive
------------------------------------------------------------

local function wait_event()
    local ev = pop_local()
    if ev then return ev end
    return table.pack(coroutine.yield("__event_wait__"))
end

------------------------------------------------------------
-- pull APIs
------------------------------------------------------------

function event.pullFiltered(...)
    local args = table.pack(...)
    local seconds, filter = math.huge, nil

    if type(args[1]) == "function" then
        filter = args[1]
    else
        seconds = args[1]
        filter = args[2]
    end

    local deadline = computer.uptime() + (seconds or math.huge)

    repeat
        local ev = wait_event()
        if ev and ev.n > 0 then
            dispatch_handlers(ev)
            if not filter or filter(table.unpack(ev, 1, ev.n)) then
                return table.unpack(ev, 1, ev.n)
            end
        end
    until computer.uptime() >= deadline
end

function event.pull(...)
    local args = table.pack(...)
    if type(args[1]) == "string" then
        return event.pullFiltered(createPlainFilter(...))
    else
        return event.pullFiltered(args[1], createPlainFilter(select(2, ...)))
    end
end

------------------------------------------------------------
-- timer
------------------------------------------------------------

function event.timer(interval, callback, times)
    return event.register(false, callback, interval, times)
end

function event.dispatch(ev)
    if not ev or ev.n == 0 then return end

    local interactive_events = {
        key_down = true,
        key_up = true,
        touch = true,
        drag = true,
        drop = true,
        scroll = true,
        clipboard = true
    }
    local is_interactive = interactive_events[ev[1]]

    for pid, q in pairs(queues) do
        if not is_interactive or pid == foreground_pid then
            q[#q + 1] = ev
        end
    end
    dispatch_handlers(ev)
end

function event.removeQueue(pid)
    queues[pid] = nil
end

event.handlers = handlers
