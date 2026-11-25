-- Focused regression tests for cp and mv. Run from nexus with:
-- lua tests/userland/fileops_copy_move.lua
local function read(path)
    local file = assert(io.open(path, "r"))
    local value = file:read("*a")
    file:close()
    return value
end

local compile = loadstring or load
local unpackArgs = unpack or table.unpack
local cpSource = read("root/usr/ubin/cp.lua")
local mvSource = read("root/usr/ubin/mv.lua")
local argparseSource = read("root/usr/lib/libargparse.lua")
local fileopsSource = read("root/usr/lib/libfileops.lua")

local function normalize(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then table.remove(parts)
        elseif part ~= "." and part ~= "" then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
end

local function newWorld()
    local nodes = { ["/"] = { type = "VDIR" } }
    local aliases = {}
    local failures = {}
    local function resolve(path)
        path = normalize(path:sub(1, 1) == "/" and path or ("/work/" .. path))
        for alias, target in pairs(aliases) do
            if path == alias or path:sub(1, #alias + 1) == alias .. "/" then
                path = target .. path:sub(#alias + 1)
                break
            end
        end
        return normalize(path)
    end
    local function addDir(path)
        path = resolve(path)
        nodes[path] = nodes[path] or { type = "VDIR" }
        if path ~= "/" then
            local parent = path:match("^(.*)/[^/]+$")
            if parent == "" then parent = "/" end
            nodes[parent] = nodes[parent] or { type = "VDIR" }
        end
    end
    local function addFile(path, data)
        path = resolve(path)
        local parent = path:match("^(.*)/[^/]+$")
        addDir(parent == "" and "/" or parent)
        nodes[path] = { type = "VREG", data = data }
    end
    addDir("/work")
    local fs = {}
    fs.resolve = resolve
    fs.concat = function(a, b) return normalize((a == "/" and "" or a) .. "/" .. b) end
    fs.name = function(path) return resolve(path):match("([^/]+)$") or "/" end
    fs.path = function(path)
        local parent = resolve(path):match("^(.*)/[^/]+$")
        return parent == "" and "/" or parent
    end
    fs.realPath = function(path) return nodes[resolve(path)] and resolve(path) or nil end
    fs.can = function(path)
        return failures.canDenied ~= resolve(path)
    end
    fs.attributes = function(path)
        local node = nodes[resolve(path)]
        if not node then return nil, "No such file or directory" end
        return { type = node.type }
    end
    fs.isDirectory = function(path)
        local node = nodes[resolve(path)]
        return node and node.type == "VDIR" or false
    end
    fs.list = function(path)
        path = resolve(path)
        if not fs.isDirectory(path) then return nil, "Not a directory" end
        local children = {}
        for child in pairs(nodes) do
            if child ~= path then
                local parent = child:match("^(.*)/[^/]+$")
                if parent == "" then parent = "/" end
                if parent == path then children[#children + 1] = child:match("([^/]+)$") end
            end
        end
        table.sort(children)
        local index = 0
        return function()
            index = index + 1
            return children[index]
        end
    end
    fs.makeDirectory = function(path)
        path = resolve(path)
        if nodes[path] then return false, "File exists" end
        addDir(path)
        return true
    end
    fs.remove = function(path)
        path = resolve(path)
        if not nodes[path] then return false, "No such file" end
        if nodes[path].type == "VDIR" then
            for child in pairs(nodes) do
                if child:sub(1, #path + 1) == path .. "/" then return false, "Directory not empty" end
            end
        end
        nodes[path] = nil
        return true
    end
    fs.open = function(path, mode)
        path = resolve(path)
        if mode == "rb" then
            local node = nodes[path]
            if not node then return nil, "No such file" end
            if failures.read then return nil, "Read open failed" end
            local offset = 1
            return {
                read = function(_, size)
                    if failures.read then return nil, "Read failed" end
                    if offset > #node.data then return nil end
                    local chunk = node.data:sub(offset, offset + size - 1)
                    offset = offset + #chunk
                    return chunk
                end,
                close = function() if failures.closeRead then error("Read close failed") end end
            }
        elseif mode == "wb" then
            if nodes[path] then return nil, "File exists" end
            local node = { type = "VREG", data = "" }
            nodes[path] = node
            return {
                write = function(_, data)
                    if failures.write then return nil, "Write failed" end
                    node.data = node.data .. data
                    return true
                end,
                close = function() if failures.closeWrite then error("Write close failed") end end
            }
        end
        return nil, "Unsupported mode"
    end
    fs.rename = function(oldPath, newPath)
        oldPath, newPath = resolve(oldPath), resolve(newPath)
        if not nodes[oldPath] then return false, "No such file" end
        if nodes[newPath] then return false, "File exists" end
        local moving = {}
        for path, node in pairs(nodes) do
            if path == oldPath or path:sub(1, #oldPath + 1) == oldPath .. "/" then
                moving[path] = node
            end
        end
        for path in pairs(moving) do nodes[path] = nil end
        for path, node in pairs(moving) do
            nodes[newPath .. path:sub(#oldPath + 1)] = node
        end
        return true
    end
    fs.mounts = function()
        local mounts = { { path = "/" } }
        if failures.nestedMount then mounts[#mounts + 1] = { path = failures.nestedMount } end
        local index = 0
        return function()
            index = index + 1
            local mount = mounts[index]
            if mount then return {}, mount.path end
        end
    end
    return fs, nodes, aliases, failures, addDir, addFile
end

local function run(command, argv, setup)
    local fs, nodes, aliases, failures, addDir, addFile = newWorld()
    if setup then setup(fs, nodes, aliases, failures, addDir, addFile) end
    local errors = {}
    local oldRequire, oldIo = require, io
    local oldArgparse, oldFileops = package.loaded.argparse, package.loaded.fileops
    _G.require = function(name)
        if name == "filesystem" then return fs end
        return oldRequire(name)
    end
    package.loaded.argparse = assert(compile(argparseSource, "argparse.lua"))()
    package.loaded.fileops = assert(compile(fileopsSource, "fileops.lua"))()
    _G.io = { stderr = { write = function(_, value) errors[#errors + 1] = value end } }
    local source = command == "cp" and cpSource or mvSource
    local ok, result = pcall(function()
        return assert(compile(source, command .. ".lua"))(unpackArgs(argv))
    end)
    _G.require, _G.io = oldRequire, oldIo
    package.loaded.argparse, package.loaded.fileops = oldArgparse, oldFileops
    assert(ok, tostring(result))
    return result, table.concat(errors), nodes
end

local binary = "a\0b\255\n"
local status, _, nodes = run("cp", { "src", "dest" }, function(_, _, _, _, _, addFile)
    addFile("/work/src", binary)
end)
assert(status == 0 and nodes["/work/dest"].data == binary, "binary copy failed")

status, _, nodes = run("cp", { "one", "two", "out" }, function(_, _, _, _, addDir, addFile)
    addDir("/work/out")
    addFile("/work/one", "1")
    addFile("/work/two", "2")
end)
assert(status == 0 and nodes["/work/out/one"].data == "1" and nodes["/work/out/two"].data == "2", "multi-source copy failed")

status, _, nodes = run("cp", { "src", "out-alias" }, function(_, _, aliases, _, addDir, addFile)
    aliases["/work/out-alias"] = "/work/out"
    addDir("/work/out")
    addFile("/work/src", "aliased")
end)
assert(status == 0 and nodes["/work/out/src"].data == "aliased", "copy into directory alias failed")

status, errors, nodes = run("cp", { "src", "dest" }, function(_, _, _, _, _, addFile)
    addFile("/work/src", "new")
    addFile("/work/dest", "keep")
end)
assert(status ~= 0 and nodes["/work/dest"].data == "keep" and errors:find("already exists", 1, true), "cp overwrote an existing target")

status, errors, nodes = run("cp", { "src", "src" }, function(_, _, _, _, _, addFile)
    addFile("/work/src", "keep")
end)
assert(status ~= 0 and nodes["/work/src"].data == "keep" and errors:find("same path", 1, true), "same-path copy was not rejected")

status, _, nodes = run("cp", { "-R", "tree", "copy" }, function(_, _, _, _, addDir, addFile)
    addDir("/work/tree/sub")
    addFile("/work/tree/sub/file", binary)
end)
assert(status == 0 and nodes["/work/copy/sub/file"].data == binary, "recursive copy failed")

status, errors, nodes = run("cp", { "-R", "tree", "tree/inside" }, function(_, _, _, _, addDir, addFile)
    addDir("/work/tree/sub")
    addFile("/work/tree/sub/file", "keep")
end)
assert(status ~= 0 and not nodes["/work/tree/inside"] and errors:find("inside the source", 1, true), "recursive self-copy was not rejected")

status, errors, nodes = run("cp", { "-R", "tree", "alias/inside" }, function(_, _, aliases, _, addDir, addFile)
    aliases["/work/alias"] = "/work/tree"
    addDir("/work/tree/sub")
    addFile("/work/tree/sub/file", "keep")
end)
assert(status ~= 0 and not nodes["/work/tree/inside"] and errors:find("inside the source", 1, true), "recursive self-copy through parent alias was not rejected")

status, errors, nodes = run("cp", { "-R", "tree", "copy" }, function(_, _, _, failures, addDir, addFile)
    addDir("/work/tree/sub")
    addFile("/work/tree/sub/file", "keep")
    failures.canDenied = "/work/tree"
end)
assert(status ~= 0 and not nodes["/work/copy"] and errors:find("Permission denied", 1, true), "directory read/search permissions were not enforced")

status, errors, nodes = run("cp", { "-R", "tree", "copy" }, function(_, _, _, failures, addDir, addFile)
    addDir("/work/tree/mnt")
    addFile("/work/tree/mnt/file", "keep")
    failures.nestedMount = "/work/tree/mnt"
end)
assert(status ~= 0 and not nodes["/work/copy"] and errors:find("mounted filesystem", 1, true), "nested mount was traversed")

status, errors, nodes = run("cp", { "src", "dest" }, function(_, _, _, failures, _, addFile)
    addFile("/work/src", "partial")
    failures.write = true
end)
assert(status ~= 0 and nodes["/work/dest"] == nil and errors:find("Write failed", 1, true), "failed copy did not clean up incomplete target")

status, _, nodes = run("mv", { "src", "new" }, function(_, _, _, _, _, addFile)
    addFile("/work/src", binary)
end)
assert(status == 0 and nodes["/work/new"].data == binary and nodes["/work/src"] == nil, "move failed")

status, _, nodes = run("mv", { "one", "two", "out" }, function(_, _, _, _, addDir, addFile)
    addDir("/work/out")
    addFile("/work/one", "1")
    addFile("/work/two", "2")
end)
assert(status == 0 and nodes["/work/out/one"].data == "1" and nodes["/work/out/two"].data == "2", "multi-source move failed")

status, errors, nodes = run("mv", { "src", "dest" }, function(_, _, _, _, _, addFile)
    addFile("/work/src", "new")
    addFile("/work/dest", "keep")
end)
assert(status ~= 0 and nodes["/work/dest"].data == "keep" and errors:find("already exists", 1, true), "mv overwrote an existing target")

status, _, nodes = run("mv", { "tree", "new-tree" }, function(_, _, _, _, addDir, addFile)
    addDir("/work/tree/sub")
    addFile("/work/tree/sub/file", "inside")
end)
assert(status == 0 and nodes["/work/new-tree/sub/file"].data == "inside" and not nodes["/work/tree"], "directory move failed")

status, errors, nodes = run("mv", { "src", "dest" }, function(_, _, aliases, _, _, addFile)
    aliases["/work/alias"] = "/work"
    addFile("/work/src", "keep")
end)
assert(status == 0 and nodes["/work/dest"].data == "keep", "move through destination parent alias failed")

status, errors, nodes = run("cp", { "src", "dest" }, function(_, _, _, failures, _, addFile)
    addFile("/work/src", "data")
    failures.closeWrite = true
end)
assert(status ~= 0 and nodes["/work/dest"] == nil and errors:find("Write close failed", 1, true), "close failure did not clean up incomplete target")

print("fileops cp/mv tests passed")
