---@class system
system = {}
---@class stdio
system.console = {
    ---@class stdin
    stdin = {
        read = function(_, ...)
            return nil
        end,
        write = function(_, ...)
            return nil, "Read-only file system"
        end,
        close = function(_) end,
        seek  = function(_, ...) return nil, "stdin is not seekable" end,
    },
    ---@class stdout
    stdout = {
        read = function(_, ...)
            return nil, "stdout is not readable"
        end,
        write = function(_, v)
            fbcon.write(v)
        end,
        close = function(_) end,
        seek  = function(_, ...) return nil, "stdout is not seekable" end,
    },
    ---@class stderr
    stderr = {
        read = function(_, ...)
            return nil, "stderr is not readable"
        end,
        write = function(_, v)
            fbcon.write(v)
        end,
        close = function(_) end,
        seek  = function(_, ...) return nil, "stderr is not seekable" end,
    }
}

kthreads = {}

system.config = config

-- Shutdown state is kernel private. The request is deliberately a single
-- slot: once accepted, later requests cannot change poweroff into reboot (or
-- vice versa).
local shutdown_request
local metadata_sync_active = false
local metadata_sync_stopping = false

---@param flush fun()
---@return boolean|nil
---@return string|nil
function system._syncMetadata(flush, final)
    if metadata_sync_stopping and not final then
        return nil, "Metadata sync is stopping"
    end
    if metadata_sync_active then
        return nil, "Metadata sync is already active"
    end
    metadata_sync_active = true
    local ok, result, reason = pcall(flush)
    metadata_sync_active = false
    if not ok then return nil, result end
    if result == nil and reason ~= nil then return nil, reason end
    return result == nil and true or result
end

---@param reboot boolean
---@return boolean|nil
---@return string|nil
function system.requestShutdown(reboot)
    if type(reboot) ~= "boolean" then return nil, "Invalid argument" end
    local proc = process.getCurrent()
    if not proc or proc.euid ~= 0 then return nil, "Permission denied" end
    if shutdown_request == nil then shutdown_request = reboot end
    return true
end

---@return boolean|nil reboot requested; nil means no request
---@return string|nil
function system.shutdownRequested()
    if process.getCurrentPID() ~= 1 then return nil, "Permission denied" end
    return shutdown_request
end

---@return boolean|nil
---@return string|nil
function system.finishShutdown()
    if process.getCurrentPID() ~= 1 then return nil, "Permission denied" end
    if shutdown_request == nil then return nil, "No shutdown requested" end

    local reboot = shutdown_request
    metadata_sync_stopping = true
    while metadata_sync_active do coroutine.yield() end

    local ok, err = system._syncMetadata(function()
        repeat
            local flushed, flush_err = vfs.saveMetadata(coroutine.yield)
            if not flushed then return nil, flush_err end
        until not vfs._dirty
        return true
    end, true)
    if not ok then
        metadata_sync_stopping = false
        shutdown_request = nil
        return nil, err
    end

    local called, result, reason = pcall(computer.shutdown, reboot)
    if not called or result == false or (result == nil and reason ~= nil) then
        metadata_sync_stopping = false
        shutdown_request = nil
        return nil, called and reason or result
    end
    shutdown_request = nil
    metadata_sync_stopping = false
    return true
end

function system.printk(...)
    printk(...)
end

function system.panic(err, reason)
    local proc = process.getCurrent()
    if proc and proc.euid == 0 then
        panic(err, reason)
    else
        return "Permission Denied"
    end
end

function system.createKernelThread(func, name, args)
    if process.current > 0 then
        return "Permission Denied"
    end
    table.insert(kthreads, { co = wrap_with_traceback(func), args = args, name = name })
end

---@param stdio stdio
---@return boolean
---@return string|nil # error
function system.setConsole(stdio)
    if process.current > 0 then
        return false, "Permission Denied"
    end
    local valid = type(stdio) == "table"
        and type(stdio.stdin) == "table"
        and type(stdio.stdin.read) == "function"
        and type(stdio.stdout) == "table"
        and type(stdio.stdout.write) == "function"
        and type(stdio.stderr) == "table"
        and type(stdio.stderr.write) == "function"
    if not valid then
        return false, "Invalid device"
    end
    system.console.stdin.read = stdio.stdin.read
    system.console.stdout.write = stdio.stdout.write
    system.console.stderr.write = stdio.stderr.write
    return true
end
