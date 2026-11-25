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

-- Uptime of the last kernel loop pass that found no signal waiting. Input
-- that is due later (a key repeat) can only be trusted once a pass after
-- that time has drained the queue: a key_up may still be waiting in it.
local idleAt = nil

function event.markIdle(now)
    idleAt = now
end

---@return number|nil
function event.idleAt()
    return idleAt
end

-- Events a process never pulls must not pile up forever.
local MAX_QUEUE = 256

-- Input events go to the foreground process only.
local interactive_events = {
    key_down = true,
    key_up = true,
    touch = true,
    drag = true,
    drop = true,
    scroll = true,
    clipboard = true,
    text_input = true
}

-- Deadline of each coroutine blocked in an event wait (weak keys).
local wait_deadlines = setmetatable({}, { __mode = "k" })

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

-- Runs the handlers of the current context (its own and background ones)
-- that are due for `ev`. Handlers of other processes are left untouched, so
-- their timers and remaining counts are not consumed without running.
local function dispatch_handlers(ev)
    if next(handlers) == nil then return end
    local sig = ev[1]
    local now = computer.uptime()
    local current = process.current

    local due
    for id, h in pairs(handlers) do
        if (h.pid == current or h.background)
            and ((h.key == nil or h.key == sig) or now >= h.timeout) then
            due = due or {}
            due[#due + 1] = id
        end
    end
    if not due then return end

    for _, id in ipairs(due) do
        local h = handlers[id]
        -- an earlier callback may have cancelled it
        if h then
            h.times = h.times - 1
            h.timeout = h.timeout + h.interval
            if h.times <= 0 then
                handlers[id] = nil
            end
            local ok, err = pcall(h.callback, table.unpack(ev, 1, ev.n))
            if not ok and event.onError then
                pcall(event.onError, err)
            end
        end
    end
end

------------------------------------------------------------
-- core wait primitive
------------------------------------------------------------

-- Next queued event, blocking until one arrives or `deadline` passes. The
-- scheduler resumes the waiter with its start arguments, which are not an
-- event: the event itself is always taken from the queue.
local function wait_event(deadline)
    local ev = pop_local()
    if ev then return ev end
    local co = coroutine.running()
    wait_deadlines[co] = deadline
    coroutine.yield("__event_wait__")
    wait_deadlines[co] = nil
    return pop_local()
end

-- Whether the scheduler should wake `entry` (a process or thread blocked in
-- an event wait): it has queued events, its deadline passed, or one of its
-- handlers is due for `ev` (nil or empty when no signal arrived).
function event.wants(entry, now, ev)
    local q = queues[entry.pid]
    if q and q[1] then return true end
    local deadline = entry.thread and wait_deadlines[entry.thread]
    -- uptime moves in 0.05 s ticks that do not add up exactly
    if deadline and now + 1e-6 >= deadline then return true end
    local sig = ev and ev.n > 0 and ev[1] or nil
    for _, h in pairs(handlers) do
        if h.pid == entry.pid and (now >= h.timeout or (sig and (h.key == nil or h.key == sig))) then
            return true
        end
    end
    return false
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
        local ev = wait_event(deadline)
        if ev and ev.n > 0 then
            dispatch_handlers(ev)
            if not filter or filter(table.unpack(ev, 1, ev.n)) then
                return table.unpack(ev, 1, ev.n)
            end
        end
    until computer.uptime() + 1e-6 >= deadline
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

-- Kernel hooks: called with every signal before it is queued for
-- processes (the tty input layer uses this). Module tier only.
local hooks, nextHook = {}, 1

---@param fn fun(ev: table)
---@return integer
function event.addHook(fn)
    checkArg(1, fn, "function")
    local id = nextHook
    nextHook = nextHook + 1
    hooks[id] = fn
    return id
end

function event.removeHook(id)
    hooks[id] = nil
end

function event.dispatch(ev)
    if not ev or ev.n == 0 then return end

    for _, hook in pairs(hooks) do
        local ok, err = pcall(hook, ev)
        if not ok then printk("event: hook failed: " .. tostring(err), "err") end
    end

    local is_interactive = interactive_events[ev[1]]

    for pid, q in pairs(queues) do
        if not is_interactive or pid == foreground_pid then
            if #q >= MAX_QUEUE then table.remove(q, 1) end
            q[#q + 1] = ev
        end
    end
    dispatch_handlers(ev)
end

function event.removeQueue(pid)
    queues[pid] = nil
end

event.handlers = handlers
