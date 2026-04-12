---@class system
system = {}
---@class stdio
system.console = {
    ---@class stdin
    stdin = {
        read = function(_, ...)
            return nil
        end
    },
    ---@class stdout
    stdout = {
        write = function(_, v)
            fbcon.write(v)
        end
    },
    ---@class stderr
    stderr = {
        write = function(_, v)
            fbcon.write(v)
        end
    }
}

kthreads = {}

system.config = config

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