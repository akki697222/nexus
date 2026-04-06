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
local s, e = vfs.mount(computer.getBootAddress(), "/")
if not s then
    printk("mount: " .. e)
    panic("not syncing", "VFS: Unable to mount root fs on " .. computer.getBootAddress())
end
vfs.mount(computer.tmpAddress(), "/tmp")
vfs.chmod("/tmp", 1777)

vfs.link("/usr/sbin", "/sbin")
vfs.link("/usr/bin", "/bin")

for path in vfs.list("/usr/bin") do
    vfs.chmod(vfs.concat("/usr/bin", path), 0755)
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

module.autoload()
if module.exists("tty") then
    local tty = module.require("tty") --[[@as module_tty]]
    tty.new(0)
end

-- boot message
printk("Booting " .. _OSVERSION)

local init_path = nil
if #kargs ~= 0 then
    for index, value in ipairs(kargs) do
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
local pid, e = process.exec(init_path, { _OSVERSION }, 0, util.createEnv(), 1)
if pid == -1 then
    panic("not syncing", "Failed to start init process: " .. e)
end
---@param proc process_entry
-- kernel main event loop
while true do
    local ev = table.pack(computer.pullSignal(0.05))
    if ev.n > 0 then
        event.dispatch(ev)
    end

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

    -- Resume all processes and collect indices of dead processes
    local premoves = {}
    for i, proc in ipairs(processes) do
        local rm = process.resume(proc, ev)
        if rm then
            table.insert(premoves, i)
        end
    end

    -- Remove dead processes in reverse order to avoid index shifting issues
    table.sort(premoves, function(a, b) return a > b end)
    for _, i in ipairs(premoves) do
        local p = processes[i]
        table.remove(processes, i)
        event.removeQueue(p.pid)
        used_pids[p.pid] = nil
    end
    if not process.get(1) then
        panic("not syncing", "Attempted to kill init!")
    end
    fbcon.update()
end
