-- Run with: lua tests/openoc_service.lua
local definitions = {}
local filesystem = {
    attributes = function(path)
        local kind = definitions[path]
        if kind then return { type = kind } end
        return nil
    end,
    open = function(path, mode) return io.open(path, mode) end
}

local oldFilesystem = package.loaded.filesystem
package.loaded.filesystem = filesystem
local service = assert(loadfile("root/usr/lib/openoc/service.lua", "t"))()
package.loaded.filesystem = oldFilesystem

local function writeTemp(contents, suffix)
    local path = os.tmpname() .. (suffix or "")
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
    return path
end

local function readText(contents, name)
    local filePath = writeTemp(contents)
    local result, err = service.read(filePath, name)
    os.remove(filePath)
    return result, err
end

definitions["/etc/init.d/sample"] = "VREG"
definitions["/etc/init.d/sample.lua"] = "VREG"
assert(service.find("sample") == "/etc/init.d/sample", "extensionless definitions take precedence")
definitions["/etc/init.d/not-regular"] = "VDIR"
definitions["/etc/init.d/not-regular.lua"] = "VREG"
assert(service.find("not-regular") == nil, "invalid extensionless entry must not fall back")
assert(service.find("../sample") == nil, "service names reject path traversal")
definitions["/etc/init.d/legacy.lua"] = "VREG"
assert(service.find("legacy") == "/etc/init.d/legacy.lua", "legacy definitions remain discoverable")

local parsed = assert(readText(
    "#!/sbin/openoc-run\r\n" ..
    "# declarative service\r\n" ..
    "description = 'Sample daemon'\r\n" ..
    "command = /usr/bin/sample.lua\r\n" ..
    "command_args='--label \"two words\" \"\" escaped\\ space'\r\n" ..
    "type=oneshot\r\n",
    "service with name"))
assert(parsed.title == "service with name")
assert(parsed.desc == "Sample daemon")
assert(parsed.execpath == "/usr/bin/sample.lua")
assert(parsed.oneshot == true)
assert(#parsed.args == 4 and parsed.args[1] == "--label")
assert(parsed.args[2] == "two words" and parsed.args[3] == "")
assert(parsed.args[4] == "escaped space")

local defaults = assert(readText("#!/sbin/openoc-run\ncommand=/sbin/worker\n"))
assert(defaults.desc ~= "", "description defaults to path name")
assert(defaults.oneshot == false and #defaults.args == 0, "daemon and empty arguments are defaults")
local spacedPath = assert(readText("#!/sbin/openoc-run\ncommand='/opt/my tools/worker'\n"))
assert(spacedPath.execpath == "/opt/my tools/worker", "quoted absolute command paths may contain spaces")

local invalid = {
    { "#!/bin/sh\ncommand=/bin/x\n", "exact shebang required" },
    { "#!/sbin/openoc-run\ncommand=/bin/x\ncommand=/bin/y\n", "duplicate keys rejected" },
    { "#!/sbin/openoc-run\ncommand=/bin/x\nunknown=value\n", "unknown keys rejected" },
    { "#!/sbin/openoc-run\ncommand='unterminated\n", "malformed quotes rejected" },
    { "#!/sbin/openoc-run\ncommand=relative\n", "relative command rejected" },
    { "#!/sbin/openoc-run\ncommand=/bin/x\ncommand_args=\"unterminated\n", "argument quote rejected" },
    { "#!/sbin/openoc-run\ncommand=/bin/x\ncommand_args='$(touch /tmp/pwned)'\n", "substitutions rejected" },
    { "#!/sbin/openoc-run\ncommand='/bin/x\n'\n", "control characters in command rejected" },
    { "#!/sbin/openoc-run\ntype=service\ncommand=/bin/x\n", "unknown service type rejected" },
}
for _, entry in ipairs(invalid) do
    local value, err = readText(entry[1])
    assert(value == nil and err, entry[2])
end

local legacyPath = writeTemp([[
return {
    title = "Legacy",
    desc = "Old format",
    service = "program",
    execpath = "/usr/bin/legacy.lua",
    args = { "one", "two words" }
}
]], ".lua")
local legacy = assert(service.read(legacyPath))
os.remove(legacyPath)
assert(legacy.title == "Legacy" and legacy.desc == "Old format")
assert(legacy.execpath == "/usr/bin/legacy.lua" and legacy.oneshot == false)
assert(#legacy.args == 2 and legacy.args[2] == "two words")

-- Smoke-test the repository's current declarative service, when present.
local actual = io.open("root/etc/init.d/uname", "rb")
if actual then
    actual:close()
    local uname = assert(service.read("root/etc/init.d/uname", "uname"))
    assert(uname.execpath:sub(1, 1) == "/" and uname.oneshot == true)
end

print("OpenOC service reader tests passed")
