-- Run from the Nexus directory: lua tests/pipeline_integration.lua
local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local main = readSource("src/main.lua")
local scheduler = assert(main:match("    (runProcessQueue = function.-)\n    resumeKernelThreads"))
local setup = [[
local process, io
local event
]]
local harness = [[
local input, output, errors = "", {}, {}
local commands = {}
local files = { ["/data"] = ("abc\0\255xyz\n"):rep(4000) }

event = { removeQueue = function() end }
printk = function(message) errors[#errors + 1] = message end
permission = { canSetUID = function() return false end, canSetGID = function() return false end }
local function copy(values)
    local result = {}
    for key, value in pairs(values or {}) do result[key] = value end
    return result
end
util = { copyTable = copy }
local console = {
    read = function() return nil end,
    write = function(fd, value)
        local list = fd == 2 and errors or output
        list[#list + 1] = value
        return true
    end,
}
for fd = 0, 2 do
    vhandles[tostring(fd)] = { fs = console, fd = fd, flag = fd == 0 and "r" or "w" }
end
vfsk.root = function() return {} end
vfs.realPath = function() return "/" end
vfs.resolve = function(path) return path end
vfs.attributes = function() return { mode = 755, uid = 0, gid = 0 } end
vfs.exists = function(path) return commands[path] ~= nil or files[path] ~= nil end
vfs.isDirectory = function() return false end
vfs.can = function() return true end
vfs.open = function(path)
    local data = files[path]
    if not data then return nil, "No such file" end
    local offset = 1
    return {
        read = function(_, size)
            if offset > #data then return nil end
            local chunk = data:sub(offset, offset + size - 1)
            offset = offset + #chunk
            return chunk
        end,
        close = function() end,
    }
end

local colors = setmetatable({}, { __index = function() return "" end })
util.createEnv = function()
    return setmetatable({
        io = io,
        os = { getenv = process.getEnviron, setenv = process.setEnviron, exit = process.exit },
        require = function(name)
            return assert(({ colors = colors, filesystem = vfs, process = process })[name], name)
        end,
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            io.write(table.concat(parts, "\t"), "\n")
        end,
    }, { __index = _G })
end

loadfile = function(path, mode, env)
    if path == "/usr/bin/blocked.lua" then return nil, "Test load failure" end
    local command = commands[path]
    if type(command) == "function" then return command end
    if type(command) == "string" then return load(command, "@" .. path, mode, env) end
    return nil, "No such file"
end
commands["/usr/bin/sh.lua"] = shellSource
commands["/usr/ubin/cat.lua"] = catSource
commands["/usr/bin/early.lua"] = function() return 7 end
commands["/usr/bin/input.lua"] = function() input = assert(io.read("*a")) end
commands["/usr/bin/blocked.lua"] = true
commands["/usr/bin/diagnose.lua"] = function()
    io.stderr:write("diagnostic")
    io.write("output")
end

local completed = false
commands["/test"] = function()
    local pipe = assert(io.popen("echo abc | cat | cat"))
    assert(pipe:read("*a") == "abc\n")
    assert(pipe:close())

    pipe = assert(io.popen("cat /data | cat | cat"))
    assert(pipe:read("*a") == files["/data"])
    assert(pipe:close())

    pipe = assert(io.popen("cat /data | early"))
    assert(pipe:read("*a") == "")
    local ok, reason, code = pipe:close()
    assert(ok == nil and reason == "exit" and code == 7)

    pipe = assert(io.popen("cat | input", "w"))
    assert(pipe:write(files["/data"]))
    assert(pipe:close())
    assert(input == files["/data"])

    pipe = assert(io.popen("diagnose | cat"))
    assert(pipe:read("*a") == "output")
    assert(pipe:close())
    assert(table.concat(errors, "\n"):find("diagnostic", 1, true))

    pipe = assert(io.popen("echo never-run | blocked | cat"))
    assert(pipe:read("*a") == "")
    local failed, kind, status = pipe:close()
    assert(failed == nil and kind == "exit" and status ~= 0)
    assert(table.concat(errors, "\n"):find("Test load failure", 1, true))

    for index in pairs(process.getCurrent().fd) do assert(index <= 3) end
    completed = true
end

assert(process.exec("/test") > 0)
for _ = 1, 500 do
    runProcessQueue({ n = 0 })
    if completed then break end
end
assert(completed, table.concat(errors, "\n"))
assert(#process.list() == 0)
]]

local env = setmetatable({
    fnv1a_hash = function() return 0 end,
    shellSource = readSource("root/usr/bin/sh.lua"),
    catSource = readSource("root/usr/ubin/cat.lua"),
}, { __index = _G })
local source = table.concat({
    setup, readSource("src/vfs.lua"), readSource("src/process.lua"),
    readSource("src/io.lua"), scheduler, harness,
}, "\n")
assert(load(source, "@pipeline_integration", "t", env))()
print("pipeline integration passed")
