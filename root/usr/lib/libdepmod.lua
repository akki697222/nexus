-- libdepmod.lua - the module index (modules.idx): scan, check, serialize
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Userland: require("depmod"), on the target (modctl depmod) and on the host
-- (tools/depmod.lua). Pure: all file access goes through an fsio table:
--   fsio.isDir(path) -> boolean
--   fsio.list(dir)   -> names in dir, directories with a trailing "/"; nil on error
--   fsio.read(path)  -> string, or nil and why
--   fsio.size(path)  -> size in bytes
--
--   depmod.build(fsio, root, prefix) -> idx, errors, warnings
--   depmod.scan(fsio, root, prefix)  -> entries, errors, warnings
--   depmod.serialize(idx)            -> text of modules.idx (a data-only chunk)
--   depmod.evaluate(source, name)    -> table, or nil and why
--
-- root is the directory of the modules on fsio; prefix is the path the target
-- sees for it (depmod.MOUNT). A *.lua file below root is a module; a file
-- named *.drv.lua with a driver table is a driver. Each file is evaluated once
-- where require returns a stub that absorbs any use; only the manifest and
-- driver tables are read. Side effects belong in load(), unload(), attach().

local depmod = {}

depmod.MOUNT = "/usr/lib/modules"
depmod.ABI = 1
depmod.VERSION = 2

-- Handled by the kernel and its modules; drivers never bind to these.
depmod.CORE_TYPES = {
    filesystem = true, gpu = true, screen = true,
    keyboard = true, eeprom = true, computer = true,
}

-- device_type vocabulary of src/dev/device.lua
depmod.CLASSES = {
    volume = true, processor = true, data = true, display = true, input = true,
    system = true, communication = true, memory = true, eeprom = true,
    floppy = true, generic = true, multimedia = true, bus = true, power = true,
    network = true, audio = true,
}

local ACCESS = { r = true, w = true, rw = true, root = true, open = true }

-- The value of require() while a file is evaluated: absorbs any use.
local stub
stub = setmetatable({}, {
    __index = function() return stub end,
    __call = function() return stub end,
    __newindex = function() end,
})

local function sandbox()
    local env = {
        assert = assert, error = error, ipairs = ipairs, pairs = pairs,
        next = next, pcall = pcall, xpcall = xpcall, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        rawequal = rawequal, rawget = rawget, rawlen = rawlen, rawset = rawset,
        setmetatable = setmetatable, getmetatable = getmetatable,
        string = setmetatable({}, { __index = string }),
        table = setmetatable({}, { __index = table }),
        math = setmetatable({}, { __index = math }),
        utf8 = setmetatable({}, { __index = utf8 }),
        coroutine = setmetatable({}, { __index = coroutine }),
        require = function() return stub end,
    }
    env._G = env
    return env
end

-- Evaluates one module source. name is the file path for error messages.
---@param source string
---@param name string
---@return table|nil, string|nil
function depmod.evaluate(source, name)
    local chunk, err = load(source, "=" .. name, "t", sandbox())
    if not chunk then return nil, err end
    local ok, res = pcall(chunk)
    if not ok then return nil, tostring(res) end
    if type(res) ~= "table" then return nil, "does not return a table" end
    return res
end

local function isInt(v) return math.type(v) == "integer" end

local function isDigits(n)
    if not isInt(n) or n < 0 or n > 7777 then return false end
    for d in tostring(n):gmatch("%d") do
        if tonumber(d) > 7 then return false end
    end
    return true
end

local function stringList(v)
    if type(v) ~= "table" then return false end
    for _, s in ipairs(v) do
        if type(s) ~= "string" or s == "" then return false end
    end
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    return count == #v
end

-- Checks the driver table. Returns the index part of the entry, or nil when
-- there are errors; warnings are appended to warn.
local function checkDriver(rel, drv, warn, errors)
    local before = #errors
    local function bad(msg) errors[#errors + 1] = rel .. ": " .. msg end
    local function note(msg) warn[#warn + 1] = rel .. ": " .. msg end
    if type(drv.attach) ~= "function" then bad("driver.attach is missing") end
    if not stringList(drv.match) or #drv.match == 0 then
        bad("driver.match must be a non-empty list of component types")
    end
    if drv.priority ~= nil and not isInt(drv.priority) then bad("driver.priority must be an integer") end
    if drv.class ~= nil then
        if type(drv.class) ~= "string" then
            bad("driver.class must be a string")
        elseif not depmod.CLASSES[drv.class] then
            note("unknown class '" .. drv.class .. "'")
        end
    end
    if drv.node ~= nil and (type(drv.node) ~= "string" or not drv.node:match("^[a-z][a-z_]*$")) then
        bad("driver.node must be a lowercase prefix (letters and _)")
    end
    if drv.mode ~= nil and not isDigits(drv.mode) then
        bad("driver.mode must be octal digits written as a number, e.g. 660")
    end
    if drv.group ~= nil and (type(drv.group) ~= "string" or not drv.group:match("^[%w_%-]+$")) then
        bad("driver.group must be a group name")
    end
    if (drv.mode ~= nil or drv.group ~= nil or drv.access ~= nil) and drv.node == nil then
        note("mode/group/access have no effect without driver.node")
    end
    if drv.access ~= nil then
        if type(drv.access) ~= "table" then
            bad("driver.access must map op names to \"r\", \"w\", \"rw\", \"root\" or \"open\"")
        else
            for op, need in pairs(drv.access) do
                if type(op) ~= "string" or not ACCESS[need] then
                    bad("driver.access." .. tostring(op) .. " must be \"r\", \"w\", \"rw\", \"root\" or \"open\"")
                end
            end
        end
    end
    if #errors > before then return nil end

    local match = {}
    for _, t in ipairs(drv.match) do
        if depmod.CORE_TYPES[t] then
            note("'" .. t .. "' is a core type and is never bound")
        else
            match[#match + 1] = t
        end
    end
    local access
    if drv.access then
        access = {}
        for op, need in pairs(drv.access) do access[op] = need end
    end
    return {
        match = match, priority = drv.priority or 0, class = drv.class,
        node = drv.node, mode = drv.mode, group = drv.group, access = access,
    }
end

-- Checks one evaluated file. rel is the path below the modules directory,
-- path the one the target sees. Returns an entry (its name is the key of
-- the index) or nil; problems go to errors, optional fields to warn.
local function checkModule(rel, path, mod, warn, errors)
    local before = #errors
    local base = rel:match("([^/]+)$")
    local isDriverFile = base:sub(-8) == ".drv.lua"
    local stem = isDriverFile and base:sub(1, -9) or base:sub(1, -5)
    local function bad(msg) errors[#errors + 1] = rel .. ": " .. msg end
    local function note(msg) warn[#warn + 1] = rel .. ": " .. msg end

    local m = mod.manifest
    if type(m) ~= "table" then
        bad("manifest table is missing")
        return nil
    end
    if type(m.name) ~= "string" or not m.name:match("^[%w_%-]+$") then
        bad("manifest.name must be a module name")
        return nil
    end
    if m.name ~= stem then
        if isDriverFile then
            bad("driver name must match file name")
            return nil
        end
        note("file name '" .. stem .. "' differs from manifest name '" .. m.name .. "'")
    end

    local drv = mod.driver
    if isDriverFile and drv == nil then
        bad("driver file must define a driver table")
        return nil
    end
    if not isDriverFile and drv ~= nil then
        bad("driver table in a non-.drv.lua file")
        return nil
    end

    if m.desc == nil then
        note("manifest.desc is missing")
    elseif type(m.desc) ~= "string" then
        bad("manifest.desc must be a string")
    end
    if m.version == nil then
        note("manifest.version is missing")
    elseif type(m.version) ~= "string" then
        bad("manifest.version must be a string")
    end
    if m.version_n == nil then
        note("manifest.version_n is missing")
    elseif not isInt(m.version_n) or m.version_n < 0 then
        bad("manifest.version_n must be a non-negative integer")
    end
    if m.abi == nil then
        note("manifest.abi is missing, the kernel will not check it")
    elseif m.abi ~= depmod.ABI then
        bad("manifest.abi " .. tostring(m.abi) .. ", this depmod builds ABI " .. depmod.ABI)
    end

    -- normalised to { name, min_version_n | nil }
    local depends = {}
    if m.depends ~= nil then
        local count = type(m.depends) == "table" and 0 or nil
        if count then
            for _ in pairs(m.depends) do count = count + 1 end
        end
        if not count or count ~= #m.depends then
            bad("manifest.depends must be a list")
        else
            for _, d in ipairs(m.depends) do
                if type(d) == "string" and d:match("^[%w_%-]+$") then
                    depends[#depends + 1] = { d }
                elseif type(d) == "table" and type(d[1]) == "string" and d[1]:match("^[%w_%-]+$")
                    and (d[2] == nil or isInt(d[2])) and #d == (d[2] and 2 or 1) then
                    depends[#depends + 1] = { d[1], d[2] }
                else
                    bad("manifest.depends entries are names or {name, version_n}")
                end
            end
        end
    end

    local driver
    if drv then
        driver = checkDriver(rel, drv, warn, errors)
    end
    if #errors > before then return nil end
    return {
        name = m.name, path = path, kind = drv and "driver" or "module",
        desc = m.desc, version = m.version, version_n = m.version_n, abi = m.abi,
        depends = depends, driver = driver,
    }
end

-- Scans root (recursively, sorted) and checks every *.lua file.
---@return table entries, string[] errors, string[] warnings
function depmod.scan(fsio, root, prefix)
    local entries, errors, warn = {}, {}, {}
    if not fsio.isDir(root) then return entries, errors, warn end
    local files = {}
    local function walk(dir, rel)
        local names = fsio.list(dir)
        if not names then
            errors[#errors + 1] = "cannot list " .. dir
            return
        end
        table.sort(names)
        for _, n in ipairs(names) do
            if n:sub(-1) == "/" then
                walk(dir .. "/" .. n:sub(1, -2), rel .. n)
            elseif n:sub(-4) == ".lua" then
                files[#files + 1] = rel .. n
            end
        end
    end
    walk(root, "")
    table.sort(files)

    local seen = {}
    for _, rel in ipairs(files) do
        local file = root .. "/" .. rel
        local src, err = fsio.read(file)
        if not src then
            errors[#errors + 1] = rel .. ": cannot read: " .. tostring(err)
        else
            local mod, e = depmod.evaluate(src, rel)
            if not mod then
                errors[#errors + 1] = rel .. ": " .. e
            else
                local entry = checkModule(rel, prefix .. "/" .. rel, mod, warn, errors)
                if entry then
                    entry.size = fsio.size(file)
                    if seen[entry.name] then
                        errors[#errors + 1] = rel .. ": module '" .. entry.name
                            .. "' is already defined by " .. seen[entry.name]
                    else
                        seen[entry.name] = rel
                        entries[#entries + 1] = entry
                    end
                end
            end
        end
    end
    return entries, errors, warn
end

-- Builds the index: { version, abi, modules = { [name] = entry } }. Missing
-- dependencies and version minimums are warnings, and so are cycles.
---@return table idx, string[] errors, string[] warnings
function depmod.build(fsio, root, prefix)
    local entries, errors, warn = depmod.scan(fsio, root, prefix)
    local modules = {}
    for _, e in ipairs(entries) do modules[e.name] = e end
    local names = {}
    for n in pairs(modules) do names[#names + 1] = n end
    table.sort(names)

    for _, n in ipairs(names) do
        local e = modules[n]
        for _, d in ipairs(e.depends) do
            local dep = modules[d[1]]
            if not dep then
                warn[#warn + 1] = e.path .. ": depends on '" .. d[1] .. "', which is not in the index"
            elseif d[2] and (dep.version_n or 0) < d[2] then
                warn[#warn + 1] = e.path .. ": needs " .. d[1] .. " version " .. d[2]
                    .. ", index has " .. tostring(dep.version_n)
            end
        end
    end

    -- depth-first walk; a edge back to a module on the stack is a cycle
    local state, stack = {}, {}
    local function visit(n)
        if state[n] == 2 then return end
        if state[n] == 1 then
            local start
            for i, s in ipairs(stack) do
                if s == n then start = i break end
            end
            local cycle = {}
            for i = start, #stack do cycle[#cycle + 1] = stack[i] end
            cycle[#cycle + 1] = n
            warn[#warn + 1] = "circular dependency: " .. table.concat(cycle, " -> ")
            return
        end
        state[n] = 1
        stack[#stack + 1] = n
        for _, d in ipairs(modules[n].depends) do
            if modules[d[1]] then visit(d[1]) end
        end
        stack[#stack] = nil
        state[n] = 2
    end
    for _, n in ipairs(names) do visit(n) end

    -- the name is the key in the index, not a field of the entry
    for _, n in ipairs(names) do modules[n].name = nil end
    return { version = depmod.VERSION, abi = depmod.ABI, modules = modules }, errors, warn
end

local function quote(s) return string.format("%q", s) end

-- One Lua value: strings quoted, arrays as lists, other tables with sorted keys.
local function value(v)
    local t = type(v)
    if t == "string" then return quote(v) end
    if t == "number" then return tostring(math.tointeger(v) or v) end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" then error("cannot serialize a " .. t, 0) end
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    if count == 0 then return "{}" end
    local parts = {}
    if count == #v then
        for i = 1, #v do parts[i] = value(v[i]) end
    else
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= "string" then error("cannot serialize key " .. tostring(k), 0) end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for i, k in ipairs(keys) do
            local key = k:match("^[%a_][%w_]*$") and k or "[" .. quote(k) .. "]"
            parts[i] = key .. " = " .. value(v[k])
        end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

-- The text of modules.idx: one module per line, sorted by name.
function depmod.serialize(idx)
    local names = {}
    for n in pairs(idx.modules) do names[#names + 1] = n end
    table.sort(names)
    local out = {
        "-- generated by depmod (libdepmod.lua); do not edit",
        "return {",
        "    version = " .. idx.version .. ",",
        "    abi = " .. idx.abi .. ",",
        "    modules = {",
    }
    for _, n in ipairs(names) do
        out[#out + 1] = "        [" .. quote(n) .. "] = " .. value(idx.modules[n]) .. ","
    end
    out[#out + 1] = "    },"
    out[#out + 1] = "}"
    return table.concat(out, "\n") .. "\n"
end

return depmod
