---@class system
local system = {}

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