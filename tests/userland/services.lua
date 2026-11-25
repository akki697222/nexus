-- klog, system.log, syslogd, dmesg, logger and synapsed.
-- Run from the Nexus directory: lua tests/userland/services.lua
local hostLoadfile = loadfile
local function read(path) local f = assert(io.open(path)); local s = f:read("a"); f:close(); return s end

-- kernel log -----------------------------------------------------------------
local uptime, realTime = 1.5, 1800000000
computer = { uptime = function() return uptime end }
getRealTime = function() return realTime end
local current = nil -- process.getCurrent()
process = { current = -1, getCurrent = function() return current end }
config = {}
assert(hostLoadfile("src/kernel/klog.lua"))()
local sysSource = read("src/kernel/system.lua")
assert(load(sysSource, "=system.lua"))()

klog.record("info", "kernel", "boot")
local entries, newest, oldest = klog.read(0)
assert(#entries == 1 and newest == 1 and oldest == 1 and entries[1].msg == "boot")
entries[1].msg = "tampered"
assert(klog.read(0)[1].msg == "boot", "readers get copies")

-- processes log under their own name, pid and uid; they cannot be "kernel"
current = { pid = 12, uid = 100, path = "/usr/bin/backup.lua" }
assert(system.log("nightly run"))
assert(system.log("spoof", "kernel"))
assert(system.log("tagged", "my.tag!", "err"))
assert(not system.log("x", nil, "loud"), "unknown level rejected")
current = nil
entries = klog.read(1)
assert(entries[1].tag == "backup" and entries[1].pid == 12 and entries[1].uid == 100 and entries[1].level == "notice")
assert(entries[2].tag == "kernel?", "a process cannot pose as the kernel")
assert(entries[3].tag == "my.tag" and entries[3].level == "err")

-- bounded by bytes and entries; readers learn about dropped entries
for i = 1, 600 do klog.record("info", "kernel", ("m%03d "):format(i) .. ("x"):rep(100)) end
entries, newest, oldest = klog.read(0)
assert(#entries <= klog.MAX_ENTRIES, #entries)
local total = 0
for _, e in ipairs(entries) do total = total + #e.msg + #e.tag + 32 end
assert(total <= klog.MAX_BYTES, total)
assert(entries[#entries].msg:find("^m600") and oldest > 1)
assert(#klog.read(newest) == 0)
klog.record("info", "kernel", ("y"):rep(1000))
assert(#klog.read(newest)[1].msg == klog.MAX_MESSAGE, "long messages are cut")

-- in-memory filesystem shared by the daemons --------------------------------
local function newFs()
    local files, dirs = {}, { ["/"] = true }
    local fs = { files = files, dirs = dirs, mounted = {}, modes = {} }
    function fs.path(p) return p:match("^(.*)/[^/]*$") ~= "" and p:match("^(.*)/[^/]*$") or "/" end
    function fs.exists(p) return files[p] ~= nil or dirs[p] == true end
    function fs.isDirectory(p) return dirs[p] == true end
    function fs.makeDirectory(p) dirs[p] = true return true end
    function fs.size(p) return #(files[p] or "") end
    function fs.remove(p) files[p] = nil return true end
    function fs.rename(a, b) files[b], files[a] = files[a], nil return true end
    function fs.chmod(p, m) fs.modes[p] = m end
    function fs.open(p, mode)
        if mode == "r" then
            local data = files[p]
            if not data then return nil, "not found" end
            return { read = function() local d = data; data = nil; return d end, close = function() end }
        end
        if fs.failWrites then return nil, "disk full" end
        if mode == "w" or not files[p] then files[p] = "" end
        return { write = function(_, s) files[p] = files[p] .. s end, close = function() end }
    end
    return fs
end

local function daemon(path, env)
    local chunk = assert(load(read(path), "=" .. path, "t", setmetatable(env, { __index = _G })))
    local co = coroutine.create(chunk)
    local d = {}
    function d.step(...)
        local ok, err = coroutine.resume(co, ...)
        assert(ok, err)
        return coroutine.status(co)
    end
    return d
end

-- syslogd ------------------------------------------------------------------------
do
    local fs = newFs()
    local sys = { readLog = function(since) return klog.read(since) end,
                  log = function(m, t, l) klog.record(l or "notice", t or "syslogd", m) end }
    local d = daemon("root/usr/sbin/syslogd.lua", {
        require = function(n)
            if n == "filesystem" then return fs end
            if n == "system" then return sys end
            if n == "event" then return { pullFiltered = function() coroutine.yield() end } end
            error(n)
        end,
        os = setmetatable({ getenv = function(k) return k == "HOSTNAME" and "box" or nil end }, { __index = os }),
    })
    -- a fresh ring
    assert(load(read("src/kernel/klog.lua")))()
    klog.record("info", "kernel", "VFS: mounted")
    current = { pid = 7, uid = 0, path = "/usr/sbin/synapsed.lua" }
    system.log("mounted abc on /mnt/x")
    system.log("disk failing", nil, "err")
    current = nil
    assert(d.step() == "suspended")
    local log = fs.files["/var/log/messages"]
    assert(fs.dirs["/var/log"] and fs.modes["/var/log/messages"] == 640)
    local date = os.date("%b %d %H:%M:%S", realTime)
    assert(log == date .. " box kernel: VFS: mounted\n"
        .. date .. " box synapsed[7]: mounted abc on /mnt/x\n"
        .. date .. " box synapsed[7]: <err> disk failing\n", log)

    -- nothing new: nothing written
    d.step()
    assert(fs.files["/var/log/messages"] == log)

    -- dropped entries are reported, and the file rotates past 32 KiB
    for i = 1, 400 do klog.record("info", "kernel", ("line %d "):format(i) .. ("z"):rep(90)) end
    d.step()
    assert(fs.files["/var/log/messages"]:find("messages lost") or fs.files["/var/log/messages.1"]:find("messages lost"))
    for _ = 1, 6 do
        for i = 1, 100 do klog.record("info", "kernel", ("more %d "):format(i) .. ("q"):rep(90)) end
        d.step()
    end
    assert(fs.files["/var/log/messages.1"] and fs.files["/var/log/messages.2"], "rotated")
    assert(#fs.files["/var/log/messages"] < 32 * 1024 + 16 * 1024)
end

-- dmesg / logger -----------------------------------------------------------------
do
    assert(load(read("src/kernel/klog.lua")))()
    uptime = 4.4
    klog.record("info", "kernel", "Nexus version test")
    current = { pid = 3, uid = 0, path = "/usr/sbin/syslogd.lua" }
    system.log("started")
    system.log("bad thing", nil, "err")
    current = nil
    local out = {}
    local function run(path, ...)
        out = {}
        local env = setmetatable({
            require = function(n) assert(n == "system"); return system end,
            io = { write = function(...) out[#out + 1] = table.concat({ ... }) end,
                   stderr = { write = function(_, s) out[#out + 1] = "ERR:" .. s end },
                   read = function() return nil end },
            print = function(s) out[#out + 1] = s .. "\n" end,
        }, { __index = _G })
        return assert(load(read(path), "=" .. path, "t", env))(...)
    end
    run("root/usr/ubin/dmesg.lua")
    assert(table.concat(out) == "[    4.40] Nexus version test\n[    4.40] syslogd[3]: started\n[    4.40] syslogd[3]: bad thing\n",
        table.concat(out))
    run("root/usr/ubin/dmesg.lua", "-k")
    assert(table.concat(out) == "[    4.40] Nexus version test\n")
    run("root/usr/ubin/dmesg.lua", "-l", "err")
    assert(table.concat(out) == "[    4.40] syslogd[3]: bad thing\n")
    current = { pid = 9, uid = 100, path = "/usr/ubin/logger.lua" }
    run("root/usr/ubin/logger.lua", "-t", "backup", "-p", "user.warning", "disk", "almost", "full")
    current = nil
    local e = klog.read(0)
    e = e[#e]
    assert(e.tag == "backup" and e.level == "warning" and e.msg == "disk almost full" and e.pid == 9)
end

-- synapsed ------------------------------------------------------------------------
do
    assert(load(read("src/kernel/klog.lua")))()
    local fs = newFs()
    local labels = { aaa111 = "OpenOS", bbb222 = nil, ccc333 = "backup", ddd444 = "OpenOS", eee555 = "junk",
                     boot00 = "Nexus", tmp000 = "tmpfs" }
    local present = { boot00 = "filesystem", tmp000 = "filesystem", aaa111 = "filesystem",
                      bbb222 = "filesystem", ccc333 = "filesystem", gpu000 = "gpu" }
    local mounts = { { { address = "boot00" }, "/" }, { { address = "tmp000" }, "/tmp" } }
    local busyPaths = {}
    function fs.mounts()
        local i = 0
        return function() i = i + 1; if mounts[i] then return mounts[i][1], mounts[i][2] end end
    end
    function fs.mount(addr, path)
        if not fs.isDirectory(fs.path(path)) then return false, "Mount parent is not an existing directory" end
        mounts[#mounts + 1] = { { address = addr }, path }
        return true
    end
    function fs.umount(path)
        if busyPaths[path] then return false, "Filesystem is busy" end
        for i, m in ipairs(mounts) do if m[2] == path then table.remove(mounts, i); return true end end
        return false, "No such mount"
    end
    local function where(addr) for _, m in ipairs(mounts) do if m[1].address == addr then return m[2] end end end
    fs.files["/etc/synapse.rules"] = "# rules\nlabel=backup mount=/backup\naddress=eee nomount\ntype=gpu run=/usr/bin/gpu-hook.lua\nlabel=x bogus=1\ndriver=printer3d run=/usr/bin/printer-hook.lua\n"
    local ran = {}
    local d = daemon("root/usr/sbin/synapsed.lua", {
        require = function(n)
            if n == "filesystem" then return fs end
            if n == "system" then return system end
            if n == "event" then return { pull = function(timeout) return coroutine.yield(timeout) end } end
            if n == "process" then
                return { exec = function(p, args) ran[#ran + 1] = p .. " " .. table.concat(args, " "); return 50 end }
            end
            if n == "device" then
                return {
                    list = function()
                        local out = {}
                        for a, t in pairs(present) do
                            out[a] = { component = t, label = labels[a], type = "x" }
                        end
                        return out
                    end,
                    get = function(a)
                        if present[a] then return { component = present[a], label = labels[a] } end
                    end,
                    bindings = function()
                        return { { address = "prn001", type = "printer3d", driver = "printer3d", node = "printer0", state = "bound" },
                                 { address = "bad001", type = "chat_box", driver = "chatbox", state = "failed" } }
                    end,
                }
            end
            error(n)
        end,
    })
    local function event(...) return d.step(...) end

    -- coldplug
    assert(d.step() == "suspended")
    assert(where("aaa111") == "/mnt/OpenOS", tostring(where("aaa111")))
    assert(where("bbb222") == "/mnt/bbb", "unlabeled: address prefix")
    assert(where("ccc333") == "/backup", "rule mount path")
    assert(where("boot00") == "/" and where("tmp000") == "/tmp", "existing mounts untouched")
    assert(ran[1] == "/usr/bin/gpu-hook.lua add gpu000 gpu", tostring(ran[1]))
    assert(ran[2] == "/usr/bin/printer-hook.lua add prn001 printer3d printer3d printer0", tostring(ran[2]))
    assert(#ran == 2, "driver rules skip component events and failed bindings")
    local logText = {}
    for _, e in ipairs(klog.read(0)) do logText[#logText + 1] = e.tag .. ": " .. e.msg end
    logText = table.concat(logText, "\n")
    assert(logText:find("synapse.rules:5: ignoring rule"), logText)
    assert(logText:find("synapsed: mounted aaa111 %(OpenOS%) on /mnt/OpenOS"), logText)

    -- hotplug: same label gets a suffix; nomount rule
    present.ddd444 = "filesystem"
    event("component_added", "ddd444", "filesystem")
    assert(where("ddd444") == "/mnt/OpenOS-ddd", tostring(where("ddd444")))
    present.eee555 = "filesystem"
    event("component_added", "eee555", "filesystem")
    assert(where("eee555") == nil, "nomount rule")

    -- removal unmounts; a busy one is retried until it can be
    present.aaa111 = nil
    event("component_removed", "aaa111", "filesystem")
    assert(where("aaa111") == nil)
    busyPaths["/mnt/bbb"] = true
    present.bbb222 = nil
    event("component_removed", "bbb222", "filesystem")
    assert(where("bbb222") == "/mnt/bbb", "still busy")
    busyPaths["/mnt/bbb"] = nil
    event() -- retry timer fires
    assert(where("bbb222") == nil, "unmounted on retry")
    event("component_removed", "gpu000", "gpu")
    assert(ran[#ran] == "/usr/bin/gpu-hook.lua remove gpu000 gpu")

    -- driver events
    present.prn002 = "printer3d"
    event("component_added", "prn002", "printer3d")
    local before = #ran
    event("device_attached", "prn002", "printer3d", "printer3d", "printer1")
    assert(#ran == before + 1 and ran[#ran] == "/usr/bin/printer-hook.lua add prn002 printer3d printer3d printer1")
    event("device_detached", "prn002", "printer3d", "printer3d", "printer1")
    assert(ran[#ran] == "/usr/bin/printer-hook.lua remove prn002 printer3d printer3d printer1")
    event("device_attached", "x1", "chat_box", "chatbox", nil)
    assert(ran[#ran] == "/usr/bin/printer-hook.lua remove prn002 printer3d printer3d printer1", "other drivers do not match")
end

io.write("services tests passed\n")
