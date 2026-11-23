-- Focused tests for mkdir, rmdir, rm, and touch. Run from nexus with:
-- lua tests/fileops_basic.lua
local function read(path)
    local f = assert(io.open(path, "r"))
    local value = f:read("*a")
    f:close()
    return value
end

local sources = {
    mkdir = read("root/usr/ubin/mkdir.lua"),
    rmdir = read("root/usr/ubin/rmdir.lua"),
    rm = read("root/usr/ubin/rm.lua"),
    touch = read("root/usr/ubin/touch.lua"),
    argparse = read("root/usr/lib/argparse.lua"),
}
local compile = loadstring or load
local unpack_args = unpack or table.unpack

local function canonical(path)
    local absolute = path:sub(1, 1) == "/"
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    local result = table.concat(parts, "/")
    if absolute then result = "/" .. result end
    return result == "" and (absolute and "/" or ".") or result
end

local function parent(path)
    if path == "/" then return nil end
    return path:match("^(.*)/[^/]+$") or "/"
end

local function new_fs()
    local nodes = {
        ["/"] = { type = "VDIR" },
        ["/tmp"] = { type = "VDIR" },
        ["/tmp/tree"] = { type = "VDIR" },
        ["/tmp/tree/nested"] = { type = "VDIR" },
        ["/tmp/tree/file"] = { type = "VREG", content = "keep me" },
        ["/tmp/tree/link"] = { type = "VLNK", link = "/tmp/tree/file" },
        ["/tmp/empty"] = { type = "VDIR" },
        ["/tmp/nonempty"] = { type = "VDIR" },
        ["/tmp/nonempty/child"] = { type = "VREG" },
        ["/tmp/alias"] = { type = "VLNK", link = "/tmp/tree" },
    }
    local list_calls, removed = {}, {}
    local mounted = { "/tmp/tree/nested/mount" }
    nodes[mounted[1]] = { type = "VDIR" }
    nodes[mounted[1] .. "/secret"] = { type = "VREG" }

    local function resolve(path)
        if path:sub(1, 1) ~= "/" then path = "/tmp/" .. path end
        return canonical(path)
    end
    local function lookup(path)
        path = resolve(path)
        local node = nodes[path]
        if node and node.type == "VLNK" then return node, path end
        local parts, current = {}, ""
        for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
        current = "/"
        for i, part in ipairs(parts) do
            current = current == "/" and ("/" .. part) or (current .. "/" .. part)
            local prefix = nodes[current]
            if prefix and prefix.type == "VLNK" and i < #parts then
                local rest = {}
                for j = i + 1, #parts do rest[#rest + 1] = parts[j] end
                return lookup(resolve(prefix.link .. "/" .. table.concat(rest, "/")))
            end
        end
        return node, path
    end
    local function attributes(path)
        local node, resolved = lookup(path)
        if not node then return nil, "No such file or directory" end
        if node.permission_error then return nil, "Permission denied" end
        local result = {}
        for k, v in pairs(node) do result[k] = v end
        result.name = resolved:match("([^/]+)$") or "/"
        return result
    end
    local fs = {
        resolve = resolve,
        concat = function(a, b) return resolve(a .. "/" .. b) end,
        exists = function(path) return nodes[resolve(path)] ~= nil end,
        attributes = attributes,
        isDirectory = function(path)
            local node, resolved = lookup(path)
            if node and node.type == "VLNK" then
                node = nodes[resolve(node.link)]
            end
            return node ~= nil and node.type == "VDIR"
        end,
        can = function(path)
            local node = nodes[resolve(path)]
            return node ~= nil and not node.permission_error and not node.read_denied and not node.exec_denied
        end,
        list = function(path)
            local node, resolved = lookup(path)
            if node and node.type == "VLNK" then
                resolved = resolve(node.link)
                node = nodes[resolved]
            end
            if not node or node.type ~= "VDIR" then return nil, "Not a directory" end
            list_calls[resolved] = (list_calls[resolved] or 0) + 1
            local names = {}
            for child in pairs(nodes) do
                if parent(child) == resolved then names[#names + 1] = child:match("([^/]+)$") end
            end
            table.sort(names)
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
        makeDirectory = function(path)
            path = resolve(path)
            if nodes[path] then return false, "File exists" end
            if not nodes[parent(path)] or nodes[parent(path)].type ~= "VDIR" then
                return false, "No such file or directory"
            end
            nodes[path] = { type = "VDIR" }
            return true
        end,
        remove = function(path)
            path = resolve(path)
            local node = nodes[path]
            if not node then return false, "No such file or directory" end
            if node.permission_error then return false, "Permission denied" end
            if node.type == "VDIR" then
                for child in pairs(nodes) do
                    if parent(child) == path then return false, "Directory not empty" end
                end
            end
            if node.permission_error then return false, "Permission denied" end
            nodes[path] = nil
            removed[#removed + 1] = path
            return true
        end,
        mounts = function()
            local i = 0
            return function()
                i = i + 1
                if mounted[i] then return {}, mounted[i] end
            end
        end,
        realPath = function(path)
            local node, resolved = lookup(path)
            if node and node.type == "VLNK" then return resolve(node.link) end
            return resolved
        end,
        touch = function(path)
            path = resolve(path)
            local node = nodes[path]
            if node then
                if node.permission_error then return false, "Permission denied" end
                node.touched = true
                return true
            end
            if not nodes[parent(path)] then return false, "No such file or directory" end
            nodes[path] = { type = "VREG", content = "", touched = true }
            return true
        end,
        _nodes = nodes,
        _list_calls = list_calls,
        _removed = removed,
    }
    return fs
end

local function run(command, argv, fs)
    local errors = {}
    local argparse = assert(compile(sources.argparse, "argparse.lua"))()
    local env = {
        require = function(name)
            if name == "filesystem" then return fs end
            if name == "argparse" then return argparse end
            error("unexpected require: " .. name)
        end,
        io = { stderr = { write = function(_, value) errors[#errors + 1] = tostring(value) end } },
        os = { exit = function(code) error({ exit = code }) end },
        pairs = pairs, ipairs = ipairs, tostring = tostring, type = type,
        table = table, string = string, math = math, assert = assert,
        error = error, pcall = pcall,
    }
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = assert(compile(sources[command], command .. ".lua"))
        setfenv(chunk, env)
    else
        chunk = assert(compile(sources[command], command .. ".lua", "t", env))
    end
    local ok, result = pcall(function() return chunk(unpack_args(argv)) end)
    if not ok and type(result) == "table" and result.exit then
        return result.exit, table.concat(errors)
    end
    assert(ok, tostring(result))
    error(command .. " did not exit")
end

local fs = new_fs()
assert(run("mkdir", { "-p", "/tmp/new/deep", "/tmp/new/deep" }, fs) == 0)
assert(fs._nodes["/tmp/new/deep"].type == "VDIR")
local mkdir_code = run("mkdir", { "/tmp/from-multi", "/tmp/tree/file/child" }, fs)
assert(mkdir_code == 1 and fs._nodes["/tmp/from-multi"], "mkdir must continue after a failed operand")
assert(run("mkdir", { "/tmp/.meta/secret" }, fs) == 1)

fs = new_fs()
assert(run("rmdir", { "/tmp/empty" }, fs) == 0)
fs._nodes["/tmp/unreadable-empty"] = { type = "VDIR", read_denied = true }
assert(run("rmdir", { "/tmp/unreadable-empty" }, fs) == 0, "rmdir should rely on guarded backend removal for emptiness")
local rmdir_code = run("rmdir", { "/tmp/nonempty", "/tmp/tree/link" }, fs)
assert(rmdir_code == 1 and fs._nodes["/tmp/nonempty"] and fs._nodes["/tmp/tree/file"])
assert(run("rmdir", { "/tmp/tree/." }, fs) == 1)

fs = new_fs()
assert(run("rm", { "/tmp/tree/file" }, fs) == 0)
assert(run("rm", {}, fs) == 1, "rm requires at least one operand")
assert(run("rm", { "-f" }, fs) == 0, "-f without operands should succeed")
assert(run("rm", { "/tmp/tree" }, fs) == 1, "rm without -r must refuse directories")
assert(run("rm", { "-f", "/tmp/missing" }, fs) == 0)
fs._nodes["/tmp/denied"] = { type = "VREG", permission_error = true }
assert(run("rm", { "-f", "/tmp/denied" }, fs) == 1, "-f must not hide permission errors")
assert(run("rm", { "-r", "/tmp/tree" }, fs) == 1, "recursive rm must stop before nested mounts")
assert(fs._nodes["/tmp/tree/nested/mount/secret"])
assert((fs._list_calls["/tmp/tree"] or 0) == 0, "mount preflight must happen before traversal")
assert(run("rm", { "-r", "/tmp/alias/nested" }, fs) == 1, "mount checks must use real paths through aliases")
assert(fs._nodes["/tmp/tree/nested"])

fs = new_fs()
assert(run("rm", { "-r", "/tmp/tree/nested" }, fs) == 1, "mount point itself must be protected")
assert(run("rm", { "-r", "/tmp/tree/link" }, fs) == 0, "recursive rm must unlink symlinks without following them")
assert(fs._nodes["/tmp/tree/file"] and not fs._nodes["/tmp/tree/link"])
fs._nodes["/tmp/denied-dir"] = { type = "VDIR", permission_error = true }
fs._nodes["/tmp/denied-dir/child"] = { type = "VREG" }
assert(run("rm", { "-r", "/tmp/denied-dir" }, fs) == 1, "recursive rm must check traversal permissions")
assert(fs._nodes["/tmp/denied-dir/child"])

fs = new_fs()
local sentinel = fs._nodes["/tmp/tree/file"].content
assert(run("touch", { "/tmp/tree/file", "/tmp/new-file" }, fs) == 0)
assert(fs._nodes["/tmp/tree/file"].content == sentinel, "touch must not truncate existing files")
assert(fs._nodes["/tmp/new-file"].type == "VREG")
assert(run("touch", { "-c", "/tmp/no-create" }, fs) == 0)
assert(not fs._nodes["/tmp/no-create"])
assert(run("touch", { "/tmp/.meta/secret" }, fs) == 1)

io.write("fileops_basic tests passed\n")
