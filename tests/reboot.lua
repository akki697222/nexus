-- Run with: lua tests/reboot.lua
local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local parser_source = read("root/usr/lib/argparse.lua")
local function run(command, argv, euid, request_error)
    local events, errors, output = {}, {}, {}
    local parser_chunk = assert(load(parser_source, "argparse.lua", "t", _ENV))
    local argparse = parser_chunk()
    local process = { getCurrent = function()
        events[#events + 1] = "getCurrent"
        return { euid = euid == nil and 0 or euid }
    end }
    local system = { requestShutdown = function(reboot)
        events[#events + 1] = { "requestShutdown", reboot }
        if request_error then return nil, request_error end
        return true
    end }
    local env = {
        require = function(name)
            if name == "argparse" then return argparse end
            if name == "process" then return process end
            if name == "system" then return system end
            error("unexpected require: " .. name)
        end,
        io = {
            stderr = { write = function(_, ...)
                for i = 1, select("#", ...) do errors[#errors + 1] = tostring(select(i, ...)) end
            end },
            write = function(...)
                for i = 1, select("#", ...) do output[#output + 1] = tostring(select(i, ...)) end
            end
        },
        os = { exit = function(code) error({ exit = code }) end },
        tostring = tostring,
        pcall = pcall,
        select = select,
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        table = table,
        string = string,
        math = math,
        assert = assert,
        error = error,
        _VERSION = _VERSION
    }
    local source = read("root/usr/bin/" .. command .. ".lua")
    local chunk = assert(load(source, command .. ".lua", "t", env))
    local ok, err = pcall(function() chunk(table.unpack(argv)) end)
    local code
    if not ok and type(err) == "table" and err.exit then code = err.exit
    elseif not ok then error(err) end
    return events, table.concat(errors), table.concat(output), code
end

local events, errors, _, code = run("reboot", {}, 0)
assert(code == nil and errors == "")
assert(events[1] == "getCurrent")
assert(events[2][1] == "requestShutdown" and events[2][2] == true)

events, errors, _, code = run("poweroff", {}, 0)
assert(code == nil and errors == "")
assert(events[2][1] == "requestShutdown" and events[2][2] == false)

for _, command in ipairs({ "reboot", "poweroff" }) do
    events, errors, _, code = run(command, {}, 100)
    assert(code == 1 and errors:find(command .. ": Permission denied", 1, true))
    assert(#events == 1 and events[1] == "getCurrent", "non-root must not queue shutdown")

    events, errors, _, code = run(command, {}, 0, "backend unavailable")
    assert(code == 1 and errors:find("unable to request", 1, true))
    assert(events[2][1] == "requestShutdown")
end

print("reboot and poweroff tests passed")
