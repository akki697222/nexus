-- kernel entry point
local kargs = { ... }

local function kernelArg(name)
    for _, value in ipairs(kargs) do
        if type(value) == "string" then
            local match = value:match("^" .. name .. "=(.*)")
            if match then return match end
        end
    end
end

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
---@type device
device = device
---@type procfs
procfs = procfs
---@type module
module = module
---@type event
event = event
---@type system
system = system

-- Userland and kernel modules get their environments from env.lua and must
-- never see the raw OC APIs; drop them from the global table the kernel was
-- loaded into (kernel code keeps its own upvalues, see base.lua).
_ENV.component = nil
_ENV.computer = nil

-- resets framebuffer controller
fbcon.reset()
devfs.init()
device.init()

local function main()
    -- Real-time clock: a fresh tmpfs file's modification time is the host's
    -- wall clock. Done first so every vnode gets a real timestamp.
    do
        local ok, timestamp = pcall(function()
            local volume = component.proxy(computer.tmpAddress())
            if not volume then return end
            local path = "/.nexus-boot-clock"
            local handle = volume.open(path, "wb")
            if not handle then return end
            volume.close(handle)
            local modified = volume.lastModified(path)
            volume.remove(path)
            return modified
        end)
        if ok and type(timestamp) == "number" and timestamp > 0 then
            -- epoch seconds at uptime 0; getRealTime() adds uptime
            bootRealTime = math.floor(timestamp / 1000 - computer.uptime())
        end
    end

    -- boot message
    printk("Nexus version " .. _OSVERSIONSTRING)
    local cpu = device.getFromType("processor") --[[@as device_manifest_cpu]]
    if cpu then
        printk(computer.getArchitecture() .. "/CPU: " .. cpu.vendor .. " " .. cpu.product .. " @ " .. cpu.clock)
    end
    local total_kb = math.floor(computer.totalMemory() / 1024)
    local free_kb = math.floor(computer.freeMemory() / 1024)
    local used_kb = total_kb - free_kb
    printk("Memory: " .. free_kb .. "KB/" .. total_kb .. "KB available (" .. used_kb .. "KB reserved)")
    for addr, dev in pairs(device.list()) do
        printk("device [" .. addr .. "] " .. dev.product .. " (" .. dev.desc .. ")")
    end

    -- Mount root
    do
        local boot = computer.getBootAddress()
        if kdebug then kdebug.print("bootaddr: " .. boot) end
        local s, e = vfs.mount(boot, "/")
        if not s then
            printk("mount: " .. e, "err")
            panic("not syncing", "VFS: unable to mount root fs on " .. tostring(boot))
        end
        printk("VFS: Mounted root fs on device " .. tostring(boot) .. ".")
    end
    do
        local s, e = vfs.mount(computer.tmpAddress(), "/tmp")
        if not s then
            printk("VFS: unable to mount tmp fs on " .. computer.tmpAddress(), "err")
        end
    end
    printk("tmpfs: mounted")
    do
        local s, e = vfs.mount(devfs, "/dev")
        if not s then
            printk("mount: " .. e, "err")
            panic("not syncing", "devfs: unable to mount")
        end
        devfs.postmount()
    end
    vfs.chmod("/tmp", 1777)

    -- Installed systems boot from an NXIMG (bootstrap/init.lua passes
    -- image=): /usr is its read-only usr section, with modes and owners from
    -- the image, and /etc is seeded from its etc section on first boot.
    local imagePath = kernelArg("image")
    if imagePath then
        local boot = computer.getBootAddress()
        local usr, e = imgfs.open(boot, imagePath, imgfs.SECTION.usr)
        if not usr then
            panic("not syncing", "imgfs: " .. imagePath .. ": " .. tostring(e))
        end
        local mounted, me = vfs.mount(usr, "/usr")
        if not mounted then
            panic("not syncing", "imgfs: unable to mount /usr: " .. tostring(me))
        end
        printk("imgfs: mounted " .. imagePath .. " on /usr (ro)")
        local seeded, se = imgfs.seedEtc(boot, imagePath)
        if not seeded then
            printk("imgfs: unable to seed /etc: " .. tostring(se), "err")
        end
    end

    vfs.link("/usr/sbin", "/sbin")
    vfs.link("/usr/bin", "/bin")
    vfs.link("/usr/ubin", "/ubin")

    -- Keep sudo as the only set-user-ID entry point. Its policy is immutable
    -- to non-root users and defaults are installed in /etc/sudoers. An image
    -- /usr already carries these modes and cannot be changed.
    if not imagePath then
        for path in vfs.list("/usr/bin") do
            vfs.chmod(vfs.concat("/usr/bin", path), 0755)
        end

        for path in vfs.list("/usr/ubin") do
            vfs.chmod(vfs.concat("/usr/ubin", path), 0755)
        end

        vfs.chown("/usr/bin/sudo.lua", 0, 0)
        vfs.chmod("/usr/bin/sudo.lua", 04755)
    end
    vfs.chown("/etc/sudoers", 0, 0)
    vfs.chmod("/etc/sudoers", 0440)

    system.createKernelThread(function()
        local SAVE_INTERVAL = 1
        local last_save = computer.uptime()
        local last_sync_error
        while true do
            if vfs._dirty and computer.uptime() - last_save >= SAVE_INTERVAL then
                local ok, err = system._syncMetadata(function()
                    return vfs.saveMetadata(coroutine.yield)
                end)
                if not ok and err ~= "Metadata sync is stopping" then
                    -- a failure repeats every interval; show it once
                    local msg = "vfs: metadata sync failed: " .. tostring(err)
                    printk(msg, msg == last_sync_error and "debug" or "err")
                    last_sync_error = msg
                elseif ok then
                    last_sync_error = nil
                end
                last_save = computer.uptime()
            end
            coroutine.yield()
        end
    end, "vfs_sync", {})

    do
        local s, e = vfs.mount(procfs, "/proc")
        if not s then
            printk("procfs: mount failed: " .. e, "err")
        end
    end

    device.register()

    -- initialize tty
    if not config.console_force_framebuffer then
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
                    return tty.read(...)
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
        local buf = ""
        for _, value in ipairs(fbcon.buffer) do
            buf = buf .. value .. "\n"
        end
        tty.write(buf)
        fbcon.buffer = nil
    end

    user.init()
    group.init()

    -- bind drivers to the devices present at boot; modules from
    -- /etc/modules.lua are loaded by now, groups are known for /dev nodes
    devmgr.init()
    devmgr.coldplug()

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
    -- from here on the console belongs to userland; see console_loglevel
    fbcon.booted = true
    local pid, e = process.exec(init_path, { _OSVERSION }, 0, util.createEnv(), 1)
    if pid == -1 then
        panic("not syncing", "Failed to start init process: " .. e)
    end

    runProcessQueue = function(event)
        local run_queue = process.getRunQueue()
        local premoves = {}
        local snapshot = {}
        for _, proc in ipairs(run_queue) do
            -- Threads share their owning process PID, so keep that owner
            -- alongside each queued thread entry when checking PID reuse.
            table.insert(snapshot, { entry = proc, owner = process.get(proc.pid) })
        end

        for _, item in ipairs(snapshot) do
            local proc = item.entry
            if item.owner and item.owner.instance == proc.instance
                and process.get(proc.pid) == item.owner then
                local dead = process.resume(proc, event)
                if dead then
                    table.insert(premoves, item)
                end
            end
        end

        for _, item in ipairs(premoves) do
            local proc = item.entry
            if item.owner and item.owner.instance == proc.instance
                and process.get(proc.pid) == item.owner then
                process.kill(proc.pid)
            end
        end
        -- back in kernel context: no process is current
        process.current = -1
    end

    resumeKernelThreads = function()
        local tremoves = {}
        for i, thr in ipairs(kthreads) do
            if coroutine.status(thr.co) ~= "dead" then
                local s, e = coroutine.resume(thr.co, table.unpack(thr.args))
                if not s then
                    printk("kthread: " .. thr.name .. ": " .. e, "err")
                end
            else
                table.insert(tremoves, i)
            end
        end
        for _, i in ipairs(tremoves) do
            table.remove(kthreads, i)
        end
    end

    -- loop statistics (kdebug.lua, development builds with config.loop_stats)
    local stats = kdebug and kdebug.loopStats()

    -- kernel main event loop
    while true do
        -- Block for the next signal only when no process is ready to run;
        -- otherwise a process that yields would wait a whole tick each time.
        local ev = table.pack(computer.pullSignal(#process.getRunQueue() > 0 and 0 or 0.05))
        if ev.n > 0 then
            device.handleEvent(ev[1], ev[2])
            devmgr.handleEvent(ev[1], ev[2], ev[3])
            event.dispatch(ev)
        end

        if stats then stats.pass(ev) end

        process.dispatchWaiting(ev)

        runProcessQueue(ev)

        if stats then stats.processesDone() end

        -- Kernel threads (the vt repaint among them) run after the
        -- processes, so what a process wrote for this key press reaches the
        -- screen in the same pass instead of one tick later.
        resumeKernelThreads()

        if stats then stats.threadsDone() end

        if not process.get(1) then
            panic("not syncing", "Attempted to kill init!")
        end
    end
end

local s, e = xpcall(main, debug.traceback)
if not s then
    -- the error and where it came from, not just that something failed
    local message = tostring(e)
    for line in message:gmatch("[^\r\n]+") do
        printk(line, "emerg")
    end
    panic("not syncing", "Uncaught Error Occurred: " .. (message:match("^[^\r\n]*") or "?"))
end
