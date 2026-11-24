-- depmod: driver info extraction, validation, warnings, index format.
-- Run from the Nexus directory: lua tests/depmod.lua
local depmod = assert(loadfile("tools/depmod.lua"))()

local function has(list, pat)
    for _, m in ipairs(list) do if m:find(pat, 1, true) then return true end end
    return false
end

local files = {
    { name = "zeta", source = [[
        local snd = require("sound")   -- declared modules are stubs at build time
        snd.setup().more = 1
        log("loading")
        return { info = { match = { "chat_box" } }, attach = function() end }
    ]] },
    { name = "chatbox", source = [[
        local driver = { info = {
            match = { "chat_box", "gpu" }, class = "communication", depends = { "sound" },
            desc = "Chat box", node = "chat", mode = 660, group = "chat",
            access = { say = "w", getName = "r", setName = "root" },
        } }
        function driver.attach(dev) return {} end
        return driver
    ]] },
    { name = "badmode", source = [[ return { info = { match = { "x" }, node = "x", mode = 680 }, attach = function() end } ]] },
    { name = "badaccess", source = [[ return { info = { match = { "y" }, node = "y", access = { op = "rx" } }, attach = function() end } ]] },
    { name = "noattach", source = [[ return { info = { match = { "z" } } } ]] },
    { name = "noinfo", source = [[ return { attach = function() end } ]] },
    { name = "throws", source = [[ error("boom") ]] },
    { name = "named", source = [[ return { info = { name = "other", match = { "w" }, class = "weird", mode = 600 }, attach = function() end } ]] },
    { name = "badnode", source = [[ return { info = { match = { "v" }, node = "v1" }, attach = function() end } ]] },
}

local text, warn, errors = depmod.generate(files)

-- errors
assert(has(errors, "badmode: info.mode"))
assert(has(errors, "badaccess: info.access.op"))
assert(has(errors, "noattach: driver.attach is missing"))
assert(has(errors, "noinfo: driver.info is missing"))
assert(has(errors, "throws:") and has(errors, "boom"))
assert(has(errors, "badnode: info.node"))
assert(#errors == 6, #errors)

-- warnings
assert(has(warn, "chatbox: 'gpu' is a core type"))
assert(has(warn, "zeta: 'chat_box' is already handled by chatbox"), "first match by file name wins")
assert(has(warn, "named: info.name is ignored"))
assert(has(warn, "named: unknown class 'weird'"))
assert(has(warn, "named: mode/group/access have no effect without info.node"))

-- the index is data only and loads in an empty environment
local idx = assert(load(text, "=drivers.idx", "t", {}))()
assert(idx.version == 1)
local names = {}
for i, d in ipairs(idx.drivers) do names[i] = d.name end
assert(table.concat(names, ",") == "chatbox,named,zeta", table.concat(names, ","))
local c = idx.drivers[1]
assert(c.path == "/usr/lib/drivers/chatbox.lua")
assert(#c.match == 1 and c.match[1] == "chat_box", "core types are dropped from the index")
assert(c.class == "communication" and c.depends[1] == "sound" and c.desc == "Chat box")
assert(c.node == "chat" and c.mode == 660 and c.group == "chat")
assert(c.access.say == "w" and c.access.getName == "r" and c.access.setName == "root")
assert(idx.drivers[2].name == "named", "the file name is the driver name")

-- deterministic output, the caller's list is left alone
assert(files[1].name == "zeta")
local text2 = depmod.generate(files)
assert(text == text2)

-- run() on a host directory
local dir = os.tmpname()
os.remove(dir)
assert(os.execute('mkdir "' .. dir .. '"'))
local f = assert(io.open(dir .. "/chatbox.lua", "w"))
f:write(files[2].source)
f:close()
f = assert(io.open(dir .. "/notes.txt", "w"))
f:write("ignored")
f:close()
assert(depmod.run(dir, nil, true))
local out = assert(io.open(dir .. "/drivers.idx")):read("a")
local idx2 = assert(load(out, "=drivers.idx", "t", {}))()
assert(#idx2.drivers == 1 and idx2.drivers[1].name == "chatbox")
os.remove(dir .. "/chatbox.lua")
os.remove(dir .. "/notes.txt")
os.remove(dir .. "/drivers.idx")
os.remove(dir)

-- a missing directory is not an error (nothing to index)
assert(depmod.run(dir .. "-missing", nil, true))

print("depmod tests passed")
