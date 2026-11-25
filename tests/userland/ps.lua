-- Regression tests for ps selection and formatting. Run from nexus with:
-- lua tests/userland/ps.lua
local function read(path)
    local f = assert(io.open(path, "r"))
    local value = f:read("*a")
    f:close()
    return value
end

local ps_source = read("root/usr/ubin/ps.lua")
local argparse_source = read("root/usr/lib/libargparse.lua")
local compile = loadstring or load
local unpack_args = unpack or table.unpack
local processes = {
    { pid = 1, uid = 0, tty = 2, path = "/sbin/init", arguments = {}, status = "running" },
    { pid = 2, uid = 100, tty = -1, path = "/bin/worker", arguments = { "--quiet" }, status = "waiting" },
    { pid = 3, uid = 200, tty = 2, path = "/usr/bin/editor", arguments = {}, status = "running" },
    { pid = 4, uid = 300, tty = -1, path = "/bin/orphan", arguments = {}, status = "waiting" }
}
local users = {
    root = { uid = 0, username = "root" },
    alice = { uid = 100, username = "alice" },
    bob = { uid = 200, username = "bob" }
}

local function run(argv)
    local printed, errors = {}, {}
    local old = {
        require = require, print = print, io = io, os = os,
        arg = arg, package_loaded_argparse = package.loaded.argparse
    }
    local process = {
        list = function() return processes end,
        getCurrent = function() return { tty = 2 } end,
        get = function(pid)
            for _, p in ipairs(processes) do if p.pid == pid then return p end end
        end
    }
    local user = {
        getUser = function(name) return users[name] end,
        getUserByUID = function(uid)
            for _, u in pairs(users) do if u.uid == uid then return u end end
        end
    }
    local argparse = assert(compile(argparse_source, "argparse.lua"))()
    package.loaded.argparse = argparse
    _G.require = function(name)
        if name == "process" then return process end
        if name == "user" then return user end
        return old.require(name)
    end
    _G.print = function(line) printed[#printed + 1] = tostring(line) end
    _G.io = { stderr = { write = function(_, value) errors[#errors + 1] = value end } }
    _G.os = { exit = function(code) error({ exit = code }) end }
    local ok, err = pcall(function()
        assert(compile(ps_source, "ps.lua"))(unpack_args(argv))
    end)
    _G.require, _G.print, _G.io, _G.os = old.require, old.print, old.io, old.os
    package.loaded.argparse = old.package_loaded_argparse
    if not ok and type(err) == "table" and err.exit then
        return nil, table.concat(errors), err.exit
    end
    assert(ok, tostring(err))
    return table.concat(printed, "\n")
end

local function contains(output, text) return output:find(text, 1, true) ~= nil end
local function expect_pids(output, expected)
    local command_by_pid = { [1] = "init", [2] = "worker", [3] = "editor", [4] = "orphan" }
    local expected_set = {}
    for _, pid in ipairs(expected) do
        expected_set[pid] = true
        assert(contains(output, command_by_pid[pid]), "missing PID " .. pid)
    end
    for _, pid in ipairs({ 1, 2, 3, 4 }) do
        if not expected_set[pid] then
            assert(not contains(output, command_by_pid[pid]), "unexpected PID " .. pid .. " in output")
        end
    end
end

expect_pids(run({}), { 1, 3 })
expect_pids(run({ "aux" }), { 1, 2, 3, 4 })
expect_pids(run({ "-e" }), { 1, 2, 3, 4 })
expect_pids(run({ "-A" }), { 1, 2, 3, 4 })
expect_pids(run({ "-p", "2", "-p", "3" }), { 2, 3 })
expect_pids(run({ "-p", "1,3" }), { 1, 3 })
expect_pids(run({ "-p", "1", "-U", "alice" }), { 1, 2 }) -- explicit selectors combine as a union
expect_pids(run({ "-U", "alice" }), { 2 })
expect_pids(run({ "-U", "200" }), { 3 })
expect_pids(run({ "-U", "300" }), { 4 })
expect_pids(run({ "-p", "999" }), {})
local invalid_output, invalid_error, invalid_code = run({ "-p", "nope" })
assert(invalid_output == nil and invalid_code == 1 and invalid_error:find("invalid PID", 1, true))

for _, flags in ipairs({ { "-f" }, { "-l" }, { "-u" }, { "-j" } }) do
    local output = run(flags)
    assert(output and #output > 0, "format did not produce output")
end

io.write("ps tests passed\n")
