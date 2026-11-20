-- Shell pipeline regressions. Run from nexus/: lua tests/sh_pipeline.lua
local source = assert(io.open("root/usr/bin/sh.lua", "r")):read("*a")

local function run(args, lines, spawn_failure, statuses, env_values)
    local records, closed, output, errors, setenv, killed, waited = {}, {}, {}, {}, {}, {}, {}
    local next_fd, next_pid = 10, 100
    local children = {}
    local fs = {
        concat = function(...) return table.concat({...}, "/") end,
        exists = function(path)
            return path == "/usr/bin/sh.lua" or path == "/usr/ubin/cat" or path == "/usr/bin/cat"
                or path == "/usr/ubin/true" or path == "/usr/ubin/false"
        end,
        pipe = function()
            local rfd, wfd = next_fd, next_fd + 1
            next_fd = next_fd + 2
            return rfd, wfd
        end,
        close = function(fd) closed[#closed + 1] = fd end
    }
    local proc = {
        cwd = function(path) if path then return path end return "/" end,
        spawn = function(path, argv, stdio)
            if spawn_failure and #records + 1 == spawn_failure.at then return -1, "injected failure" end
            local pid = next_pid
            next_pid = next_pid + 1
            local instance = pid + 1000
            records[#records + 1] = { path = path, args = argv, stdio = stdio, pid = pid, instance = instance }
            children[pid] = { instance = instance }
            return pid, nil, instance
        end,
        get = function(pid) return children[pid] end,
        kill = function(pid) killed[#killed + 1] = pid; children[pid] = nil; return true end,
        wait = function(pid, instance)
            waited[#waited + 1] = { pid = pid, instance = instance }
            if children[pid] and children[pid].instance == instance then
                children[pid] = nil
            end
            local status = statuses and statuses[pid]
            if status == nil then status = 0 end
            return nil, status
        end,
        exec = function(path, argv)
            local pid = next_pid
            next_pid = next_pid + 1
            local instance = pid + 1000
            records[#records + 1] = { path = path, args = argv, stdio = {}, pid = pid, instance = instance }
            children[pid] = { instance = instance }
            return pid
        end
    }
    local env = setmetatable({}, { __index = _G })
    env.require = function(name)
        if name == "colors" then return { green = "", bright_blue = "", reset = "", bold = "", red = "" } end
        if name == "filesystem" then return fs end
        if name == "process" then return proc end
        error("unexpected require: " .. name)
    end
    env.os = {
        getenv = function(key) return (env_values or {})[key] end,
        setenv = function(key, value) setenv[key] = value end,
        exit = function(code) error({ shell_exit = code }, 0) end
    }
    env.io = {
        write = function(value) output[#output + 1] = tostring(value) end,
        stderr = { write = function(_, value) errors[#errors + 1] = tostring(value) end },
        read = function()
            local line = table.remove(lines, 1)
            if line then return line end
            return nil
        end
    }
    env.print = function(value) output[#output + 1] = tostring(value) .. "\n" end
    local chunk = assert(load(source, "sh.lua", "t", env))
    local thread = coroutine.create(function() return chunk(table.unpack(args or {})) end)
    local ok, result = coroutine.resume(thread)
    if ok and coroutine.status(thread) == "suspended" then ok, result = coroutine.resume(thread) end
    local code
    if not ok and type(result) == "table" then
        if result.shell_exit ~= nil then code = result.shell_exit
        elseif result.shell_input_done then code = nil
        else error(result) end
    elseif not ok then error(result) end
    return { records = records, closed = closed, output = output, errors = errors, setenv = setenv,
        killed = killed, waited = waited, code = code }
end

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then io.stderr:write("FAIL ", name, "\n", err, "\n"); os.exit(1) end
    print("ok - " .. name)
end

test("three stage builtin and external pipeline maps adjacent pipes", function()
    local result = run({ "-c", "echo abc|cat | cat" })
    assert(result.code == 0)
    assert(#result.records == 3)
    assert(result.records[1].path == "/usr/bin/sh.lua")
    assert(result.records[1].args[1] == "--builtin" and result.records[1].args[2] == "echo")
    assert(result.records[2].path == "/usr/ubin/cat")
    assert(result.records[1].stdio[1] == 11)
    assert(result.records[2].stdio[0] == 10 and result.records[2].stdio[1] == 13)
    assert(result.records[3].stdio[0] == 12)
    assert(#result.closed == 4)
end)

test("quoted and escaped pipes remain arguments", function()
    local result = run({ "-c", "cat 'a|b' \"c|d\" e\\|f" })
    assert(result.code == 0)
    assert(#result.records == 1, "single external commands retain exec compatibility")
    assert(result.records[1].args[1] == "a|b")
    assert(result.records[1].args[2] == "c|d")
    assert(result.records[1].args[3] == "e|f")
end)

test("quoted pipe in a pipeline stays inside its argument", function()
    local result = run({ "-c", "echo 'left|right'|cat" })
    assert(result.code == 0 and #result.records == 2)
    assert(result.records[1].args[3] == "left|right")
end)

test("spawn failure closes pipes and kills and reaps started children", function()
    local result = run({ "-c", "echo a|cat|cat" }, {}, { at = 2 })
    assert(result.code == 1)
    assert(#result.closed == 4)
    assert(#result.records == 1)
    assert(table.concat(result.errors):find("injected failure", 1, true))
    assert(#result.killed == 1 and result.killed[1] == result.records[1].pid)
    assert(#result.waited == 1 and result.waited[1].instance == result.records[1].instance)
end)

test("-c returns last stage status", function()
    local result = run({ "-c", "true|false" })
    assert(result.code == 0, "stub defaults last process status to zero")
    local result_nonzero = run({ "-c", "true|false" }, {}, nil, { [101] = 7 })
    assert(result_nonzero.code == 7)
end)

test("missing pipeline segments return syntax status before spawning", function()
    for _, line in ipairs({ "|cat", "cat|", "cat||cat" }) do
        local result = run({ "-c", line })
        assert(result.code == 2 and #result.records == 0)
    end
end)

test("environment expansion cannot create a pipeline operator", function()
    local result = run({ "-c", "echo $VALUE" }, {}, nil, nil, { VALUE = "left|right" })
    assert(result.code == 0 and #result.records == 0)
end)

test("single builtin runs in the parent shell", function()
    local result = run({}, { "export KEY=value" })
    assert(result.setenv.KEY == "value")
    assert(#result.records == 0)
end)

test("builtin in a pipeline runs in a child without changing the parent environment", function()
    local result = run({ "-c", "export KEY=secret|cat" })
    assert(result.code == 0 and #result.records == 2)
    assert(result.records[1].path == "/usr/bin/sh.lua")
    assert(result.records[1].args[1] == "--builtin" and result.records[1].args[2] == "export")
    assert(result.records[1].args[3] == "KEY=secret")
    assert(result.setenv.KEY == nil)
end)

print("all shell pipeline tests passed")
