-- kernel entry point
local kargs = { ... }

-- reassigns global (for luals autocompletion)
---@type vfs
vfs = vfs
---@type fbcon
fbcon = fbcon
---@type process
process = process
---@type packagelib
package = package
---@type devfs
devfs = devfs
---@type procfs
procfs = procfs
---@type module
module = module
---@type event
event = event
---@type system
system = system

-- setting up package.preload
package.preload.filesystem = setmetatable({}, { __index = vfs })
package.preload.computer = setmetatable({}, { __index = computer })
package.preload.component = setmetatable({}, { __index = component })
package.preload.event = setmetatable({}, { __index = event })
package.preload.unicode = setmetatable({}, { __index = unicode })
-- nexus apis
package.preload.permission = setmetatable({}, { __index = permission })
package.preload.module = setmetatable({}, { __index = module })
package.preload.process = setmetatable({}, { __index = process })
package.preload.devfs = setmetatable({}, { __index = devfs })
package.preload.sha2 = setmetatable({}, { __index = sha2 })
package.preload.system = setmetatable({}, { __index = system })
package.preload.user = setmetatable({}, { __index = user })
package.preload.group = setmetatable({}, { __index = group })

-- default lua environment for openos compability
local env = {
    coroutine = coroutine,
    debug = debug,
    io = io,
    math = math,
    os = os,
    shell = shell,
    package = package,
    table = table,
    string = string,
    utf8 = utf8,
    assert = assert,
    collectgarbage = function()
        -- do nothing
    end,
    getmetatable = getmetatable,
    setmetatable = setmetatable,
    ipairs = ipairs,
    pairs = pairs,
    load = load,
    loadfile = loadfile,
    dofile = function(filename)
        local chunk, err = loadfile(filename)
        if not chunk then
            error(err or "failed to load file", 2)
        end
        return chunk()
    end,
    print = print,
    next = next,
    pcall = pcall,
    xpcall = xpcall,
    rawequal = rawequal,
    rawget = rawget,
    rawlen = rawlen,
    rawset = rawset,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    error = error,
    type = type,
    require = require,
    checkArg = checkArg,
    _VERSION = _VERSION,
    _OSVERSION = _OSVERSION,
    _OSVERSIONNUMBER = _OSVERSIONNUMBER,
    _OSDIST = _OSDIST,
    _NEXUS = true,
}

util.createEnv = function()
    return setmetatable({}, { __index = env })
end

-- resets framebuffer controller
fbcon.reset()

-- Mount root
do
    local s, e = vfs.mount(computer.getBootAddress(), "/")
    if not s then
        printk("mount: " .. e)
        panic("not syncing", "VFS: unable to mount root fs on " .. computer.getBootAddress())
    end
end
do
    local s, e = vfs.mount(computer.tmpAddress(), "/tmp")
    if not s then
        printk("VFS: unable to mount tmp fs on " .. computer.tmpAddress())
    end
end
vfs.chmod("/tmp", 1777)

vfs.link("/usr/sbin", "/sbin")
vfs.link("/usr/bin", "/bin")

for path in vfs.list("/usr/bin") do
    vfs.chmod(vfs.concat("/usr/bin", path), 0755)
end

system.createKernelThread(function()
    local SAVE_INTERVAL = 1
    local last_save = computer.uptime()
    while true do
        if vfs._dirty and computer.uptime() - last_save >= SAVE_INTERVAL then
            vfs.saveMetadata()
            vfs._dirty = false
            last_save = computer.uptime()
        end
        coroutine.yield()
    end
end, "vfs_sync", {})

do
    local s, e = vfs.mount(procfs, "/proc")
    if not s then
        printk("procfs: mount failed: " .. e)
    end
end

devfs.init()
user.init()
group.init()

-- set boot time
do
    local proxy, path = component.proxy(computer.tmpAddress()), "timestamp"
    if proxy then
        proxy.close(proxy.open(path, "wb"))
        bootRealTime = math.floor(proxy.lastModified(path) / 1000)
        proxy.remove(path)
    end
end

-- initialize tty
do
    local tty
    local s, e = xpcall(function()
        module.autoload()
        if module.exists("tty") then
            tty = module.require("tty") --[[@as module_tty]]
            tty.new(0)
        end
    end, debug.traceback)
    if not s then
        panic("not syncing", "failed to initialize console: " .. e)
    end
    system.setConsole({
        stdin = {
            read = function(_, ...)
                return tty.read()
            end
        },
        stdout = {
            write = function(_, v)
                tty.write(v)
            end
        },
        stderr = {
            write = function(_, v)
                tty.write("\27[31m" .. v .. "\27[0m")
            end
        }
    })
    for _, value in ipairs(fbcon.buffer) do
        printk(value)
    end
    fbcon.buffer = nil
end

-- boot message
printk("Booting " .. _OSVERSION)
printk("Nexus version " .. _OSVERSIONSTRING .. " (" .. computer.getArchitecture() .. ")")
printk("machine: " .. _MACHINE)
local total_kb = math.floor(computer.totalMemory() / 1024)
local free_kb = math.floor(computer.freeMemory() / 1024)
local used_kb = total_kb - free_kb
printk("Memory: " .. free_kb .. "KB/" .. total_kb .. "KB available (" .. used_kb .. "KB reserved)")

local init_path = nil
if #kargs ~= 0 then
    for _, value in ipairs(kargs) do
        if type(value) == "string" then
            local match = string.match(value, "^init=(.*)")
            if match then
                init_path = match
            end
        end
    end
end

-- trying to start init
if not init_path or (init_path and not vfs.exists(init_path)) then
    panic("not syncing", "No init found. Try passing init= option to kernel.")
end
printk("init: starting " .. init_path .. " (PID 1)")
local pid, e = process.exec(init_path, { _OSVERSION }, 0, util.createEnv(), 1)
if pid == -1 then
    panic("not syncing", "Failed to start init process: " .. e)
end

runProcessQueue = function(event)
    local run_queue = process.getRunQueue()
    local premoves = {}
    local snapshot = {}
    for _, proc in ipairs(run_queue) do
        table.insert(snapshot, proc)
    end

    for _, proc in ipairs(snapshot) do
        if process.get(proc.pid) then
            local dead = process.resume(proc, event)
            if dead then
                table.insert(premoves, proc.pid)
            end
        end
    end

    for _, pid in ipairs(premoves) do
        local proc = process.get(pid)
        if proc then
            process.kill(pid)
        end
    end
end

resumeKernelThreads = function()
    local tremoves = {}
    for i, thr in ipairs(kthreads) do
        if coroutine.status(thr.co) ~= "dead" then
            local s, e = coroutine.resume(thr.co, table.unpack(thr.args))
            if not s then
                printk("kthread: " .. thr.name .. ": " .. e)
            end
        else
            table.insert(tremoves, i)
        end
    end
    for _, i in ipairs(tremoves) do
        table.remove(kthreads, i)
    end
end

-- kernel main event loop
while true do
    local ev = table.pack(computer.pullSignal(0.05))
    if ev.n > 0 then
        event.dispatch(ev)
    end

    resumeKernelThreads()

    if ev.n > 0 then
        process.dispatchWaiting(ev)
    end

    runProcessQueue(ev)

    if not process.get(1) then
        panic("not syncing", "Attempted to kill init!")
    end
end
