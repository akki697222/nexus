_ARCH    = _VERSION
_DISTRO  = "Nexus"
_VERSION = "0.1.0-dev_oc"

---@output init.lua
---@bundle util/argument.lua
---@bundle util/panic.lua
---@bundle sys/log.lua
---@bundle cap/capability.lua
---@bundle sys/proc/timer.lua
---@bundle sys/proc/sched.lua
---@bundle sys/proc/mgr.lua
---@bundle sys/event/router.lua
---@bundle sys/event/event.lua
---@bundle sys/srv/mgr.lua

local function main()
    -- init log
    local gpu    = component.proxy(component.list("gpu")())
    local screen = component.list("screen")()
    log.init(gpu, screen)
    log.info("%s %s (%s)", _DISTRO, _VERSION, _ARCH)

    -- register core services
    service_manager.register({
        id   = "storage",
        path = "/Services/storage.lua",
        kind = "core",
        deps = {},
    })
    service_manager.register({
        id   = "filesystem",
        path = "/Services/filesystem.lua",
        kind = "core",
        deps = { "storage" },
    })
    service_manager.register({
        id   = "module",
        path = "/Services/module.lua",
        kind = "core",
        deps = { "filesystem" },
    })

    -- hook process_died for service restart / panic
    event.on("process_died", function(ev)
        service_manager.on_process_died(ev.pid)
    end)

    -- start all registered services in dependency order
    service_manager.start_all()

    log.info("All services started, entering scheduler loop")

    -- hand off to scheduler
    scheduler.run()
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    panic(err)
else
    computer.shutdown()
end