-- Focused du command regressions. Run from nexus/: lua tests/disk_du.lua
local function read(path)
    local file = assert(io.open(path, "r"))
    local value = file:read("*a")
    file:close()
    return value
end

local source = read("root/usr/ubin/du.lua")
local argparse_source = read("root/usr/lib/libargparse.lua")
local compile = loadstring or load
local unpack_args = unpack or table.unpack

local function fixture()
    local nodes = {
        ["/"] = { type = "VDIR", size = 0, children = { "alpha", "mnt", "secret", "sym" } },
        ["/alpha"] = { type = "VDIR", size = 0, children = { "child", "small-a", "small-b", "large" } },
        ["/alpha/child"] = { type = "VDIR", size = 0, children = { "data" } },
        ["/alpha/child/data"] = { type = "VREG", size = 600 },
        ["/alpha/small-a"] = { type = "VREG", size = 100 },
        ["/alpha/small-b"] = { type = "VREG", size = 100 },
        ["/alpha/large"] = { type = "VREG", size = 1536 },
        ["/mnt"] = { type = "VDIR", size = 0, children = { "mounted" } },
        ["/mnt/mounted"] = { type = "VREG", size = 4096 },
        ["/secret"] = { type = "VDIR", size = 0, children = { "hidden" } },
        ["/secret/hidden"] = { type = "VREG", size = 256 },
        ["/sym"] = { type = "VLNK", size = 0, link = "/alpha" },
    }
    local lists = {}
    local fs
    fs = {
        resolve = function(path)
            if path:sub(1, 1) ~= "/" then path = "/" .. path end
            local parts = {}
            for part in path:gmatch("[^/]+") do
                if part == ".." then table.remove(parts)
                elseif part ~= "." then parts[#parts + 1] = part end
            end
            return "/" .. table.concat(parts, "/")
        end,
        attributes = function(path)
            local node = nodes[path]
            if not node then return nil, "No such file or directory" end
            return { type = node.type, size = node.size }
        end,
        can = function(path, action)
            if fs.denySecret and path == "/secret" then return false, "Permission denied" end
            if fs.denySecret and path == "/secret/hidden" then return false, "Permission denied" end
            return true
        end,
        list = function(path)
            lists[path] = (lists[path] or 0) + 1
            local node = nodes[path]
            if not node or node.type ~= "VDIR" then return nil, "Not a directory" end
            local i = 0
            return function()
                i = i + 1
                return node.children[i]
            end
        end,
        mounts = function()
            local entries = { { {}, "/" }, { {}, "/mnt" } }
            local i = 0
            return function()
                i = i + 1
                local entry = entries[i]
                if entry then return entry[1], entry[2] end
            end
        end,
    }
    return fs, lists
end

local function run(argv, fs)
    local printed, errors = {}, {}
    local old_require, old_print, old_io, old_os = require, print, io, os
    local old_argparse = package.loaded.argparse
    package.loaded.argparse = assert(compile(argparse_source, "argparse.lua"))()
    _G.require = function(name)
        if name == "filesystem" then return fs end
        return old_require(name)
    end
    _G.print = function(value) printed[#printed + 1] = tostring(value) end
    _G.io = { stderr = { write = function(_, value) errors[#errors + 1] = value end } }
    _G.os = { exit = function(code) error({ exit = code }) end }
    local ok, err = pcall(function() assert(compile(source, "du.lua"))(unpack_args(argv)) end)
    _G.require, _G.print, _G.io, _G.os = old_require, old_print, old_io, old_os
    package.loaded.argparse = old_argparse
    if not ok and type(err) == "table" and err.exit then
        return table.concat(printed, "\n"), table.concat(errors), err.exit
    end
    assert(ok, tostring(err))
    return table.concat(printed, "\n"), table.concat(errors), 0
end

local fs, lists = fixture()
local output, errors, code = run({ "/alpha" }, fs)
assert(code == 0 and errors == "")
assert(output:find("1\t/alpha/child", 1, true), output)
assert(output:find("3\t/alpha", 1, true), output) -- 600 + 100 + 100 + 1536 = 2336 bytes
assert(not output:find("/alpha/small-a", 1, true), "default output must omit files")

output, errors, code = run({ "-a", "/alpha" }, fs)
assert(code == 0 and output:find("1\t/alpha/small-a", 1, true), output)
assert(output:find("2\t/alpha/large", 1, true), output)

output = run({ "-s", "/alpha", "/alpha/large" }, fs)
assert(output == "3\t/alpha\n2\t/alpha/large", output)

output = run({ "-h", "/alpha/large" }, fs)
assert(output == "1.5KiB\t/alpha/large", output)
output = run({ "-k", "/alpha/large" }, fs)
assert(output == "2\t/alpha/large", output)

lists["/alpha"] = nil
output = run({ "/sym" }, fs)
assert(output == "0\t/sym", output) -- VFS exposes zero logical bytes for symlinks.
assert(lists["/alpha"] == nil, "a symlink operand must not be traversed")

fs.denySecret = false
output = run({ "-x", "/" }, fs)
assert(output:find("0\t/mnt", 1, true), output)
assert(not output:find("mounted", 1, true), output)
assert(output:find("3\t/", 1, true), output) -- total excludes the mounted file.
assert(lists["/mnt"] == nil, "-x must not descend into a nested mount")

fs.denySecret = true
lists["/secret"] = nil
output, errors, code = run({ "/secret", "/alpha/large" }, fs)
assert(code == 1 and errors:find("/secret", 1, true), errors)
assert(output == "2\t/alpha/large", output)
assert(lists["/secret"] == nil, "protected directories must not be listed")

output, errors, code = run({ "", "/alpha/large" }, fs)
assert(code == 1 and errors:find("empty path", 1, true), errors)
assert(output == "2\t/alpha/large", output)

io.write("du tests passed\n")
