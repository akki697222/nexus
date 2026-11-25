-- Tests for root/usr/sbin/firstboot.lua and the first boot check in
-- root/usr/sbin/login.lua, against mocked modules.
-- Run from the Nexus directory: lua tests/firstboot.lua
local function read(path)
    local f = assert(io.open(path, "rb"))
    local v = f:read("a")
    f:close()
    return v
end

local firstbootSource = read("root/usr/sbin/firstboot.lua")
local loginSource = read("root/usr/sbin/login.lua")

-- In-memory /etc and a user module working on it.
local function newSystem(passwd)
    local sys = {
        files = {
            ["/etc/passwd"] = passwd or "root:x:0:0:root:/root:/bin/sh.lua\n",
            ["/etc/sudoers"] = "root ALL=(root) ALL\n",
        },
        passwords = {},
        created = {},
    }
    local function users()
        local list = {}
        for line in sys.files["/etc/passwd"]:gmatch("[^\n]+") do
            local name, uid = line:match("^([^:]+):[^:]*:(%d+):")
            list[#list + 1] = { username = name, uid = tonumber(uid) }
        end
        return list
    end
    sys.user = {
        getUser = function(name)
            for _, u in ipairs(users()) do
                if u.username == name then return u end
            end
        end,
        hasPassword = function(name) return sys.passwords[name] ~= nil end,
        setPassword = function(name, password)
            if password == "" then return nil, "empty password" end
            sys.passwords[name] = password
            return true
        end,
        create = function(name, password, uid, gid)
            sys.created[#sys.created + 1] = { name = name, uid = uid, gid = gid }
            sys.files["/etc/passwd"] = sys.files["/etc/passwd"]
                .. string.format("%s:x:%d:%d::/home/%s:/bin/sh.lua\n", name, uid, gid, name)
            sys.passwords[name] = password
        end,
        checkPasswordCorrect = function(name, password)
            return name ~= nil and sys.passwords[name] == password
        end,
    }
    sys.open = function(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "r" then
            local data = sys.files[path]
            if not data then return nil, path .. ": No such file or directory" end
            local pos = 1
            -- like Nexus file handles: read("*l"/"l"/"*a"/"a"), no :lines()
            return {
                read = function(_, fmt)
                    fmt = fmt or "*l"
                    if pos > #data then return nil end
                    if fmt == "a" or fmt == "*a" then
                        local rest = data:sub(pos)
                        pos = #data + 1
                        return rest
                    end
                    assert(fmt == "l" or fmt == "*l", "unsupported read format " .. tostring(fmt))
                    local line, nextPos = data:match("([^\n]*)\n?()", pos)
                    pos = nextPos
                    return line
                end,
                close = function() end,
            }
        end
        local buffer = {}
        return {
            write = function(_, s) buffer[#buffer + 1] = s end,
            close = function()
                local text = table.concat(buffer)
                if mode:sub(1, 1) == "a" then
                    sys.files[path] = (sys.files[path] or "") .. text
                else
                    sys.files[path] = text
                end
            end,
        }
    end
    return sys
end

-- Runs firstboot with scripted answers; masked reads come from the same list.
local function firstboot(sys, answers)
    local i, out = 0, {}
    local env = setmetatable({
        require = function(name)
            assert(name == "user", "unexpected module " .. name)
            return sys.user
        end,
        io = {
            write = function(...) for _, s in ipairs({ ... }) do out[#out + 1] = s end end,
            read = function()
                i = i + 1
                return answers[i]
            end,
            open = sys.open,
        },
        print = function(...) out[#out + 1] = table.concat({ ... }, "\t") .. "\n" end,
        os = { getenv = function(name) if name == "HOSTNAME" then return "nexus" end end },
    }, { __index = _G })
    local code = assert(load(firstbootSource, "=firstboot", "t", env))()
    return code, table.concat(out), i
end

-- 1. Full setup: hostname, root password (a mismatch first), a user with sudo.
local sys = newSystem()
local code, out = firstboot(sys, {
    "box",
    "r00t", "typo", "r00t", "r00t",
    "alice", "pw", "pw", "",
})
assert(code == 0, out)
assert(sys.files["/etc/hostname"] == "box\n")
assert(sys.passwords.root == "r00t")
assert(out:find("do not match", 1, true))
assert(#sys.created == 1 and sys.created[1].name == "alice" and sys.created[1].uid == 100)
assert(sys.passwords.alice == "pw")
assert(sys.files["/etc/sudoers"]:find("\nalice ALL=(root) ALL\n", 1, true))

-- 2. Defaults: empty hostname keeps the current one, no user is created.
sys = newSystem()
code = firstboot(sys, { "", "pw", "pw", "" })
assert(code == 0)
assert(sys.files["/etc/hostname"] == "nexus\n")
assert(sys.passwords.root == "pw" and #sys.created == 0)

-- 3. Bad answers are asked again: hostname, empty password, user names; no sudo.
sys = newSystem("root:x:0:0:root:/root:/bin/sh.lua\nbob:x:100:100::/home/bob:/bin/sh.lua\n")
code, out = firstboot(sys, {
    "bad host!", "-x", "ok-host",
    "", "pw", "pw",
    "Bad", "root", "carol", "c", "c", "n",
})
assert(code == 0, out)
assert(sys.files["/etc/hostname"] == "ok-host\n")
assert(out:find("must not be empty", 1, true) and out:find("already exists", 1, true))
assert(sys.created[1].name == "carol" and sys.created[1].uid == 101, "uid 100 is taken by bob")
assert(not sys.files["/etc/sudoers"]:find("carol", 1, true))

-- 4. End of input aborts before anything is set.
sys = newSystem()
code, out = firstboot(sys, { "box", "pw" })
assert(code == 1 and out:find("aborted", 1, true))
assert(sys.passwords.root == nil)

-- login: runs firstboot while nobody can log in, then shows the prompt.
local function login(sys)
    local execs, prompts, environ = {}, 0, {}
    local env = setmetatable({
        require = function(name)
            if name == "user" then return sys.user end
            if name == "filesystem" then
                return { exists = function(path) return path == "/usr/sbin/firstboot.lua" end }
            end
            if name == "group" then return {} end
            if name == "process" then
                return {
                    listenSignal = function() end,
                    getCurrent = function() return { tty = -1 } end,
                    exec = function(path)
                        execs[#execs + 1] = path
                        -- what firstboot would do
                        sys.passwords.root = "pw"
                        sys.files["/etc/hostname"] = "box\n"
                        return 7
                    end,
                    wait = function() end,
                    setEnviron = function(k, v) environ[k] = v end,
                }
            end
            error("unexpected module " .. name)
        end,
        io = {
            write = function(s) if s == "Login: " then prompts = prompts + 1 end end,
            read = function()
                if prompts >= 2 then error("stop", 0) end
                return "nobody"
            end,
            open = sys.open,
            stderr = { write = function() end },
        },
        print = function() end,
    }, { __index = _G })
    local ok, err = pcall(assert(load(loginSource, "=login", "t", env)))
    assert(not ok and err == "stop", tostring(err))
    return execs, environ
end

local execs, environ = login(newSystem())
assert(#execs == 1 and execs[1] == "/usr/sbin/firstboot.lua", "firstboot runs once")
assert(environ.HOSTNAME == "box")

sys = newSystem()
sys.passwords.root = "set"
execs = login(sys)
assert(#execs == 0, "root has a password: no setup")

sys = newSystem("root:x:0:0:root:/root:/bin/sh.lua\ndebug:x:100:100::/home/debug:/bin/sh.lua\n")
sys.passwords.debug = "debug"
execs = login(sys)
assert(#execs == 0, "another account can log in: no setup")

print("firstboot tests passed")
