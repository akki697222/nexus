-- tools/depmod.lua - build the driver index (drivers.idx)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Host-side tool (Lua 5.3+). Run from the nexus root:
--   lua tools/depmod.lua [drivers dir] [output]
--       defaults: root/usr/lib/drivers  root/usr/lib/drivers/drivers.idx
--
-- Every <name>.lua in the drivers directory is evaluated once, here on the
-- build host, in a stub sandbox; only the table it returns in `info` is
-- kept. The driver name is the file name. On the target, devmgr matches
-- components against this index and never runs driver code to decide.
--
-- Index format (a Lua chunk returning data only):
--   return { version = 1, drivers = {
--       { name, path, match = {..}, class, depends = {..}, desc,
--         node, mode, group, access = { op = "r"|"w"|"root" } },
--   } }
-- Order is by file name; for a component type the first match wins.

local depmod = {}

depmod.MOUNT = "/usr/lib/drivers"

-- Handled by the kernel and its modules; drivers never bind to these.
depmod.CORE_TYPES = {
    filesystem = true, gpu = true, screen = true,
    keyboard = true, eeprom = true, computer = true,
}

-- device_type vocabulary of src/device.lua
depmod.CLASSES = {
    volume = true, processor = true, data = true, display = true, input = true,
    system = true, communication = true, memory = true, eeprom = true,
    floppy = true, generic = true, multimedia = true, bus = true, power = true,
    network = true, audio = true,
}

local ACCESS = { r = true, w = true, rw = true, root = true }

-- A value that absorbs any use, for driver top-level code that touches its
-- declared modules while depmod evaluates it.
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
        computer = { uptime = function() return 0 end },
        devfs = { exists = function() return false end, list = function() return {} end },
        log = function() end,
        require = function() return stub end,
        checkArg = function() end,
    }
    env._G = env
    return env
end

local function isDigits(n)
    if math.type(n) ~= "integer" or n < 0 or n > 7777 then return false end
    for d in tostring(n):gmatch("%d") do
        if tonumber(d) > 7 then return false end
    end
    return true
end

local function stringList(v)
    if type(v) ~= "table" then return false end
    for i, s in ipairs(v) do
        if type(s) ~= "string" or s == "" then return false end
    end
    for k in pairs(v) do
        if math.type(k) ~= "integer" or k < 1 or k > #v then return false end
    end
    return true
end

-- Validates one driver's info. Returns the index entry or nil plus errors;
-- warnings are appended to `warn`.
---@param name string
---@param info any
---@param warn string[]
function depmod.check(name, info, warn)
    local errors = {}
    local function bad(msg) errors[#errors + 1] = name .. ": " .. msg end
    if type(info) ~= "table" then
        bad("driver.info is missing")
        return nil, errors
    end
    if not stringList(info.match) or #info.match == 0 then
        bad("info.match must be a non-empty list of component types")
    end
    if info.name ~= nil then
        warn[#warn + 1] = name .. ": info.name is ignored (the file name is the driver name)"
    end
    if info.depends ~= nil and not stringList(info.depends) then
        bad("info.depends must be a list of module names")
    end
    if info.class ~= nil then
        if type(info.class) ~= "string" then
            bad("info.class must be a string")
        elseif not depmod.CLASSES[info.class] then
            warn[#warn + 1] = name .. ": unknown class '" .. info.class .. "'"
        end
    end
    if info.desc ~= nil and type(info.desc) ~= "string" then bad("info.desc must be a string") end
    if info.node ~= nil and (type(info.node) ~= "string" or not info.node:match("^[a-z][a-z_]*$")) then
        bad("info.node must be a lowercase prefix (letters and _)")
    end
    if info.mode ~= nil and not isDigits(info.mode) then
        bad("info.mode must be octal digits written as a number, e.g. 660")
    end
    if info.group ~= nil and (type(info.group) ~= "string" or not info.group:match("^[%w_%-]+$")) then
        bad("info.group must be a group name")
    end
    if (info.mode ~= nil or info.group ~= nil or info.access ~= nil) and info.node == nil then
        warn[#warn + 1] = name .. ": mode/group/access have no effect without info.node"
    end
    if info.access ~= nil then
        if type(info.access) ~= "table" then
            bad("info.access must map op names to \"r\", \"w\", \"rw\" or \"root\"")
        else
            for op, need in pairs(info.access) do
                if type(op) ~= "string" or not ACCESS[need] then
                    bad("info.access." .. tostring(op) .. " must be \"r\", \"w\", \"rw\" or \"root\"")
                end
            end
        end
    end
    if #errors > 0 then return nil, errors end

    local match = {}
    for _, t in ipairs(info.match) do
        if depmod.CORE_TYPES[t] then
            warn[#warn + 1] = name .. ": '" .. t .. "' is a core type and is never bound"
        else
            match[#match + 1] = t
        end
    end
    local access
    if info.access then
        access = {}
        for op, need in pairs(info.access) do access[op] = need end
    end
    local depends = {}
    for i, d in ipairs(info.depends or {}) do depends[i] = d end
    return {
        name = name,
        path = depmod.MOUNT .. "/" .. name .. ".lua",
        match = match,
        class = info.class,
        depends = depends,
        desc = info.desc,
        node = info.node,
        mode = info.mode,
        group = info.group,
        access = access,
    }
end

-- Evaluates one driver source and returns its info table.
---@param name string
---@param source string
function depmod.evaluate(name, source)
    local chunk, err = load(source, "=" .. name .. ".lua", "t", sandbox())
    if not chunk then return nil, err end
    local ok, drv = pcall(chunk)
    if not ok then return nil, tostring(drv) end
    if type(drv) ~= "table" then return nil, "does not return a driver table" end
    if type(drv.attach) ~= "function" then return nil, "driver.attach is missing" end
    return drv.info
end

-- files: { { name = "chatbox", source = "..." }, ... } (any order)
-- Returns the index text, the list of warnings and the list of errors.
function depmod.generate(files)
    local sorted = {}
    for i, f in ipairs(files) do sorted[i] = f end
    files = sorted
    table.sort(files, function(a, b) return a.name < b.name end)
    local warn, errors, entries = {}, {}, {}
    local owner = {}
    for _, f in ipairs(files) do
        local info, e = depmod.evaluate(f.name, f.source)
        local entry, errs
        if e then
            errs = { f.name .. ": " .. e }
        else
            entry, errs = depmod.check(f.name, info, warn)
        end
        if entry then
            entries[#entries + 1] = entry
            for _, t in ipairs(entry.match) do
                if owner[t] then
                    warn[#warn + 1] = f.name .. ": '" .. t .. "' is already handled by "
                        .. owner[t] .. " (first match wins)"
                else
                    owner[t] = f.name
                end
            end
        else
            for _, m in ipairs(errs) do errors[#errors + 1] = m end
        end
    end
    return depmod.serialize(entries), warn, errors
end

local KEY_ORDER = { "name", "path", "match", "class", "depends", "desc", "node", "mode", "group", "access" }

local function value(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) == "number" then return tostring(math.tointeger(v) or v) end
    if type(v) == "table" then
        local parts = {}
        if #v > 0 then
            for _, x in ipairs(v) do parts[#parts + 1] = value(x) end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do parts[#parts + 1] = k .. " = " .. value(v[k]) end
        end
        return "{ " .. table.concat(parts, ", ") .. (#parts > 0 and " }" or "}")
    end
    return tostring(v)
end

function depmod.serialize(entries)
    local out = { "-- generated by tools/depmod.lua; do not edit", "return { version = 1, drivers = {" }
    for _, e in ipairs(entries) do
        local parts = {}
        for _, k in ipairs(KEY_ORDER) do
            if e[k] ~= nil then parts[#parts + 1] = k .. " = " .. value(e[k]) end
        end
        out[#out + 1] = "    { " .. table.concat(parts, ", ") .. " },"
    end
    out[#out + 1] = "} }"
    return table.concat(out, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- Host directory scanning
---------------------------------------------------------------------------

local windows = package.config:sub(1, 1) == "\\"

local function listLua(dir)
    local cmd
    if windows then
        cmd = 'dir /b /a-d "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul'
    else
        cmd = 'ls -1 "' .. dir .. '" 2>/dev/null'
    end
    local pipe = io.popen(cmd, "r")
    if not pipe then return nil end
    local names = {}
    for line in pipe:lines() do
        local n = line:gsub("\r$", ""):match("^([%w_%-]+)%.lua$")
        if n then names[#names + 1] = n end
    end
    pipe:close()
    return names
end

-- Builds the index for a host directory. Returns text, warnings, errors;
-- text is nil when the directory has no drivers.
function depmod.scan(dir)
    local names = listLua(dir) or {}
    local files = {}
    for _, n in ipairs(names) do
        local f = io.open(dir .. "/" .. n .. ".lua", "rb")
        if f then
            files[#files + 1] = { name = n, source = f:read("a") }
            f:close()
        end
    end
    if #files == 0 then return nil, {}, {} end
    return depmod.generate(files)
end

-- Writes <dir>/drivers.idx (or `out`). Prints warnings; returns false on
-- errors (the index is still written without the broken drivers).
function depmod.run(dir, out, quiet)
    dir = dir or "root/usr/lib/drivers"
    out = out or (dir .. "/drivers.idx")
    local text, warn, errors = depmod.scan(dir)
    for _, w in ipairs(warn) do io.stderr:write("depmod: warning: " .. w .. "\n") end
    for _, e in ipairs(errors) do io.stderr:write("depmod: error: " .. e .. "\n") end
    if not text then
        if not quiet then print("depmod: no drivers in " .. dir) end
        return true
    end
    local f, e = io.open(out, "wb")
    if not f then
        io.stderr:write("depmod: cannot write " .. out .. ": " .. tostring(e) .. "\n")
        return false
    end
    f:write(text)
    f:close()
    if not quiet then print("depmod: " .. out) end
    return #errors == 0
end

if arg and arg[0] and arg[0]:match("tools[/\\]depmod%.lua$") then
    os.exit(depmod.run(arg[1], arg[2]) and 0 or 1)
end

return depmod
