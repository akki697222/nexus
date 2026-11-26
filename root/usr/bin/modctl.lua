-- modctl.lua - list, inspect, load, unload and index kernel modules
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   modctl [list] [--drivers|--modules] [--raw|--lsmod]   modules and drivers
--   modctl info <name>                                    manifest, path, state, users
--   modctl load [--no-deps] [--dry-run] <name|path>       load (root)
--   modctl unload [-f] [-r] [--dry-run] <name>            unload (root)
--   modctl depmod                                         regenerate modules.idx (root)

local argparse = require("argparse")
local fs = require("filesystem")
local module = require("module")
local process = require("process")

local MODULES_DIR = "/usr/lib/modules"
local INDEX = MODULES_DIR .. "/modules.idx"

local parser = argparse("modctl", "List, inspect, load and unload kernel modules")
parser:require_command(false)
parser:command_target("action")

local listCmd = parser:command("list")
listCmd:flag("--drivers")
listCmd:flag("--modules")
listCmd:flag("--raw")
listCmd:flag("--lsmod")

parser:command("info"):argument("name")

local loadCmd = parser:command("load")
loadCmd:flag("--no-deps")
loadCmd:flag("--dry-run")
loadCmd:argument("target")

local unloadCmd = parser:command("unload")
unloadCmd:flag("-f --force")
unloadCmd:flag("-r --recursive")
unloadCmd:flag("--dry-run")
unloadCmd:argument("name")

parser:command("depmod")

local args = parser:parse({ ... })

local function fail(msg)
    io.stderr:write("modctl: " .. tostring(msg) .. "\n")
    os.exit(1)
end

local function pad(s, n)
    s = tostring(s or "-")
    if #s >= n then return s .. " " end
    return s .. string.rep(" ", n - #s)
end

local function names(list)
    if not list or #list == 0 then return "-" end
    return table.concat(list, ",")
end

local function requireRoot()
    local caller = process.getCurrent()
    if not caller or caller.euid ~= 0 then fail("Permission denied") end
end

-- the first table among the results of a call (dryRun returns the order)
local function firstTable(results)
    for i = 1, results.n do
        if type(results[i]) == "table" then return results[i] end
    end
    return nil
end

local function kindMatches(m, a)
    if not a.drivers and not a.modules then return true end
    return (a.drivers and m.kind == "driver") or (a.modules and m.kind == "module") or false
end

local function cmdList(a)
    local rows = {}
    for _, m in ipairs(module.list()) do
        if kindMatches(m, a) then rows[#rows + 1] = m end
    end
    if a.lsmod then
        print(pad("Module", 20) .. pad("Size", 10) .. "Used by")
        for _, m in ipairs(rows) do
            if m.state == "loaded" then
                local users = m.usedBy or {}
                local line = pad(m.name, 20) .. pad(m.size, 10) .. tostring(#users)
                if #users > 0 then line = line .. " " .. table.concat(users, ",") end
                print(line)
            end
        end
    elseif a.raw then
        for _, m in ipairs(rows) do
            print(table.concat({ m.name, m.kind, m.version or "-", names(m.usedBy), m.state }, "\t"))
        end
    else
        print(pad("NAME", 22) .. pad("KIND", 9) .. pad("VERSION", 12) .. pad("USED-BY", 26) .. "STATE")
        for _, m in ipairs(rows) do
            print(pad(m.name, 22) .. pad(m.kind, 9) .. pad(m.version, 12)
                .. pad(names(m.usedBy), 26) .. tostring(m.state))
        end
    end
end

local function formatDepends(deps)
    if not deps or #deps == 0 then return "-" end
    local out = {}
    for i, d in ipairs(deps) do
        if type(d) == "table" then
            out[i] = d[2] and (tostring(d[1]) .. ">=" .. tostring(d[2])) or tostring(d[1])
        else
            out[i] = tostring(d)
        end
    end
    return table.concat(out, ",")
end

local function formatAccess(access)
    if type(access) ~= "table" then return "-" end
    local keys = {}
    for k in pairs(access) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for i, k in ipairs(keys) do out[i] = k .. "=" .. tostring(access[k]) end
    return table.concat(out, ", ")
end

local function boundDevices(driverName)
    local device = require("device")
    local out = {}
    for _, b in ipairs(device.bindings()) do
        if b.driver == driverName then
            out[#out + 1] = b.address .. " (" .. tostring(b.state) .. ")"
        end
    end
    return out
end

local function cmdInfo(a)
    local info, err = module.info(a.name)
    if not info then fail(err or (a.name .. ": not found")) end
    local function line(key, value) print(key .. ": " .. tostring(value)) end
    line("name", info.name)
    line("kind", info.kind)
    line("desc", info.desc or "-")
    line("version", info.version or "-")
    line("version_n", info.version_n or "-")
    line("abi", info.abi or "-")
    line("depends", formatDepends(info.depends or info.deps))
    line("path", info.path or "-")
    line("state", info.state or (info.loaded and "loaded" or "available"))
    line("used-by", names(info.usedBy))
    if info.kind == "driver" then
        local drv = info.driver or {}
        line("match", names(drv.match))
        line("priority", drv.priority or 0)
        line("class", drv.class or "-")
        line("node", drv.node or "-")
        line("access", formatAccess(drv.access))
        local devices = boundDevices(info.name)
        line("devices", #devices > 0 and table.concat(devices, ", ") or "-")
    end
end

local function cmdLoad(a)
    requireRoot()
    local results = table.pack(module.load(a.target, { noDeps = a.no_deps, dryRun = a.dry_run }))
    if not results[1] then fail(results[2]) end
    if a.dry_run then
        for _, n in ipairs(firstTable(results) or {}) do print(n) end
    else
        print("loaded " .. tostring(results[2]))
    end
end

local function cmdUnload(a)
    requireRoot()
    local results = table.pack(module.unload(a.name, {
        force = a.force, recursive = a.recursive, dryRun = a.dry_run,
    }))
    if not results[1] then fail(results[2]) end
    if a.dry_run then
        for _, n in ipairs(firstTable(results) or {}) do print(n) end
    end
end

-- Adapter from the userland filesystem API to the fsio table that depmod uses.
local function fsAdapter()
    return {
        list = function(dir)
            local entries, err = fs.list(dir)
            if not entries then error(tostring(err), 0) end
            local out = {}
            for name in entries do
                if name:sub(-1) ~= "/" and fs.isDirectory(fs.concat(dir, name)) then
                    name = name .. "/"
                end
                out[#out + 1] = name
            end
            return out
        end,
        isDir = function(path) return fs.isDirectory(path) end,
        read = function(path)
            local handle, err = io.open(path, "r")
            if not handle then error(tostring(err), 0) end
            local data = handle:read("a")
            handle:close()
            return data
        end,
        size = function(path)
            local attr = fs.attributes(path)
            return (attr and tonumber(attr.size)) or 0
        end,
    }
end

local function cmdDepmod()
    requireRoot()
    local depmod = require("depmod")
    local ok, idx, errors, warnings = pcall(depmod.build, fsAdapter(), MODULES_DIR, MODULES_DIR)
    if not ok then fail(idx) end
    for _, w in ipairs(warnings or {}) do
        io.stderr:write("modctl: warning: " .. tostring(w) .. "\n")
    end
    if errors and #errors > 0 then
        for _, e in ipairs(errors) do io.stderr:write("modctl: " .. tostring(e) .. "\n") end
        fail("depmod: " .. #errors .. " error(s), " .. INDEX .. " not written")
    end
    local f, err = io.open(INDEX, "w")
    if not f then fail(err) end
    f:write(depmod.serialize(idx))
    f:close()
    module.reindex()
    local count = 0
    for _ in pairs(idx.modules or {}) do count = count + 1 end
    print("wrote " .. INDEX .. " (" .. count .. " entries)")
end

local command = args.action or "list"
if command == "list" then
    cmdList(args)
elseif command == "info" then
    cmdInfo(args)
elseif command == "load" then
    cmdLoad(args)
elseif command == "unload" then
    cmdUnload(args)
elseif command == "depmod" then
    cmdDepmod()
end
