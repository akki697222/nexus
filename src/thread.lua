---@class thread_lib
local thread = {}

local handle_map = {}
local pid_map = {}

---@class thread_handle
local thread_handle = {}
thread_handle.__index = thread_handle

local function create_handle(pid)
    local t = setmetatable({}, thread_handle)
    handle_map[t] = pid
    pid_map[pid] = t
    return t
end

function thread.create(thread_proc, ...)
    local args = { ... }
    local pid = process.createThread(function(...)
        local result = { thread_proc(...) }
    end, args, "thread")

    return create_handle(pid)
end

function thread.waitForAll(threads, timeout)
    local deadline = timeout and (computer.uptime() + timeout) or math.huge
    while true do
        local all_dead = true
        for _, t in ipairs(threads) do
            if t:status() ~= "dead" then
                all_dead = false
                break
            end
        end
        if all_dead then return true end

        if computer.uptime() > deadline then
            return false, "timeout"
        end

        coroutine.yield()
    end
end

function thread.waitForAny(threads, timeout)
    local deadline = timeout and (computer.uptime() + timeout) or math.huge
    while true do
        for _, t in ipairs(threads) do
            if t:status() == "dead" then
                return true
            end
        end

        if computer.uptime() > deadline then
            return false, "timeout"
        end

        coroutine.yield()
    end
end

function thread.current()
    local proc = process.getCurrent()
    if not proc then return nil end
    local pid = proc.pid
    if not pid_map[pid] then
        return nil
    end
    return pid_map[pid]
end

local function get_proc(self)
    local pid = handle_map[self]
    if not pid then return nil, "invalid thread handle" end
    local proc = process.get(pid)
    if not proc then return nil, "dead" end
    return proc, pid
end

function thread_handle:resume()
    local proc, pid = get_proc(self)
    if not proc then return false, "dead" end
    local ok, err = process.resume_handle(pid)
    if not ok then return nil, err end
    return true
end

function thread_handle:suspend()
    local proc, pid = get_proc(self)
    if not proc then return false, "dead" end
    if pid == process.getCurrent().pid then
        -- special case for self-suspend needed?
        -- the process.suspend sets status, but we must yield to stop running immediately
        process.suspend(pid)
        coroutine.yield()
        return true
    end
    local ok, err = process.suspend(pid)
    if not ok then return nil, err end
    return true
end

function thread_handle:kill()
    local pid = handle_map[self]
    if not pid then return false, "invalid handle" end
    return process.kill(pid)
end

function thread_handle:status()
    local pid = handle_map[self]
    if not pid then return "dead" end
    local proc = process.get(pid)
    if not proc then return "dead" end
    if proc.status == "suspended" then return "suspended" end
    return "running"
end

function thread_handle:attach(level)
    local proc, pid = get_proc(self)
    if not proc then return nil, "dead" end

    local parent_proc = process.getCurrent()
    if level and level > 0 then
        for i = 1, level do
            if parent_proc.parent then
                parent_proc = process.get(parent_proc.parent)
                if not parent_proc then break end
            else
                break
            end
        end
    end

    if parent_proc then
        proc.parent = parent_proc.pid
        return true
    end
    return nil, "parent not found"
end

function thread_handle:detach()
    local proc, pid = get_proc(self)
    if proc then
        proc.parent = 0
    end
    return self
end

function thread_handle:join(timeout)
    return thread.waitForAll({ self }, timeout)
end
