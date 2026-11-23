local argparse = require("argparse")
local fs = require("filesystem")
local process = require("process")
local serviceCatalog = require("openoc.service")

local parser = argparse("rc-update", "Manage OpenOC service registration for boot")
parser:command_target("action")
for _, action in ipairs({ "add", "del" }) do
    local command = parser:command(action)
    command:argument("service")
    command:argument("runlevel"):args("?")
end
parser:command("show"):argument("runlevel"):args("?")
local args = parser:parse({ ... })

local function fail(message)
    io.stderr:write("rc-update: " .. message .. "\n")
    os.exit(1)
end

local function validName(name)
    return name:match("^[%w_][%w_%-]*$") ~= nil
end

local root = "/etc/runlevels"
local function show(runlevel)
    local path = fs.concat(root, runlevel)
    if not fs.isDirectory(path) then return end
    local entries, err = fs.list(path)
    if not entries then fail(tostring(err)) end
    for name in entries do
        local attr = fs.attributes(fs.concat(path, name))
        if validName(name) and attr and attr.type == "VREG" then
            print(name .. "\t" .. runlevel)
        end
    end
end

if args.runlevel and not validName(args.runlevel) then fail("Invalid runlevel name") end
if args.action == "show" then
    if args.runlevel then
        show(args.runlevel)
    else
        local entries, err = fs.list(root)
        if not entries then fail(tostring(err)) end
        for name in entries do if validName(name) then show(name) end end
    end
    return
end

local caller = process.getCurrent()
if not caller or caller.euid ~= 0 then fail("Permission denied") end
if not validName(args.service) then fail("Invalid service name") end

local runlevel = args.runlevel or "default"
local directory = fs.concat(root, runlevel)
local marker = fs.concat(directory, args.service)
local registration = fs.attributes(marker)
if registration and registration.type ~= "VREG" then fail("Invalid registration at " .. marker) end

if args.action == "add" then
    local definition, err = serviceCatalog.find(args.service)
    if not definition then fail("Unknown service: " .. args.service .. (err and (": " .. tostring(err)) or "")) end
    if not registration then
        if not fs.isDirectory(directory) then
            local ok, err = fs.makeDirectory(directory)
            if not ok then fail(tostring(err)) end
        end
        local file, err = fs.open(marker, "w")
        if not file then fail(tostring(err)) end
        file:close()
    end
    print(args.service .. " added to " .. runlevel)
elseif registration then
    local ok, err = fs.remove(marker)
    if not ok then fail(tostring(err)) end
    print(args.service .. " removed from " .. runlevel)
else
    print(args.service .. " is not registered in " .. runlevel)
end
