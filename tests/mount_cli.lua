-- CLI behavior for mount/umount. Run from Nexus: lua tests/mount_cli.lua
local parserSource = assert(io.open("root/usr/lib/argparse.lua", "r")):read("*a")
local mountSource = assert(io.open("root/usr/ubin/mount.lua", "r")):read("*a")
local umountSource = assert(io.open("root/usr/ubin/umount.lua", "r")):read("*a")

local function run(source, argv, mounts, nodes)
    local output, errors, calls = {}, {}, {}
    local fs = {
        mounts = function()
            local i = 0
            return function()
                i = i + 1
                local mount = mounts[i]
                if mount then return mount.info, mount.path end
            end
        end,
        mount = function(sourceArg, target)
            calls[#calls + 1] = { "mount", sourceArg, target }
            return true
        end,
        umount = function(target)
            calls[#calls + 1] = { "umount", target }
            if target == "broken" then return false, "injected failure" end
            return true
        end,
    }
    local modules = {
        filesystem = fs,
        device = { list = function() return nodes end },
        argparse = assert(load(parserSource, "argparse", "t", _G))(),
    }
    local env = setmetatable({
        require = function(name) assert(modules[name], "unexpected module: " .. name); return modules[name] end,
        io = {
            write = function(...) output[#output + 1] = table.concat({ ... }) end,
            stderr = { write = function(_, ...) errors[#errors + 1] = table.concat({ ... }) end },
        },
        os = { exit = function(code) error({ exit = code }, 0) end },
    }, { __index = _G })
    local chunk = assert(load(source, "mount_cli", "t", env))
    local ok, err = pcall(chunk, table.unpack(argv))
    local code = type(err) == "table" and err.exit or nil
    return ok, code, table.concat(output), table.concat(errors), calls
end

local nodes = {
    ["uuid-a"] = { node = "hd0" },
    ["uuid-f"] = { node = "fd0" },
}
local mounts = {
    { info = { address = "uuid-b", label = "Backup", readOnly = true }, path = "/backup" },
    { info = { address = "uuid-a", label = "RootDisk", readOnly = false }, path = "/data" },
}

local ok, code, output = run(mountSource, {}, mounts, nodes)
assert(ok and not code)
assert(output:find("uuid%-a %(RootDisk%) on /data %(rw%)"))
assert(output:find("uuid%-b %(Backup%) on /backup %(ro%)"))
assert(output:find("/backup") < output:find("/data"), "mount list must sort by mount path")

ok, code, _, _, calls = run(mountSource, { "/dev/hd0", "/mnt" }, {}, nodes)
assert(ok and not code and calls[1][2] == "uuid-a" and calls[1][3] == "/mnt")
ok, code, _, _, calls = run(mountSource, { "Backup", "/backup" }, {}, nodes)
assert(ok and not code and calls[1][2] == "Backup")
ok, code = run(mountSource, { "source" }, {}, nodes)
assert(not ok and code == 1)
ok, code = run(mountSource, { "", "/mnt" }, {}, nodes)
assert(not ok and code == 1)

ok, code, _, _, calls = run(umountSource, { "/data" }, mounts, nodes)
assert(ok and not code and calls[1][2] == "/data")
ok, code, _, _, calls = run(umountSource, { "/dev/hd0" }, mounts, nodes)
assert(ok and not code and calls[1][2] == "uuid-a")
ok, code, _, _, calls = run(umountSource, { "uuid-a" }, mounts, nodes)
assert(ok and not code and calls[1][2] == "uuid-a")
ok, code, _, _, calls = run(umountSource, { "RootDisk" }, mounts, nodes)
assert(ok and not code and calls[1][2] == "RootDisk")
ok, code, _, errors, calls = run(umountSource, { "broken", "/data" }, mounts, nodes)
assert(not ok and code == 2 and #calls == 2 and errors:find("broken"))
ok, code = run(umountSource, {}, mounts, nodes)
assert(not ok and code == 1)
print("mount/umount CLI tests passed")
