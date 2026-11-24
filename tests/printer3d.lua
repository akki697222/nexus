-- printer3d sample driver and print3d command.
-- Run from the Nexus directory: lua tests/printer3d.lua
local depmod = assert(loadfile("tools/depmod.lua"))()

local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("a")
    f:close()
    return s
end

local source = read("root/usr/lib/drivers/printer3d.lua")

-- the index entry is valid and warning-free
local text, warn, errors = depmod.generate({ { name = "printer3d", source = source } })
assert(#errors == 0, table.concat(errors, "\n"))
assert(#warn == 0, table.concat(warn, "\n"))
local idx = assert(load(text, "=idx", "t", {}))()
local entry = idx.drivers[1]
assert(entry.node == "printer" and entry.mode == 660 and entry.group == "lp")
assert(entry.access.print == "w" and entry.access.status == "r")

-- load the driver as devmgr does (no component/computer in its env)
local logs = {}
local env = {
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring, tonumber = tonumber,
    error = error, pcall = pcall, select = select, setmetatable = setmetatable,
    string = string, table = table, math = math,
    log = function(msg) logs[#logs + 1] = msg end,
}
local drv = assert(load(source, "=printer3d.lua", "t", env))()

-- every op in info.access is implemented
for op in pairs(drv.info.access) do
    assert(type(drv.ops[op]) == "function", "missing op " .. op)
end

local calls, emitted = {}, {}
local busy = false
local proxy = {
    status = function() return busy and "busy" or "idle", busy and 40 or true end,
    getMaxShapeCount = function() return 2 end,
    getShapeCount = function() return 0, 0 end,
    reset = function() calls[#calls + 1] = "reset" end,
    setLabel = function(v) calls[#calls + 1] = "label=" .. v end,
    setTooltip = function(v) calls[#calls + 1] = "tooltip=" .. v end,
    setButtonMode = function(v) calls[#calls + 1] = "button=" .. tostring(v) end,
    setRedstoneEmitter = function(v) calls[#calls + 1] = "redstone=" .. tostring(v) end,
    addShape = function(x1, y1, z1, x2, y2, z2, tex, state, tint)
        calls[#calls + 1] = string.format("shape %d,%d,%d-%d,%d,%d %s %s %s", x1, y1, z1, x2, y2, z2,
            tex, tostring(state), tostring(tint))
        return true
    end,
    commit = function(n)
        if busy then return false, "busy" end
        calls[#calls + 1] = "commit " .. n
        busy = true
        return true
    end,
}
local dev = {
    address = "abcdef0123", type = "printer3d", proxy = proxy,
    emit = function(name, ...) emitted[#emitted + 1] = { name, ... } end,
}
local inst = assert(drv.attach(dev))
assert(logs[1]:find("abcdef01") and logs[1]:find("max 2"))

local model = {
    label = "Lamp", tooltip = "glows", buttonMode = false, emitRedstone = true,
    shapes = {
        { 0, 0, 0, 16, 8, 16, texture = "stone" },
        { 4, 8, 4, 12, 16, 12, texture = "glass", state = true, tint = 0xff0000 },
    },
}
assert(drv.ops.print(inst, model, 2))
assert(table.concat(calls, "|") == table.concat({
    "reset", "label=Lamp", "tooltip=glows", "button=false", "redstone=true",
    "shape 0,0,0-16,8,16 stone false nil",
    "shape 4,8,4-12,16,12 glass true 16711680",
    "commit 2",
}, "|"), table.concat(calls, "|"))
assert(emitted[1][1] == "printer_job" and emitted[1][2] == 2)
assert(drv.ops.jobs(inst) == 1)

-- busy printer, bad input
assert(select(2, drv.ops.print(inst, model)) == "printer is busy")
busy = false
assert(select(2, drv.ops.print(inst, {})) == "model has no shapes")
assert(select(2, drv.ops.print(inst, model, 0)) == "invalid count")
assert(select(2, drv.ops.print(inst, { shapes = { { 1, 2 } } })):find("shape 1"))
assert(select(2, drv.ops.print(inst, { shapes = { {0,0,0,1,1,1}, {0,0,0,1,1,1}, {0,0,0,1,1,1}, {0,0,0,1,1,1}, {0,0,0,1,1,1} } })):find("too many"))

-- passthrough and missing methods
assert(drv.ops.status(inst) == "idle")
assert(select(2, drv.ops.getLightLevel(inst)) == "not supported")
assert(drv.ops.commit(inst) and calls[#calls] == "commit 1")
drv.detach(inst)

------------------------------------------------------------
-- print3d command
------------------------------------------------------------
local opened = {}
local fakeHandle
local deviceLib = {
    open = function(path, mode)
        opened[#opened + 1] = path .. ":" .. mode
        if path ~= "/dev/printer0" then return nil, "No such device" end
        fakeHandle = {
            print = function(m, n) fakeHandle.printed = { m, n }; return true end,
            status = function() return "busy", 30 end,
            jobs = function() return 3 end,
        }
        return fakeHandle
    end,
    close = function(h) h.closed = true; return true end,
}
local argparse = assert(loadfile("root/usr/lib/libargparse.lua"))()
local out, exitCode = {}, nil
local modelPath = os.tmpname()
local mf = assert(io.open(modelPath, "w"))
mf:write('{ label = "Cube", shapes = { { 0, 0, 0, 16, 16, 16, texture = "planks_oak" } } }')
mf:close()
local function run(...)
    out, exitCode = {}, nil
    local cenv = setmetatable({
        require = function(n)
            if n == "argparse" then return argparse end
            if n == "device" then return deviceLib end
            error(n)
        end,
        print = function(s) out[#out + 1] = s end,
        io = {
            open = io.open,
            stderr = { write = function(_, s) out[#out + 1] = "ERR " .. s end },
        },
        os = { exit = function(c) exitCode = c; error("exit", 0) end },
    }, { __index = _G })
    local chunk = assert(loadfile("root/usr/bin/print3d.lua", "t", cenv))
    local ok, e = pcall(chunk, ...)
    if not ok and e ~= "exit" then error(e) end
end

run(modelPath, "3")
assert(exitCode == nil, table.concat(out, "\n"))
assert(opened[#opened] == "/dev/printer0:w")
assert(fakeHandle.printed[1].label == "Cube" and fakeHandle.printed[2] == 3 and fakeHandle.closed)
assert(out[1]:find("printing 3 x Cube"))

run(modelPath, "-s")
assert(opened[#opened] == "/dev/printer0:r" and out[1]:find("busy 30%%") and out[1]:find("3 job"))

run(modelPath, "-d", "/dev/printer9")
assert(exitCode == 1 and out[1]:find("No such device"))

-- the model file is read as data, not run
mf = assert(io.open(modelPath, "w"))
mf:write('{ shapes = {} }, os.exit(42)')
mf:close()
run(modelPath)
assert(exitCode == 1, "model files cannot run code")
os.remove(modelPath)

print("printer3d driver tests passed")
