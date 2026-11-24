-- sudo policy/authentication regression tests. Run with: lua tests/sudo.lua
local function read(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local sudo_source = read("root/usr/bin/sudo.lua")
local argparse_source = read("root/usr/lib/libargparse.lua")
local main_source = read("src/main.lua")
local unpack_args = table.unpack or unpack

assert(main_source:find('vfs.chown("/usr/bin/sudo.lua", 0, 0)', 1, true)
    and main_source:find('vfs.chmod("/usr/bin/sudo.lua", 04755)', 1, true)
    and main_source:find('vfs.chmod("/etc/sudoers", 0440)', 1, true),
    "boot must install sudo as root-owned setuid and lock down sudoers")
assert(main_source:find("return tty.read(...) ", 1, true) or main_source:find("return tty.read(...)", 1, true),
    "stdin must forward the mask argument to tty.read")

local function run(argv, options)
    options = options or {}
    local events, stdout, stderr = {}, {}, {}
    local credentials = { uid = options.uid or 100, euid = options.euid == nil and 0 or options.euid,
        gid = options.uid == 0 and 0 or 100, egid = 0 }
    local environment = { USER = "attacker", HOME = "/home/debug", PATH = ".:/tmp/bin",
        PWD = "/work", EXTRA = "secret" }
    local files = {
        ["/etc/passwd"] = "root:x:0:0:root:/root:/bin/sh.lua\ndebug:x:100:100:Debug:/home/debug:/bin/sh.lua\n",
        ["/etc/group"] = "root:0:root\nsudo:27:debug\n",
        ["/etc/sudoers"] = options.sudoers or "root ALL=(root) ALL\ndebug ALL=(root) ALL\n",
        ["/usr/lib/libargparse.lua"] = argparse_source,
    }
    local modes = options.modes or {}
    local process = {
        getCurrent = function() return credentials end,
        setuser = function(account)
            events[#events + 1] = { "setuser", account.uid }
            credentials.uid, credentials.euid, credentials.suid = account.uid, account.uid, account.uid
            credentials.gid, credentials.egid, credentials.sgid = account.gid, account.gid, account.gid
            return true
        end,
        cwd = function() return "/work" end,
        getEnviron = function() return environment end,
        setEnviron = function(key, value) environment[key] = value end,
        exec = function(path, args)
            events[#events + 1] = { "exec", path, args, credentials.uid, credentials.euid, environment }
            if options.exec_error then return -1, options.exec_error end
            return 42
        end,
        wait = function(pid)
            events[#events + 1] = { "wait", pid }
            return options.wait_error
        end,
    }
    local filesystem = {
        attributes = function(path)
            if not files[path] then return nil end
            return { type = "VREG", uid = options.owners and options.owners[path] or 0, mode = modes[path] or 644 }
        end,
        open = function(path)
            local content = files[path]
            if not content then return nil, "missing" end
            return { readAll = function() return content end, close = function() end }
        end,
        exists = function(path)
            if path == "/usr/bin/echo.lua" or path == "/usr/bin/reboot.lua" then return true end
            return false
        end,
        isDirectory = function() return false end,
    }
    local responses, response_index = options.passwords or { "correct" }, 0
    local env = setmetatable({
        require = function(name)
            if name == "process" then return process end
            if name == "filesystem" then return filesystem end
            if name == "user" then
                return { checkPasswordCorrect = function(username, password)
                    events[#events + 1] = { "password", username, password }
                    return username == "debug" and password == "correct"
                end }
            end
            error("unexpected require: " .. name)
        end,
        load = function(source, name, mode, load_env)
            return load(source, name, mode, load_env)
        end,
        io = {
            write = function(...) for i = 1, select("#", ...) do stdout[#stdout + 1] = tostring(select(i, ...)) end end,
            read = function(...)
                local formats = { ... }
                events[#events + 1] = { "read", formats[1], formats[2] }
                response_index = response_index + 1
                return responses[response_index]
            end,
            stderr = { write = function(_, ...)
                for i = 1, select("#", ...) do stderr[#stderr + 1] = tostring(select(i, ...)) end
            end },
        },
        os = { exit = function(code) error({ exit = code }) end },
    }, { __index = _G })
    local chunk = assert(load(sudo_source, "sudo.lua", "t", env))
    local ok, err = pcall(function() chunk(unpack_args(argv)) end)
    local exit_code
    if not ok and type(err) == "table" and err.exit then exit_code = err.exit
    elseif not ok then error(err) end
    return { events = events, stdout = table.concat(stdout), stderr = table.concat(stderr),
        exit_code = exit_code, credentials = credentials, environment = environment }
end

local result = run({ "echo", "--help", "--flag", "two words" })
local exec_event
for _, event in ipairs(result.events) do if event[1] == "exec" then exec_event = event end end
assert(exec_event, "allowed user should execute a command")
assert(exec_event[2] == "/usr/bin/echo.lua")
assert(table.concat(exec_event[3], "\0") == "--help\0--flag\0two words", "command flags and args must pass through")
assert(exec_event[4] == 0 and exec_event[5] == 0, "command must execute with root credentials")
assert(result.environment.USER == "root" and result.environment.HOME == "/root")
assert(result.environment.PATH == "/usr/bin:/usr/sbin:/usr/ubin:/bin:/sbin:/ubin")
assert(result.environment.EXTRA == nil and result.environment.SUDO_USER == "debug")
local masked_read = false
for _, event in ipairs(result.events) do
    if event[1] == "read" then masked_read = event[2] == "*l" and event[3] == "*" end
end
assert(masked_read, "password input must request masked line input")

result = run({ "--", "echo", "--help" })
assert(result.events[#result.events - 1][1] == "exec", "explicit -- should allow a command and its flags")

result = run({ "echo" }, { uid = 0 })
for _, event in ipairs(result.events) do assert(event[1] ~= "password", "root must not be prompted") end

result = run({ "echo" }, { sudoers = "root ALL=(root) ALL\n%sudo ALL=(root) ALL\n" })
assert(result.exit_code == nil, "a disk-backed supplementary group should authorize the caller")
result = run({ "echo" }, { sudoers = "%sudo ALL=(root) ALL\n" })
assert(result.exit_code == nil, "group membership should be read from /etc/group")

result = run({ "echo" }, { sudoers = "root ALL=(root) ALL\n" })
assert(result.exit_code == 1 and not result.stderr:find("authentication failed", 1, true))
for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "denied users must not execute") end

result = run({ "echo" }, { passwords = { "wrong", "wrong", "wrong" } })
assert(result.exit_code == 1 and result.stderr:find("authentication failed", 1, true))
for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "bad passwords must not execute") end

result = run({ "echo" }, { passwords = {} })
assert(result.exit_code == 1 and result.stderr:find("authentication failed", 1, true))
for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "EOF at password prompt must not execute") end

result = run({ "echo" }, { euid = 100 })
assert(result.exit_code == 1 and result.stderr:find("set-user-ID privilege is unavailable", 1, true))
for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "missing setuid privilege must not execute") end

result = run({ "echo" }, { owners = { ["/etc/sudoers"] = 100 } })
assert(result.exit_code == 1 and result.stderr:find("unsafe ownership/permissions", 1, true))
for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "non-root-owned policy must not execute") end

for _, mode in ipairs({ 660, 664, 646, 666 }) do
    result = run({ "echo" }, { modes = { ["/etc/sudoers"] = mode } })
    assert(result.exit_code == 1 and result.stderr:find("unsafe ownership/permissions", 1, true),
        "writable sudoers mode must be rejected: " .. mode)
    for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "unsafe policy must not execute") end
end
for _, mode in ipairs({ 644, 640, 440 }) do
    result = run({ "echo" }, { modes = { ["/etc/sudoers"] = mode } })
    assert(result.exit_code == nil, "safe policy mode should be accepted: " .. mode)
end

for _, path in ipairs({ "/etc/passwd", "/etc/group" }) do
    result = run({ "echo" }, { modes = { [path] = 664 } })
    assert(result.exit_code == 1 and result.stderr:find("unsafe ownership/permissions", 1, true),
        "writable identity database must be rejected: " .. path)
    for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "unsafe identity data must not execute") end
end

result = run({ "echo" }, { sudoers = "debug ALL=(root) /usr/bin/echo.lua\n" })
assert(result.exit_code == 1 and result.stderr:find("unsupported or invalid policy rule", 1, true))

result = run({ "--not-a-sudo-option", "echo" })
assert(result.exit_code ~= nil and not result.stderr:find("command not found", 1, true))
for _, event in ipairs(result.events) do assert(event[1] ~= "exec", "unknown sudo options must not execute") end

result = run({ "--help" })
assert(result.exit_code == nil and result.stdout:find("Usage:", 1, true))

result = run({ "echo" }, { exec_error = "Permission denied" })
assert(result.exit_code == 126 and result.stderr:find("cannot execute echo", 1, true))
result = run({ "echo" }, { wait_error = "child failed" })
assert(result.exit_code == 1 and result.stderr:find("process error: child failed", 1, true))

print("sudo policy/authentication tests passed")
