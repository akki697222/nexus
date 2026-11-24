-- Shell pipeline regressions. Run from nexus/: lua tests/sh_pipeline.lua
local source = assert(io.open("root/usr/bin/sh.lua", "r")):read("*a")

local function run(args, lines, spawn_failure, statuses, env_values, options)
    local records, closed, file_closed, opened, dup2s, output, errors, setenv, killed, waited = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
    local next_fd, next_pid = 10, 100
    local children = {}
    local directories = options and options.directories or {}
    local real_paths = options and options.real_paths or {}
    local function absolute(path)
        local parts = {}
        for part in path:gmatch("[^/]+") do
            if part == ".." then parts[#parts] = nil
            elseif part ~= "." then parts[#parts + 1] = part end
        end
        return "/" .. table.concat(parts, "/")
    end
    local function real_path(path)
        local full = absolute(path)
        return real_paths[full] or full
    end
    local fs = {
        concat = function(...) return table.concat({...}, "/") end,
        resolve = absolute,
        realPath = real_path,
        exists = function(path)
            local full = absolute(path)
            if directories[full] then return true end
            local parent, name = full:match("^(.*)/([^/]+)$")
            if parent == "" then parent = "/" end
            for _, entry in ipairs(directories[parent] or {}) do
                if entry == name then return true end
            end
            return path == "/usr/bin/sh.lua" or path == "/usr/ubin/cat" or path == "/usr/bin/cat"
                or path == "/usr/ubin/true" or path == "/usr/ubin/false" or path == "/usr/ubin/touch"
        end,
        can = function(path) return not options or absolute(path) ~= options.denied_directory end,
        isDirectory = function(path) return directories[real_path(path)] ~= nil end,
        list = function(path)
            local entries = directories[real_path(path)]
            if not entries then return nil, "Not a directory" end
            local i = 0
            return function()
                i = i + 1
                return entries[i]
            end
        end,
        pipe = function()
            local rfd, wfd = next_fd, next_fd + 1
            next_fd = next_fd + 2
            return rfd, wfd
        end,
        close = function(fd) closed[#closed + 1] = fd end,
        open = function(path, mode)
            local opened_record = { path = path, mode = mode }
            opened[#opened + 1] = opened_record
            if options and options.open_failure == path then return nil, "injected open failure" end
            local fd = options and options.open_fd or next_fd
            if fd == next_fd then next_fd = next_fd + 1 end
            opened_record.fd = fd
            return {
                fd = function() return fd end,
                close = function() file_closed[#file_closed + 1] = fd end
            }
        end,
        dup = function(fd, minimum)
            if options and options.dup_failure and options.dup_failure[fd] then return nil, "Bad file descriptor" end
            local copy = math.max(next_fd, minimum or 0)
            next_fd = copy + 1
            return copy
        end,
        dup2 = function(source, target)
            dup2s[#dup2s + 1] = { source = source, target = target }
            return true
        end
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
        killed = killed, waited = waited, opened = opened, file_closed = file_closed, dup2s = dup2s, code = code }
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

test("partial pipeline spawn failure closes redirection handles too", function()
    local result = run({ "-c", "echo a>out|cat" }, {}, { at = 2 })
    assert(result.code == 1 and #result.records == 1)
    assert(#result.file_closed == 1)
    assert(#result.killed == 1 and #result.waited == 1)
end)

test("-c returns last stage status", function()
    local result = run({ "-c", "true|false" })
    assert(result.code == 0, "stub defaults last process status to zero")
    local result_nonzero = run({ "-c", "true|false" }, {}, nil, { [101] = 7 })
    assert(result_nonzero.code == 7)
end)

test("missing pipeline segments return syntax status before spawning", function()
    for _, line in ipairs({ "|cat", "cat|", "cat| |cat", "cat|;" }) do
        local result = run({ "-c", line })
        assert(result.code == 2 and #result.records == 0)
    end
end)

test("environment expansion cannot create a pipeline operator", function()
    local result = run({ "-c", "echo $VALUE" }, {}, nil, nil, { VALUE = "left|right" })
    assert(result.code == 0 and #result.records == 0)
end)

test("redirections split adjacent operators and map child descriptors", function()
    local result = run({ "-c", "cat<input.txt|cat>out.txt" })
    assert(result.code == 0 and #result.records == 2)
    assert(result.opened[1].path == "input.txt" and result.opened[1].mode == "r")
    assert(result.opened[2].path == "out.txt" and result.opened[2].mode == "w")
    assert(result.records[1].stdio[0] >= 10)
    assert(result.records[2].stdio[1] >= 10)
    assert(#result.file_closed == 2)
end)

test("append and multiple redirects are opened left to right with last mapping winning", function()
    local result = run({ "-c", "cat >first >second <input" })
    assert(result.code == 0 and #result.records == 1)
    assert(result.opened[1].mode == "w" and result.opened[2].mode == "w" and result.opened[3].mode == "r")
    assert(result.records[1].stdio[1] == result.opened[2].fd)
    assert(result.records[1].stdio[0] >= 10 and #result.file_closed == 3)
end)

test("append redirection uses append mode", function()
    local result = run({ "-c", "cat >>log" })
    assert(result.code == 0 and result.opened[1].mode == "a")
end)

test("quoted and escaped redirect operators remain literal arguments", function()
    local result = run({ "-c", "cat 'a>b' c\\>d \"e>>f\"" })
    assert(result.code == 0 and #result.records == 1)
    assert(#result.opened == 0)
    assert(result.records[1].args[1] == "a>b")
    assert(result.records[1].args[2] == "c>d")
    assert(result.records[1].args[3] == "e>>f")
end)

test("expansion cannot create a redirection operator", function()
    local result = run({ "-c", "cat $VALUE" }, {}, nil, nil, { VALUE = "<input" })
    assert(result.code == 0 and #result.opened == 0 and #result.records == 1)
    assert(result.records[1].args[1] == "<input")
end)

test("missing targets and commands fail before opening any file", function()
    for _, line in ipairs({ "cat >", "cat >>", "cat <", "cat > >out", " >file", "cat|>out" }) do
        local result = run({ "-c", line })
        assert(result.code == 2 and #result.opened == 0 and #result.records == 0, line)
    end
end)

test("open failure closes prior files and starts no process", function()
    local result = run({ "-c", "cat >first >second" }, {}, nil, nil, nil, { open_failure = "second" })
    assert(result.code == 1 and #result.records == 0)
    assert(#result.file_closed == 1)
end)

test("redirected standalone builtin restores parent descriptors", function()
    local result = run({ "-c", "echo hello >out" })
    assert(result.code == 0 and #result.records == 0)
    assert(#result.dup2s == 2)
    assert(result.dup2s[1].target == 1 and result.dup2s[2].target == 1)
    assert(#result.file_closed == 1)
end)

test("redirected descriptor below three is duplicated and closed", function()
    local result = run({ "-c", "cat <input" }, {}, nil, nil, nil, { open_fd = 0 })
    assert(result.code == 0 and #result.records == 1)
    assert(result.records[1].stdio[0] >= 10)
    local found_safe_close = false
    for _, fd in ipairs(result.closed) do if fd == result.records[1].stdio[0] then found_safe_close = true end end
    assert(found_safe_close)
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

local glob_fs = { directories = {
    ["/"] = { "z.log", "dirB", ".hidden.log", "dirA", "dirC", "left|right.log", "a.log", "あ.log" },
    ["/dirA"] = { "x.luac", "x.lua" },
    ["/dirB"] = { "x.lua" },
    ["/dirC"] = {},
} }

test("external commands receive sorted absolute and relative wildcard matches", function()
    local result = run({ "-c", "touch /*.log dir*/x.lua" }, {}, nil, nil, nil, glob_fs)
    assert(result.code == 0 and #result.records == 1)
    assert(table.concat(result.records[1].args, ",") ==
        "/a.log,/left|right.log,/z.log,/あ.log,dirA/x.lua,dirB/x.lua")
end)

test("glob classes, question marks, and explicit hidden names match", function()
    local result = run({ "-c", "echo ?.log .*.log dir[!B]/x.lu[ab] [a-z].log" }, {}, nil, nil, nil, glob_fs)
    assert(table.concat(result.output) == "a.log z.log あ.log .hidden.log dirA/x.lua a.log z.log\n")
end)

test("glob trailing slash matches directories only", function()
    local result = run({ "-c", "echo */" }, {}, nil, nil, nil, glob_fs)
    assert(table.concat(result.output) == "dirA/ dirB/ dirC/\n")
end)

test("quoting inside a bracket class protects negation and range markers", function()
    local result = run({ "-c", [[echo ['!'].log [a'-'z].log]] }, {}, nil, nil, nil,
        { directories = { ["/"] = { "!.log", "-.log", "a.log", "b.log", "z.log" } } })
    assert(table.concat(result.output) == "!.log -.log a.log z.log\n")
end)

test("quotes and escapes protect wildcards and unmatched patterns remain unchanged", function()
    local result = run({ "-c", [[echo '*.log' "*.log" \*.log "dir"*'/x.lua' absent* $MATCH "$MATCH"]] },
        {}, nil, nil, { MATCH = "a.*" }, glob_fs)
    assert(table.concat(result.output) == "*.log *.log *.log dirA/x.lua dirB/x.lua absent* a.log a.*\n")
    local assignment = run({ "-c", "MATCH=*.log" }, {}, nil, nil, nil, glob_fs)
    assert(assignment.setenv.MATCH == "*.log")
end)

test("glob results in pipelines remain literal argv and respect directory access", function()
    local result = run({ "-c", "echo left* dirB/* | cat" }, {}, nil, nil, nil,
        { directories = glob_fs.directories, denied_directory = "/dirB" })
    assert(result.code == 0 and #result.records == 2)
    assert(table.concat(result.records[1].args, ",") == "--builtin,echo,left|right.log,dirB/*")
end)

test("glob directory aliases honor the target's permissions", function()
    local result = run({ "-c", "echo alias/*" }, {}, nil, nil, nil,
        { directories = glob_fs.directories, real_paths = { ["/alias"] = "/dirB" }, denied_directory = "/dirB" })
    assert(table.concat(result.output) == "alias/*\n")
end)

test("tilde and script arguments expand before pathname matching", function()
    local result = run({ "-c", [[echo ~/x.* "$1" $1]], "test", "dirB/*" },
        {}, nil, nil, { HOME = "/dirA" }, glob_fs)
    assert(table.concat(result.output) == "/dirA/x.lua /dirA/x.luac dirB/* dirB/x.lua\n")
end)

test("redirection globbing requires an unambiguous path before opening files", function()
    local result = run({ "-c", "cat <dirA/*.lua" }, {}, nil, nil, nil, glob_fs)
    assert(result.code == 0 and #result.opened == 1 and result.opened[1].path == "dirA/x.lua")
    result = run({ "-c", "cat >first <dir*/x.lua" }, {}, nil, nil, nil, glob_fs)
    assert(result.code ~= 0 and #result.opened == 0 and #result.records == 0)
    assert(table.concat(result.errors):find("ambiguous", 1, true))
end)

print("all shell pipeline tests passed")
