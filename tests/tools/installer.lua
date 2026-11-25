-- Tests for installer/nexus-install.lua against a mocked OpenOS.
-- Run from nexus with: lua tests/tools/installer.lua
local nximg = assert(loadfile("tools/nximg.lua"))()

local function read(path)
    local f = assert(io.open(path, "rb"))
    local v = f:read("a")
    f:close()
    return v
end
local function write(path, value)
    local f = assert(io.open(path, "wb"))
    f:write(value)
    f:close()
end

local installer_source = read("installer/nexus-install.lua")

-- Distribution in a temp directory (store image keeps the test fast).
local dist = os.tmpname()
os.remove(dist)
assert(os.execute('mkdir "' .. dist .. '"'))
local fs_raw = nximg.encodeFs({ { path = "bin", kind = nximg.FS_DIR, mode = tonumber("755", 8) } })
local image = nximg.encode({
    { type = nximg.SECTION.kernel, data = string.rep("-- kernel\n", 3000) },
    { type = nximg.SECTION.usr, data = fs_raw },
    { type = nximg.SECTION.etc, data = fs_raw },
}, { compression = nximg.COMP_STORE, blockSize = 4096 })
write(dist .. "/nexusos", image)
write(dist .. "/init.lua", "-- image init\n")
write(dist .. "/config.lua", "return {}\n")

local function new_disk(label)
    local files, dirs = {}, { ["/"] = true }
    local handles, nh = {}, 0
    local d = { files = files, dirs = dirs, label = label, writes = 0, used = 0, staged = false }
    local proxy = {}
    local function parent(p) return p:match("^(.*)/[^/]+$") or "" end
    local function ensure(p)
        local dir = parent(p)
        if dir == "" then return end
        dirs[dir] = true
        ensure(dir)
    end
    d.put = function(p, v) files[p] = v ensure(p) end
    function proxy.isDirectory(p) return dirs[p] == true end
    function proxy.makeDirectory(p)
        if p == "/.nexus-install" then d.staged = true end
        dirs[p] = true
        return true
    end
    function proxy.exists(p) return files[p] ~= nil or dirs[p] == true end
    function proxy.list(p)
        local base = p:gsub("/+$", "")
        local out = {}
        for f in pairs(files) do
            if parent(f) == base then out[#out + 1] = f:sub(#base + 2) end
        end
        for dir in pairs(dirs) do
            if dir ~= "/" and parent(dir) == base then out[#out + 1] = dir:sub(#base + 2) .. "/" end
        end
        table.sort(out)
        return out
    end
    function proxy.open(p, mode)
        assert(mode == "wb")
        assert(dirs[parent(p) == "" and "/" or parent(p)], "no parent for " .. p)
        nh = nh + 1
        handles[nh] = p
        files[p] = ""
        return nh
    end
    function proxy.write(h, data)
        if d.failAfter and d.writes >= d.failAfter then return nil, "disk full" end
        d.writes = d.writes + 1
        files[handles[h]] = files[handles[h]] .. data
        return true
    end
    function proxy.close(h) handles[h] = nil end
    function proxy.remove(p)
        for f in pairs(files) do
            if f == p or f:sub(1, #p + 1) == p .. "/" then files[f] = nil end
        end
        for dir in pairs(dirs) do
            if dir == p or dir:sub(1, #p + 1) == p .. "/" then dirs[dir] = nil end
        end
        return true
    end
    function proxy.rename(a, b)
        if not files[a] then return false end
        files[b], files[a] = files[a], nil
        return true
    end
    function proxy.spaceTotal() return 2 ^ 20 end
    function proxy.spaceUsed() return d.used end
    function proxy.setLabel(v) d.label = v end
    return d, proxy
end

-- OpenOS as it is on the boot disk before the install
local OPENOS = {
    ["/init.lua"] = "-- openos init\n",
    ["/lib/core/boot.lua"] = "-- boot\n",
    ["/bin/sh.lua"] = "-- sh\n",
    ["/home/user/notes.txt"] = "mine\n",
    ["/boot/config.lua"] = "old config\n",
}

local DEFAULT_BASE = "https://github.com/akki697222/nexus/releases/download/"

local function run(argv, options)
    options = options or {}
    local target, target_proxy = new_disk("OpenOS")
    local other, other_proxy = new_disk("Other")
    for k, v in pairs(options.preload or OPENOS) do target.put(k, v) end
    target.failAfter = options.failAfter
    target.used = options.used or 0
    local proxies = { target = target_proxy, other = other_proxy }
    local labels = { target = "OpenOS", other = "Other" }
    local boot_set, rebooted
    local requested, printed = {}, {}
    local modules = {
        component = {
            list = function(kind)
                assert(kind == "filesystem")
                local order, i = { "other", "target" }, 0
                return function() i = i + 1 return order[i] end
            end,
            invoke = function(address, method)
                if method == "getLabel" then return labels[address] end
                if method == "isReadOnly" then return false end
                if method == "spaceTotal" then return 2 ^ 20 end
                if method == "spaceUsed" then return 0 end
                error("unexpected invoke " .. method)
            end,
            proxy = function(address) return proxies[address] end,
        },
        computer = {
            getBootAddress = function() return options.boot or "target" end,
            setBootAddress = function(a) boot_set = a end,
            shutdown = function(r) rebooted = r end,
            freeMemory = function() return options.memory or 2 ^ 21 end,
        },
        internet = {
            request = function(url)
                requested[#requested + 1] = url
                local name = url:match("([^/]+)$")
                local data = (options.remote or {})[name]
                if not data then error("404 " .. url) end
                local pos = 1
                return function()
                    if pos > #data then return nil end
                    local chunk = data:sub(pos, pos + 999)
                    pos = pos + 1000
                    return chunk
                end
            end,
        },
    }
    local errors = {}
    local answered = false
    local env = setmetatable({
        require = function(name) return assert(modules[name], "unexpected module " .. name) end,
        io = setmetatable({
            write = function() end,
            read = function()
                answered = true
                return options.answer
            end,
            stderr = { write = function(_, ...) errors[#errors + 1] = table.concat({ ... }) end },
        }, { __index = io }),
        print = function(...) printed[#printed + 1] = table.concat({ ... }, "\t") end,
    }, { __index = _G })
    local chunk = assert(load(installer_source, "=nexus-install", "t", env))
    local code = chunk(table.unpack(argv))
    return {
        code = code, disk = target, other = other, boot = boot_set, rebooted = rebooted,
        errors = table.concat(errors), requested = requested, answered = answered,
        output = table.concat(printed, "\n"),
    }
end

local function untouched(disk)
    for path, value in pairs(OPENOS) do
        assert(disk.files[path] == value, "changed: " .. path)
    end
    assert(not disk.files["/boot/nexusos"])
    assert(not disk.dirs["/.nexus-install"], "stage left behind")
end

local function installed(disk, config)
    assert(disk.files["/boot/nexusos"] == image)
    assert(disk.files["/init.lua"] == "-- image init\n")
    assert(disk.files["/boot/config.lua"] == (config or "return {}\n"))
    assert(not disk.dirs["/.nexus-install"], "stage left behind")
    for path in pairs(disk.files) do assert(not path:match("%.new$"), path) end
end

-- 1. Clean install to the boot disk: OpenOS and /home are erased, the
--    computer reboots into Nexus.
local r = run({ "--from", dist, "-y" })
assert(r.code == 0, r.errors)
installed(r.disk)
assert(not r.disk.files["/lib/core/boot.lua"] and not r.disk.files["/home/user/notes.txt"])
assert(not r.disk.dirs["/lib"] and not r.disk.dirs["/home"])
assert(r.disk.label == "Nexus" and r.boot == "target" and r.rebooted == true)
assert(not r.answered, "-y must not prompt")
assert(r.output:find("ALL DATA ON THIS DISK WILL BE ERASED", 1, true))

-- 2. Without -y the wipe needs 'yes'.
r = run({ "--from", dist }, { answer = "n" })
assert(r.code == 1 and r.answered)
untouched(r.disk)
assert(r.rebooted == nil)
r = run({ "--from", dist }, { answer = "yes" })
assert(r.code == 0, r.errors)
installed(r.disk)

-- 3. The default source is the GitHub release.
local remote = { nexusos = image, ["init.lua"] = "-- image init\n", ["config.lua"] = "return {}\n" }
r = run({ "-y" }, { remote = remote })
assert(r.code == 0, r.errors)
installed(r.disk)
assert(r.requested[1]:sub(1, #DEFAULT_BASE) == DEFAULT_BASE, r.requested[1])
assert(r.requested[1]:match("/v[%d.]+/nexusos$"), r.requested[1])
r = run({ "-y", "--from", "http://example.test/nexus/" }, { remote = remote })
assert(r.requested[1] == "http://example.test/nexus/nexusos")

-- 4. --upgrade keeps the disk and an existing /boot/config.lua, no prompt.
r = run({ "--from", dist, "--upgrade" })
assert(r.code == 0, r.errors)
installed(r.disk, "old config\n")
assert(r.disk.files["/home/user/notes.txt"] == "mine\n")
assert(not r.answered)

-- 5. Another disk: installed there, no reboot unless asked.
r = run({ "Other", "--from", dist, "-y" })
assert(r.code == 0, r.errors)
installed(r.other)
untouched(r.disk)
assert(r.boot == "other" and r.rebooted == nil)
r = run({ "other", "--from", dist, "-y", "--reboot" })
assert(r.code == 0 and r.rebooted == true)

-- 6. A bad image is rejected before anything is erased.
local function bad(data)
    return run({ "-y", "--from", "http://x.test" },
        { remote = { nexusos = data, ["init.lua"] = "i", ["config.lua"] = "c" } })
end
r = bad(image:sub(1, #image - 1))
assert(r.code == 1 and r.errors:find("expected", 1, true), r.errors)
untouched(r.disk)
r = bad(image:sub(1, 10) .. "X" .. image:sub(12))
assert(r.code == 1 and r.errors:find("checksum", 1, true), r.errors)
untouched(r.disk)
r = bad(("x"):rep(64))
assert(r.code == 1 and r.errors:find("not a Nexus boot image", 1, true), r.errors)
untouched(r.disk)
r = run({ "-y", "--from", "http://x.test" }, { remote = {} })
assert(r.code == 1 and r.errors:find("404", 1, true), r.errors)
untouched(r.disk)

-- 7. A write failure while downloading leaves the disk as it was.
r = run({ "--from", dist, "-y" }, { failAfter = 3 })
assert(r.code == 1 and r.errors:find("disk full", 1, true), r.errors)
untouched(r.disk)

-- 8. Too little free space: the download is staged in memory instead.
r = run({ "--from", dist, "-y" }, { used = 2 ^ 20 - 1024 })
assert(r.code == 0, r.errors)
installed(r.disk)
assert(not r.disk.staged, "must not stage on a full disk")
r = run({ "--from", dist, "-y" }, { used = 2 ^ 20 - 1024, memory = 1024 })
assert(r.code == 1 and r.errors:find("not enough space", 1, true), r.errors)
untouched(r.disk)

-- 9. --help lists the disks and changes nothing.
r = run({ "--help" })
assert(r.code == 0 and r.output:find("* target", 1, true), r.output)
untouched(r.disk)

for _, name in ipairs({ "nexusos", "init.lua", "config.lua" }) do os.remove(dist .. "/" .. name) end
os.remove(dist)
io.write("installer tests passed\n")
