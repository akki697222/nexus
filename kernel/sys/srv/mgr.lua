-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type service_manager
service_manager = {}

---@type table<string, service_entry>
local services = {}

---@type table<integer, string>  pid -> service id
local pid_map = {}

function service_manager.register(def)
    arg(1, def, "table")
    if services[def.id] then
        log.warn("Duplicated service registration '%s'", def.id)
    end
    services[def.id] = {
        def   = def,
        pid   = nil,
        state = "stopped",
    }
    log.info("Service '%s' registered", def.id)
end

function service_manager.get(id)
    arg(1, id, "string")
    return services[id]
end

function service_manager.all_running()
    for _, entry in pairs(services) do
        if entry.state ~= "running" then return false end
    end
    return true
end

function service_manager.is_running(id)
    arg(1, id, "string")
    local entry = services[id]
    return entry ~= nil and entry.state == "running"
end

function service_manager.ready(id)
    arg(1, id, "string")
    local entry = services[id]
    if not entry then
        log.warn("service_manager.ready: unknown service '%s'", id)
        return
    end
    if entry.state == "starting" then
        entry.state = "running"
        log.info("Service '%s' is ready", id)
        router.broadcast({ type = "service_ready", id = id })
        if service_manager.all_running() then
            router.broadcast({ type = "all_services_ready" })
        end
        service_manager._start_pending()
    end
end

local function deps_running(def)
    for _, dep_id in ipairs(def.deps or {}) do
        local dep = services[dep_id]
        if not dep then
            error("service '" .. def.id .. "' depends on unknown service '" .. dep_id .. "'")
        end
        if dep.state ~= "running" then return false end
    end
    return true
end

local function spawn_service(entry)
    local pid = process_manager.spawn({
        path     = entry.def.path,
        detached = true,
    })
    entry.pid   = pid
    entry.state = "starting"
    pid_map[pid] = entry.def.id
    log.info("Service '%s' spawned (pid=%d)", entry.def.id, pid)
end

-- Never blocks: a service whose dependencies are not running yet is marked
-- "pending" and spawned from ready() once they are.
function service_manager.start(id)
    arg(1, id, "string")
    local entry = services[id]
    if not entry then
        error("unknown service '" .. id .. "'")
    end
    if entry.state == "running" or entry.state == "starting" then
        log.warn("Service '%s' is already running", id)
        return
    end
    if deps_running(entry.def) then
        spawn_service(entry)
    else
        entry.state = "pending"
        log.info("Service '%s' waiting for dependencies", id)
    end
end

function service_manager._start_pending()
    for _, entry in pairs(services) do
        if entry.state == "pending" and deps_running(entry.def) then
            spawn_service(entry)
        end
    end
end

local function resolve_order()
    -- topological sort of registered services by deps
    local order   = {}
    local visited = {}

    local function visit(id)
        if visited[id] then return end
        visited[id] = true
        local entry = services[id]
        if not entry then
            error("unknown service '" .. id .. "' in dependency graph")
        end
        for _, dep_id in ipairs(entry.def.deps or {}) do
            visit(dep_id)
        end
        order[#order + 1] = id
    end

    for id in pairs(services) do
        visit(id)
    end
    return order
end

function service_manager.start_all()
    local order = resolve_order()
    for _, id in ipairs(order) do
        service_manager.start(id)
    end
end

function service_manager.stop(id)
    arg(1, id, "string")
    local entry = services[id]
    if not entry or not entry.pid then return end
    local pid = entry.pid
    pid_map[pid] = nil
    process_manager.kill(pid, "stopped")
    entry.pid   = nil
    entry.state = "stopped"
    log.info("Service '%s' stopped", id)
end

---Stop and forget a service (used for runtime-registered services).
function service_manager.unregister(id)
    arg(1, id, "string")
    if not services[id] then return end
    service_manager.stop(id)
    services[id] = nil
end

function service_manager.on_process_died(pid)
    arg(1, pid, "number")
    local id = pid_map[pid]
    if not id then return end

    local entry = services[id]
    pid_map[pid] = nil
    entry.pid    = nil
    entry.state  = "crashed"

    if entry.def.kind == "core" then
        panic("Core service '" .. id .. "' crashed")
    end

    -- give up after 5 crashes within 30s (crash loop)
    local now = computer.uptime()
    local recent = {}
    for _, t in ipairs(entry.crashes or {}) do
        if now - t < 30 then recent[#recent + 1] = t end
    end
    recent[#recent + 1] = now
    entry.crashes = recent
    if #recent > 5 then
        entry.state = "failed"
        log.error("Service '%s' is crash-looping, giving up", id)
        return
    end

    log.warn("Service '%s' crashed (pid=%d), restarting...", id, pid)
    timer.after(1.0, function()
        local ok, err = pcall(service_manager.start, id)
        if not ok then
            log.error("Failed to restart service '%s': %s", id, tostring(err))
        end
    end)
end