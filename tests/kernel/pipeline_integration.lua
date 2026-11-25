-- Run from the Nexus directory: lua tests/kernel/pipeline_integration.lua
local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    return text
end

local main = readSource("src/kernel/main.lua")
local scheduler = assert(main:match("    (runProcessQueue = function.-)\n    resumeKernelThreads"))
local setup = [[
local process, io
local event
]]
local harness = [[
-- vfs internals the stand-in vfs.open below needs
local allocFd, fdTable = vfsi.allocFd, vfsi.fdTable
local input, output, errors = "", {}, {}
local commands = {}
local files = {
    ["/data"] = ("abc\0\255xyz\n"):rep(4000),
    ["/lines"] = "first\nsecond\nlast",
    ["/script"] = "#!/bin/sh\r\n"
        .. "label=script\r\n"
        .. "echo \"$label:$#:$0\" > \"$1\"\r\n"
        .. "cat </lines | cat >>\"$1\"\r\n"
        .. "exit 7\r\n"
        .. "echo unreachable\r\n",
    ["/stdin-script"] = "echo \"$1:$#\"",
    ["/broken-script"] = "echo before\necho >\necho after\n",
}

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
config = { read_bytes = 8 }
local storage = {
    read = function(handle, size)
        local data = files[handle.path]
        if handle.offset > #data then return nil end
        local chunk = data:sub(handle.offset, handle.offset + size - 1)
        handle.offset = handle.offset + #chunk
        return chunk
    end,
    write = function(handle, text)
        files[handle.path] = files[handle.path] .. text
        return true
    end,
    close = function() end,
    seek = function(handle, whence, offset)
        local base = whence == "set" and 0 or handle.offset - 1
        handle.offset = base + offset + 1
        return handle.offset - 1
    end,
}
vfs.open = function(path, mode)
    mode = mode or "r"
    if mode:find("r") and not files[path] then return nil, "No such file" end
    if mode:find("w") or not files[path] then files[path] = "" end
    local d = { fs = storage, fd = { path = path, offset = 1 }, flag = mode, ref = 1, vnode = { type = "VREG" } }
    local fd = allocFd(fdTable(), d)
    return {
        fd = function() return fd end,
        read = function(_, size) return vfs.read(fd, size) end,
        close = function() return vfs.close(fd) end,
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
commands["/usr/bin/readline.lua"] = function() io.write(assert(io.read()), "\n") end
commands["/usr/bin/blocked.lua"] = true
commands["/usr/bin/diagnose.lua"] = function()
    io.stderr:write("diagnostic")
    io.write("output")
end

local completed = false
commands["/test"] = function()
    local inputFile = assert(vfs.open("/lines", "r"))
    local inputFd = inputFile:fd()
    local duplicate = assert(vfs.dup(inputFd, 8))
    assert(duplicate >= 8 and vfs.read(inputFd) == "first")
    assert(vfs.seek(duplicate, "cur", 0) == 6)
    assert(vfs.read(duplicate, "*L") == "second\n")
    assert(vfs.read(inputFd, "*a") == "last")
    assert(vfs.close(duplicate) and inputFile:close())

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

    pipe = assert(io.popen("cat </data | cat >/written"))
    assert(pipe:read("*a") == "" and pipe:close())
    assert(files["/written"] == files["/data"])

    pipe = assert(io.popen("echo more >>/written"))
    assert(pipe:read("*a") == "" and pipe:close())
    assert(files["/written"] == files["/data"] .. "more\n")

    pipe = assert(io.popen("readline </lines | cat"))
    assert(pipe:read("*a") == "first\n" and pipe:close())

    pipe = assert(io.popen("sh /script /script-out"))
    assert(pipe:read("*a") == "")
    local scriptOk, scriptReason, scriptStatus = pipe:close()
    assert(scriptOk == nil and scriptReason == "exit" and scriptStatus == 7)
    assert(files["/script-out"] == "script:1:/script\n" .. files["/lines"])

    pipe = assert(io.popen("cat /stdin-script | sh -s argument"))
    assert(pipe:read("*a") == "argument:1\n" and pipe:close())

    pipe = assert(io.popen("sh /broken-script"))
    assert(pipe:read("*a") == "before\n")
    local syntaxOk, syntaxReason, syntaxStatus = pipe:close()
    assert(syntaxOk == nil and syntaxReason == "exit" and syntaxStatus == 2)
    assert(table.concat(errors, "\n"):find("/broken-script:2: syntax error", 1, true))

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
    getRealTime = os.time, -- kernel global from base.lua
    shellSource = readSource("root/usr/bin/sh.lua"),
    catSource = readSource("root/usr/ubin/cat.lua"),
}, { __index = _G })
local source = table.concat({
    setup, dofile("tests/lib/kernel.lua").source("vfs"), dofile("tests/lib/kernel.lua").source("process"),
    readSource("src/api/io.lua"), scheduler, harness,
}, "\n")
assert(load(source, "@pipeline_integration", "t", env))()
print("pipeline integration passed")
