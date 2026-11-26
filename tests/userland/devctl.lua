-- devctl command (modctl has its own test).
-- Run from the Nexus directory: lua tests/userland/devctl.lua
local out, err, exitCode

local bindings = {
    { address = "aaaa1111-x", type = "printer3d", driver = "printer3d", node = "printer0", state = "bound" },
    { address = "aaaa2222-y", type = "chat_box", driver = "chatbox", state = "failed", error = "kaboom\nstack" },
    { address = "bbbb3333-z", type = "mystery", state = "unbound" },
}
local calls = {}
local deviceLib = {
    bindings = function() return bindings end,
    drivers = function()
        return { { name = "printer3d", match = { "printer3d" }, priority = 0, class = "printer", desc = "3D printer" },
                 { name = "chatbox", match = { "chat_box" }, priority = 5, class = "chat" } }
    end,
    bind = function(a, d) calls[#calls + 1] = "bind " .. a .. " " .. tostring(d); return true end,
    unbind = function(a) calls[#calls + 1] = "unbind " .. a; return nil, "not bound" end,
    rescan = function() calls[#calls + 1] = "rescan"; return true end,
}

local function run(path, ...)
    out, err, exitCode = {}, {}, nil
    local env = setmetatable({
        require = function(n) return ({ device = deviceLib })[n] end,
        print = function(s) out[#out + 1] = s end,
        io = { stderr = { write = function(_, s) err[#err + 1] = s end } },
        os = { exit = function(c) exitCode = c; error("exit", 0) end },
    }, { __index = _G })
    local chunk = assert(loadfile(path, "t", env))
    local ok, e = pcall(chunk, ...)
    if not ok and e ~= "exit" then error(e) end
end

run("root/usr/sbin/devctl.lua")
assert(out[1]:find("^ADDRESS") and #out == 4)
assert(out[2]:find("aaaa1111") and out[2]:find("/dev/printer0") and out[2]:find("bound"))
assert(out[3]:find("failed: kaboom$"), "only the first line of an error is shown")
assert(out[4]:find("mystery") and out[4]:find("unbound"))

run("root/usr/sbin/devctl.lua", "drivers")
assert(out[1]:find("PRIORITY") and out[2]:find("printer3d") and out[2]:find("3D printer"))
assert(out[3]:find("chatbox") and out[3]:find("5"))

run("root/usr/sbin/devctl.lua", "bind", "bbbb", "x")
assert(exitCode == nil and calls[#calls] == "bind bbbb3333-z x", "prefixes resolve to full addresses")
run("root/usr/sbin/devctl.lua", "bind", "aaaa")
assert(exitCode == 1 and err[1]:find("ambiguous"))
run("root/usr/sbin/devctl.lua", "unbind", "aaaa1")
assert(exitCode == 1 and err[1]:find("not bound") and calls[#calls] == "unbind aaaa1111-x")
run("root/usr/sbin/devctl.lua", "rescan")
assert(exitCode == nil and calls[#calls] == "rescan")
run("root/usr/sbin/devctl.lua", "frob")
assert(exitCode == 1 and err[1]:find("unknown command"))

print("devctl tests passed")
