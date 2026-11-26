-- depmod: the module index from plain modules and drivers (root/usr/lib/
-- libdepmod.lua, its host wrapper tools/depmod.lua): checks, warnings, text.
-- Run from the Nexus directory: lua tests/tools/depmod.lua
local depmod = assert(loadfile("tools/depmod.lua"))()

local function has(list, text)
    for _, m in ipairs(list) do
        if m:find(text, 1, true) then return true end
    end
    return false
end

-- an fsio over a table: files[path] = source; directories are implied
local function memfs(files)
    local fs = {}
    function fs.isDir(p)
        local prefix = p .. "/"
        for path in pairs(files) do
            if path:sub(1, #prefix) == prefix then return true end
        end
        return false
    end
    function fs.list(dir)
        local prefix, seen, names = dir .. "/", {}, {}
        for path in pairs(files) do
            if path:sub(1, #prefix) == prefix then
                local rest = path:sub(#prefix + 1)
                local slash = rest:find("/", 1, true)
                local n = slash and rest:sub(1, slash) or rest
                if not seen[n] then
                    seen[n] = true
                    names[#names + 1] = n
                end
            end
        end
        return names
    end
    function fs.read(p)
        if files[p] then return files[p] end
        return nil, "no such file"
    end
    function fs.size(p) return files[p] and #files[p] end
    return fs
end

local GOOD = {
    ["mods/system/kernel/debug.lua"] = [[
local module = require("module")
return {
    manifest = { name = "debug", desc = "debugging aids", version = "0.1.0", version_n = 1, abi = 1 },
    load = function() end,
    unload = function() end,
    module = {},
}
]],
    ["mods/system/kernel/drivers/tty/tty.lua"] = [[
return {
    manifest = { name = "tty", desc = "tty driver", version = "0.1.1", version_n = 2 },
    load = function() end,
    unload = function() end,
    module = {},
}
]],
    ["mods/system/kernel/drivers/tty/vt.lua"] = [[
return {
    manifest = { name = "vt", desc = "virtual terminal", version = "0.1.0", version_n = 1, abi = 1, depends = {} },
    load = function() end,
    unload = function() end,
    module = {},
}
]],
    ["mods/system/kernel/drivers/network/internet.drv.lua"] = [[
local event = require("event")
local driver = {
    match = { "internet", "gpu" }, class = "network", node = "eth", mode = 660, group = "ethernet",
    access = { isHttpEnabled = "open", connect = "rw" },
}
function driver.attach(dev) return {} end
return {
    manifest = { name = "internet", desc = "Internet Card", version = "0.1.0", version_n = 1, abi = 1,
        depends = { "tty", { "vt", 2 } } },
    load = function() end,
    unload = function() end,
    module = {},
    driver = driver,
}
]],
    ["mods/system/kernel/drivers/audio/audio.drv.lua"] = [[
local driver = { match = { "audio" }, priority = 5, class = "audio" }
function driver.attach(dev) return {} end
return {
    manifest = { name = "audio", desc = "Audio card", version = "0.1.0", version_n = 1, abi = 1, depends = { "tty" } },
    load = function() end,
    unload = function() end,
    module = {},
    driver = driver,
}
]],
    ["mods/readme.txt"] = "not a module",
}

local PREFIX = "/usr/lib/modules"
local idx, errors, warn = depmod.build(memfs(GOOD), "mods", PREFIX)
assert(#errors == 0, table.concat(errors, "; "))
assert(has(warn, "tty.lua: manifest.abi is missing"), "optional fields only warn")
assert(has(warn, "internet.drv.lua: 'gpu' is a core type"))
assert(has(warn, "needs vt version 2, index has 1"))
assert(not has(warn, "circular"))

assert(idx.version == 2 and idx.abi == 1)
local m = idx.modules
local count = 0
for _ in pairs(m) do count = count + 1 end
assert(count == 5, count)
assert(m.debug.kind == "module" and m.debug.path == PREFIX .. "/system/kernel/debug.lua")
assert(m.debug.abi == 1 and m.debug.size == #GOOD["mods/system/kernel/debug.lua"])
assert(#m.debug.depends == 0 and m.debug.driver == nil and m.debug.name == nil, "names are keys")
assert(m.tty.kind == "module" and m.tty.version_n == 2 and m.tty.abi == nil)
assert(m.tty.path == PREFIX .. "/system/kernel/drivers/tty/tty.lua")
assert(m.internet.kind == "driver" and m.internet.path:sub(-#"internet.drv.lua") == "internet.drv.lua")
local d = m.internet.driver
assert(#d.match == 1 and d.match[1] == "internet", "core types are dropped")
assert(d.node == "eth" and d.mode == 660 and d.group == "ethernet" and d.priority == 0)
assert(d.access.isHttpEnabled == "open" and d.access.connect == "rw")
assert(m.internet.depends[2][1] == "vt" and m.internet.depends[2][2] == 2)
assert(m.audio.driver.priority == 5 and m.audio.driver.node == nil)

-- the text: deterministic, loads with no environment, one module a line
local text = depmod.serialize(idx)
assert(depmod.serialize((depmod.build(memfs(GOOD), "mods", PREFIX))) == text, "deterministic")
local loaded = assert(load(text, "=modules.idx", "t", {}))()
assert(loaded.abi == 1 and loaded.modules.internet.driver.mode == 660)
assert(depmod.serialize(loaded) == text, "the text round-trips")
local lines = 0
for line in text:gmatch("[^\n]+") do
    if line:find('"] = {', 1, true) then lines = lines + 1 end
end
assert(lines == 5, lines)

-- an empty or missing directory gives an empty index, not an error
local none, noneErr = depmod.build(memfs({}), "nothing", PREFIX)
assert(#noneErr == 0 and next(none.modules) == nil)

-- broken files: each is an error, the good one still indexes
local BAD = {
    ["bad/good.lua"] = [[return { manifest = { name = "good", desc = "fine", version = "1", version_n = 1, abi = 1 } }]],
    ["bad/mode.drv.lua"] = [[return { manifest = { name = "mode", version_n = 1, abi = 1 },
        driver = { match = { "m" }, node = "m", mode = 680, attach = function() end } }]],
    ["bad/access.drv.lua"] = [[return { manifest = { name = "access", version_n = 1, abi = 1 },
        driver = { match = { "a" }, access = { op = "rx" }, attach = function() end } }]],
    ["bad/noattach.drv.lua"] = [[return { manifest = { name = "noattach", version_n = 1, abi = 1 },
        driver = { match = { "n" } } }]],
    ["bad/nodriver.drv.lua"] = [[return { manifest = { name = "nodriver", version_n = 1, abi = 1 } }]],
    ["bad/plaindrv.lua"] = [[return { manifest = { name = "plaindrv", version_n = 1, abi = 1 },
        driver = { match = { "p" }, attach = function() end } }]],
    ["bad/throws.lua"] = [[error("boom")]],
    ["bad/syntax.lua"] = [[return {]],
    ["bad/abi.lua"] = [[return { manifest = { name = "abi", version_n = 1, abi = 2 } }]],
    ["bad/wrongname.drv.lua"] = [[return { manifest = { name = "other", version_n = 1, abi = 1 },
        driver = { match = { "w" }, attach = function() end } }]],
    ["bad/dupe1.lua"] = [[return { manifest = { name = "dupe", version_n = 1, abi = 1 } }]],
    ["bad/dupe2.lua"] = [[return { manifest = { name = "dupe", version_n = 1, abi = 1 } }]],
    ["bad/cyc_a.lua"] = [[return { manifest = { name = "cyc_a", version_n = 1, abi = 1, depends = { "cyc_b" } } }]],
    ["bad/cyc_b.lua"] = [[return { manifest = { name = "cyc_b", version_n = 1, abi = 1, depends = { "cyc_a" } } }]],
    ["bad/user.lua"] = [[return { manifest = { name = "user", version_n = 1, abi = 1, depends = { "ghost" } } }]],
}
local bidx, berrors, bwarn = depmod.build(memfs(BAD), "bad", PREFIX)
assert(#berrors == 10, #berrors .. ": " .. table.concat(berrors, "; "))
assert(has(berrors, "mode.drv.lua: driver.mode must be octal"))
assert(has(berrors, "access.drv.lua: driver.access.op"))
assert(has(berrors, "noattach.drv.lua: driver.attach is missing"))
assert(has(berrors, "nodriver.drv.lua: driver file must define a driver table"))
assert(has(berrors, "plaindrv.lua: driver table in a non-.drv.lua file"))
assert(has(berrors, "throws.lua: throws.lua:1: boom"))
assert(has(berrors, "syntax.lua: syntax.lua:"))
assert(has(berrors, "abi.lua: manifest.abi 2"))
assert(has(berrors, "wrongname.drv.lua: driver name must match file name"))
assert(has(berrors, "dupe2.lua: module 'dupe' is already defined by dupe1.lua"))
assert(has(bwarn, "circular dependency: cyc_a -> cyc_b -> cyc_a"))
assert(has(bwarn, "depends on 'ghost', which is not in the index"))
local bcount = 0
for n in pairs(bidx.modules) do bcount = bcount + 1 end
assert(bcount == 5 and bidx.modules.good and bidx.modules.dupe and bidx.modules.user)
assert(bidx.modules.mode == nil and bidx.modules.plaindrv == nil)

-- host wrapper on a directory: exit status and the index file
local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return s
end
local function put(dir, name, source)
    local f = assert(io.open(dir .. "/" .. name, "wb"))
    f:write(source)
    f:close()
end

local dir = os.tmpname()
os.remove(dir)
assert(os.execute('mkdir "' .. dir .. '"'))
put(dir, "debug.lua", GOOD["mods/system/kernel/debug.lua"])
put(dir, "audio.drv.lua", GOOD["mods/system/kernel/drivers/audio/audio.drv.lua"])
put(dir, "notes.txt", "ignored")
local out = dir .. ".idx"
assert(depmod.run(dir, out, true), "a clean directory")
local idx2 = assert(load(readAll(out), "=modules.idx", "t", {}))()
assert(idx2.modules.debug and idx2.modules.audio.driver.priority == 5)

put(dir, "bad.drv.lua", BAD["bad/mode.drv.lua"])
assert(not depmod.run(dir, out, true), "a broken module fails the run")
assert(io.open(out, "rb"), "the index is still written")
os.remove(dir .. "/bad.drv.lua")

local lua = (arg and arg[-1]) or "lua"
assert(os.execute('"' .. lua .. '" tools/depmod.lua "' .. dir .. '" "' .. out .. '"') == true, "cli ok")
put(dir, "bad.drv.lua", BAD["bad/mode.drv.lua"])
assert(not os.execute('"' .. lua .. '" tools/depmod.lua "' .. dir .. '" "' .. out .. '"'), "cli exits 1")
os.remove(dir .. "/bad.drv.lua")

assert(depmod.run(dir .. "-missing", nil, true), "a missing directory is not an error")

for _, n in ipairs({ "debug.lua", "audio.drv.lua", "notes.txt" }) do os.remove(dir .. "/" .. n) end
os.remove(out)
os.remove(dir)

print("depmod tests passed")
