-- Run from the Nexus directory: lua tests/openoc_registration.lua
local files = {
    ["/etc/init.d/modern"] = true,
    ["/etc/init.d/legacy.lua"] = true,
    ["/etc/init.d/uname"] = true,
}
local directories = {
    ["/etc/init.d"] = true,
    ["/etc/runlevels"] = true,
    ["/etc/runlevels/default"] = true,
}
local allowDefinitionRead = false
local fs = {
    concat = function(a, b) return a .. "/" .. b end,
    attributes = function(path)
        if files[path] then return { type = "VREG" } end
        if directories[path] then return { type = "VDIR" } end
    end,
    exists = function(path) return files[path] == true or directories[path] == true end,
    isDirectory = function(path) return directories[path] == true end,
    open = function(path, mode)
        if allowDefinitionRead and path == "/etc/init.d/uname" and mode == "r" then
            local file = assert(io.open("root/etc/init.d/uname", "r"))
            return {
                readAll = function() return file:read("*a") end,
                read = function(_, ...) return file:read(...) end,
                close = function() file:close() end,
            }
        end
        -- rc-update registers a definition without loading or executing it.
        assert(mode == "w" and path:match("^/etc/runlevels/default/"))
        files[path] = true
        return { close = function() end }
    end,
}
local parserSource = assert(loadfile("root/usr/lib/libargparse.lua"))
local services, errors
local env = setmetatable({
    require = function(name)
        if name == "filesystem" then return fs end
        if name == "openoc.service" then return assert(services) end
        if name == "argparse" then return parserSource() end
        if name == "process" then return { getCurrent = function() return { euid = 0 } end } end
        error("unexpected module: " .. name)
    end,
    io = { stderr = { write = function(_, message) errors[#errors + 1] = message end } },
    print = function() end,
    os = { exit = function(code) error(code, 0) end },
}, { __index = _G })
services = assert(loadfile("root/usr/lib/openoc/service.lua", "t", env))()
allowDefinitionRead = true
local uname = assert(services.read(assert(services.find("uname")), "uname"))
assert(uname.oneshot and uname.execpath == "/usr/ubin/uname.lua")
allowDefinitionRead = false
local run = assert(loadfile("root/usr/bin/rc-update.lua", "t", env))
for _, name in ipairs({ "legacy", "modern" }) do
    errors = {}
    assert(pcall(run, "add", name), table.concat(errors))
    assert(files["/etc/runlevels/default/" .. name])
end
errors = {}
local ok, code = pcall(run, "add", "unknown")
assert(not ok and code == 1 and not files["/etc/runlevels/default/unknown"])
print("OpenOC registration tests passed")
