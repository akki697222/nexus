-- modctl command. Run from the Nexus directory: lua tests/userland/modctl.lua
-- argparse is the real library; the kernel-facing modules are stubs.
local out, err, exitCode, written
local calls, euid, depmodErrors

local entries = {
    { name = "tty", kind = "module", version = "1.0", desc = "terminal", size = 120,
      usedBy = { "vt" }, state = "loaded" },
    { name = "vt", kind = "module", version = "1.0", desc = "virtual terminal", size = 300,
      usedBy = {}, state = "loaded" },
    { name = "internet", kind = "driver", version = "0.1.0", desc = "Internet card", size = 500,
      usedBy = {}, state = "available" },
}

local moduleLib = {
    list = function() return entries end,
    info = function(n)
        if n == "internet" then
            return { name = "internet", kind = "driver", version = "0.1.0", version_n = 1, abi = 1,
                     depends = { { "tty" }, { "vt", 2 } }, path = "/usr/lib/modules/x/internet.drv.lua",
                     state = "available", usedBy = {},
                     driver = { match = { "internet" }, priority = 0, class = "network", node = "eth",
                                access = { connect = "rw", isHttpEnabled = "open" } } }
        end
        if n == "tty" then
            return { name = "tty", kind = "module", version = "1.0", path = "/usr/lib/modules/t/tty.lua",
                     state = "loaded", usedBy = { "vt" }, depends = {} }
        end
        return nil, n .. ": not found"
    end,
    load = function(target, opts)
        calls[#calls + 1] = "load " .. target .. (opts.noDeps and " nodeps" or "")
        if opts.dryRun then return true, { "tty", "net" } end
        if target == "net" or target:find("^/usr/lib/modules/") then return true, "net" end
        return nil, "module not found"
    end,
    unload = function(n, opts)
        calls[#calls + 1] = "unload " .. n .. (opts.force and " force" or "") .. (opts.recursive and " recursive" or "")
        if opts.dryRun then return { "vt", "tty" } end
        if n == "tty" and not opts.force then return nil, "in use by vt" end
        return true
    end,
    reindex = function() calls[#calls + 1] = "reindex" end,
}

local tree = {
    ["/usr/lib/modules"] = { "system/", "debug.lua" },
    ["/usr/lib/modules/system"] = { "kernel/" },
}
local fsLib = {
    list = function(dir)
        local names = tree[dir]
        if not names then return nil, "no such directory" end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
    isDirectory = function(p) return p:sub(-1) == "/" end,
    concat = function(a, b) return a .. "/" .. b end,
    attributes = function(p) return { size = 42 } end,
}

local depmodLib = {
    build = function(fsio, root, prefix)
        calls[#calls + 1] = "scan " .. table.concat(fsio.list(root), ",") .. " " .. root .. " " .. prefix
        return { version = 2, abi = 1, modules = { tty = {}, vt = {} } }, depmodErrors, { "example warning" }
    end,
    serialize = function() return "return {}" end,
}

local deviceLib = {
    bindings = function()
        return { { address = "aaaa1111-x", type = "network", driver = "internet", state = "bound" } }
    end,
}

local processLib = { getCurrent = function() return { euid = euid } end }

local function run(...)
    out, err, exitCode, written = {}, {}, nil, nil
    local libs = {
        filesystem = fsLib, module = moduleLib, process = processLib,
        depmod = depmodLib, device = deviceLib,
    }
    local env
    env = setmetatable({
        require = function(n)
            if n == "argparse" then return env.__argparse end
            return libs[n]
        end,
        print = function(s) out[#out + 1] = tostring(s) end,
        io = {
            stderr = { write = function(_, s) err[#err + 1] = s end },
            open = function(path, mode)
                if mode == "w" then
                    return { write = function(_, s) written = s end, close = function() end }
                end
                return nil, path .. ": cannot open"
            end,
        },
        os = { exit = function(c) exitCode = c; error("exit", 0) end },
    }, { __index = _G })
    -- argparse runs in the same sandbox, so its errors reach the stubs above
    env.__argparse = assert(loadfile("root/usr/lib/libargparse.lua", "t", env))()
    local chunk = assert(loadfile("root/usr/bin/modctl.lua", "t", env))
    local ok, e = pcall(chunk, ...)
    if not ok and e ~= "exit" then error(e, 0) end
end

local function has(pattern)
    for _, line in ipairs(out) do
        if line:find(pattern) then return true end
    end
    return false
end

euid, depmodErrors, calls = 0, {}, {}

run()
assert(exitCode == nil and out[1]:find("^NAME") and #out == 4, "default is the table")
assert(out[2]:find("^tty") and out[2]:find("vt") and out[2]:find("loaded"))
assert(out[4]:find("^internet") and out[4]:find("available"))

run("list", "--drivers")
assert(#out == 2 and out[2]:find("^internet") and out[2]:find("%-"), "--drivers keeps drivers only")

run("list", "--raw", "--modules")
assert(out[1] == "tty\tmodule\t1.0\tvt\tloaded", "raw is tab separated without header: " .. tostring(out[1]))
assert(#out == 2)

run("list", "--lsmod")
assert(#out == 3 and out[1]:find("^Module") and out[2]:find("^tty") and out[2]:find("120"))
assert(out[2]:find("1 vt$"), "lsmod counts users then lists them")

run("info", "internet")
assert(exitCode == nil)
assert(has("^name: internet$") and has("^depends: tty,vt>=2$") and has("^match: internet$"))
assert(has("^access: connect=rw, isHttpEnabled=open$") and has("^devices: aaaa1111%-x %(bound%)$"))

run("info", "nope")
assert(exitCode == 1 and err[1]:find("not found"))

run("load", "--dry-run", "net")
assert(exitCode == nil and out[1] == "tty" and out[2] == "net")

run("load", "--no-deps", "/usr/lib/modules/net.lua")
assert(exitCode == nil and out[1] == "loaded net" and calls[#calls] == "load /usr/lib/modules/net.lua nodeps")

run("load", "/tmp/evil.lua")
assert(exitCode == 1 and err[1]:find("module not found"))

run("unload", "tty")
assert(exitCode == 1 and err[1]:find("in use by vt"))

run("unload", "-f", "-r", "tty")
assert(exitCode == nil and calls[#calls] == "unload tty force recursive")

run("unload", "--dry-run", "-r", "tty")
assert(exitCode == nil and out[1] == "vt" and out[2] == "tty")

run("depmod")
assert(exitCode == nil and written == "return {}", "modules.idx is written")
assert(calls[#calls] == "reindex" and calls[#calls - 1]:find("^scan system/,debug.lua /usr/lib/modules"))
assert(has("^wrote /usr/lib/modules/modules.idx %(2 entries%)$") and err[1]:find("warning"))

depmodErrors = { "bad driver" }
run("depmod")
assert(exitCode == 1 and written == nil and err[#err]:find("not written"), "errors keep the old index")
depmodErrors = {}

euid = 1000
run("list")
assert(exitCode == nil, "list is open to any user")
run("info", "tty")
assert(exitCode == nil, "info is open to any user")
run("load", "net")
assert(exitCode == 1 and err[1] == "modctl: Permission denied\n")
run("unload", "tty")
assert(exitCode == 1 and err[1] == "modctl: Permission denied\n")
run("depmod")
assert(exitCode == 1 and err[1] == "modctl: Permission denied\n" and written == nil)
euid = 0

run("frob")
assert(exitCode == 1, "unknown command is refused")

print("modctl tests passed")
