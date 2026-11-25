-- Regression tests for df output and operand handling. Run from nexus with:
-- lua tests/userland/disk_df.lua
local function read(path)
    local f = assert(io.open(path, "r"))
    local value = f:read("*a")
    f:close()
    return value
end

local dfSource = read("root/usr/ubin/df.lua")
local argparseSource = read("root/usr/lib/libargparse.lua")
local compile = loadstring or load
local unpackArgs = unpack or table.unpack
local volumes = {
    ["/"] = { address = "root-disk", label = "Root", total = 8192, used = 2048, mountPath = "/" },
    ["/mnt"] = { address = "data-disk", label = "Data", total = math.huge, used = 1024, mountPath = "/mnt" },
    ["/proc"] = { address = "procfs", label = "proc", total = 0, used = 0, mountPath = "/proc" },
    ["/unknown"] = { address = "mystery", label = nil, total = nil, used = nil, mountPath = "/unknown" },
}
local mountList = { "/mnt", "/proc", "/unknown", "/" }

local function run(argv)
    local printed, errors = {}, {}
    local old = { require = require, print = print, io = io, packageLoaded = package.loaded.argparse }
    package.loaded.argparse = assert(compile(argparseSource, "argparse.lua"))()
    local filesystem = {
        mounts = function()
            local i = 0
            return function()
                i = i + 1
                local path = mountList[i]
                if path then return { address = volumes[path].address }, path end
            end
        end,
        statfs = function(path)
            local info = volumes[path]
            if not info then return nil, "No such file system" end
            local copy = {}
            for k, v in pairs(info) do copy[k] = v end
            return copy
        end,
    }
    _G.require = function(name)
        if name == "filesystem" then return filesystem end
        return old.require(name)
    end
    _G.print = function(line) printed[#printed + 1] = tostring(line) end
    _G.io = { stderr = { write = function(_, value) errors[#errors + 1] = value end } }
    local ok, result = pcall(function() return assert(compile(dfSource, "df.lua"))(unpackArgs(argv)) end)
    _G.require, _G.print, _G.io = old.require, old.print, old.io
    package.loaded.argparse = old.packageLoaded
    assert(ok, tostring(result))
    return table.concat(printed, "\n"), table.concat(errors), result
end

local output, errors, code = run({})
assert(code == 0 and errors == "")
assert(output:find("Root", 1, true) and output:find("Data", 1, true))
assert(not output:find("proc", 1, true) and not output:find("mystery", 1, true))
assert(output:find("8", 1, true))

output, errors, code = run({ "-a" })
assert(code == 0 and errors == "")
assert(output:find("proc", 1, true) and output:find("mystery", 1, true), output)
assert(output:find("unlimited", 1, true))

output, errors, code = run({ "-h", "/" })
assert(code == 0 and errors == "")
assert(output:find("8.0K", 1, true) and output:find("2.0K", 1, true))

output, errors, code = run({ "/proc" })
assert(code == 0 and errors == "" and output:find("proc", 1, true))

output, errors, code = run({ "/", "/missing" })
assert(code == 1 and output:find("Root", 1, true))
assert(errors:find("/missing", 1, true) and errors:find("No such file system", 1, true))

output, errors, code = run({ "" })
assert(code == 1 and errors:find("empty path", 1, true))

io.write("df tests passed\n")
