-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

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
    end
end

local function wait_for_deps(def)
    if not def.deps then return end
    for _, dep_id in ipairs(def.deps) do
        local entry = services[dep_id]
        if not entry then
            error("service '" .. def.id .. "' depends on unknown service '" .. dep_id .. "'")
        end
        -- block until dep transitions to "running"
        while entry.state ~= "running" do
            if entry.state == "stopped" then
                error("dependency '" .. dep_id .. "' is stopped, cannot start '" .. def.id .. "'")
            end
            scheduler.sleep(0.05)
        end
    end
end

local function spawn_service(entry)
    local pid = process_manager.spawn({
        path     = entry.def.path,
        detached = true,
    })
    entry.pid   = pid
    entry.state = "starting"
    pid_map[pid] = entry.def.id
    log.info("Service '%s' starting (pid=%d)", entry.def.id, pid)
end

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
    wait_for_deps(entry.def)
    spawn_service(entry)
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
    process_manager.kill(entry.pid, "stopped")
    pid_map[entry.pid] = nil
    entry.pid   = nil
    entry.state = "stopped"
    log.info("Service '%s' stopped", id)
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

    log.warn("Service '%s' crashed, restarting...", id)
    timer.after(1.0, function()
        local ok, err = pcall(service_manager.start, id)
        if not ok then
            log.error("Failed to restart service '%s': %s", id, tostring(err))
        end
    end)
end