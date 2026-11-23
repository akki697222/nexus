-- Tests for installer/nexus-install.lua against a mocked OpenOS.
-- Run from nexus with: lua tests/installer.lua
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
    local d = { files = files, dirs = dirs, label = label, writes = 0 }
    local proxy = {}
    function proxy.isDirectory(p) return dirs[p] == true end
    function proxy.makeDirectory(p) dirs[p] = true return true end
    function proxy.exists(p) return files[p] ~= nil or dirs[p] == true end
    function proxy.open(p, mode)
        assert(mode == "wb")
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
    function proxy.remove(p) files[p] = nil return true end
    function proxy.rename(a, b)
        if not files[a] then return false end
        files[b], files[a] = files[a], nil
        return true
    end
    function proxy.setLabel(v) d.label = v end
    return d, proxy
end

local function run(argv, options)
    options = options or {}
    local target, target_proxy = new_disk("Blank")
    local other, other_proxy = new_disk("Other")
    for k, v in pairs(options.preload or {}) do target.files[k] = v end
    target.failAfter = options.failAfter
    local proxies = { target = target_proxy, other = other_proxy }
    local labels = { target = "Blank", other = "Other" }
    local boot_set, rebooted
    local requested = {}
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
            getBootAddress = function() return options.boot or "other" end,
            setBootAddress = function(a) boot_set = a end,
            shutdown = function(r) rebooted = r end,
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
    local env = setmetatable({
        require = function(name) return assert(modules[name], "unexpected module " .. name) end,
        io = setmetatable({
            write = function() end,
            stderr = { write = function(_, ...) errors[#errors + 1] = table.concat({ ... }) end },
        }, { __index = io }),
        print = function() end,
    }, { __index = _G })
    local chunk = assert(load(installer_source, "=nexus-install", "t", env))
    local code = chunk(table.unpack(argv))
    return code, target, boot_set, rebooted, table.concat(errors), requested
end

-- 1. Local install: all three files land, nothing left as .new.
local code, disk, boot_set, rebooted, errors = run({ dist, "Blank", "reboot" })
assert(code == 0, errors)
assert(disk.files["/boot/nexusos"] == image)
assert(disk.files["/init.lua"] == "-- image init\n")
assert(disk.files["/boot/config.lua"] == "return {}\n")
for path in pairs(disk.files) do assert(not path:match("%.new$"), path) end
assert(disk.label == "Nexus" and boot_set == "target" and rebooted == true)

-- 2. Remote install streams over HTTP from <base>/<name>.
local requested
code, disk, _, _, errors, requested = run({ "http://example.test/nexus/", "Blank" },
    { remote = { nexusos = image, ["init.lua"] = "-- init\n", ["config.lua"] = "return {}\n" } })
assert(code == 0, errors)
assert(disk.files["/boot/nexusos"] == image)
assert(requested[1] == "http://example.test/nexus/nexusos")

-- 3. An existing /boot/config.lua is kept (upgrade).
code, disk = run({ dist, "Blank" }, { preload = { ["/boot/config.lua"] = "mine" } })
assert(code == 0 and disk.files["/boot/config.lua"] == "mine")

-- 4. Truncated / corrupt / wrong images are rejected and leave nothing behind.
local function remote_image(data)
    return run({ "http://x.test", "Blank" },
        { remote = { nexusos = data, ["init.lua"] = "i", ["config.lua"] = "c" } })
end
code, disk, _, _, errors = remote_image(image:sub(1, #image - 1))
assert(code == 1 and errors:find("expected", 1, true), errors)
assert(not disk.files["/boot/nexusos"] and not disk.files["/boot/nexusos.new"])
assert(not disk.files["/init.lua"], "a failed image must stop the install")
code, _, _, _, errors = remote_image(image:sub(1, 10) .. "X" .. image:sub(12))
assert(code == 1 and errors:find("checksum", 1, true), errors)
code, _, _, _, errors = remote_image(("x"):rep(64))
assert(code == 1 and errors:find("not a Nexus boot image", 1, true), errors)

-- 5. Write failure cleans up the partial file.
code, disk, _, _, errors = run({ dist, "Blank" }, { failAfter = 3 })
assert(code == 1 and errors:find("disk full", 1, true), errors)
assert(not disk.files["/boot/nexusos.new"] and not disk.files["/boot/nexusos"])

-- 6. The running boot disk is refused unless forced.
code, _, _, _, errors = run({ dist, "Blank" }, { boot = "target" })
assert(code == 1 and errors:find("refusing", 1, true))
code = run({ dist, "Blank", "--force" }, { boot = "target" })
assert(code == 0)

for _, name in ipairs({ "nexusos", "init.lua", "config.lua" }) do os.remove(dist .. "/" .. name) end
os.remove(dist)
io.write("installer tests passed\n")
