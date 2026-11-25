-- kill(1): signal names and numbers, groups, -l.
-- Run from the Nexus directory: lua tests/userland/kill.lua
local sent, out, err, exitCode
local live = { [5] = true, [6] = true }
local processLib = {
    kill = function(pid, sig)
        sent[#sent + 1] = pid .. ":" .. sig
        if pid == 1 then return false, "Operation not permitted" end
        if pid > 0 and not live[pid] then return false, "No such process" end
        return true
    end,
    get = function(pid) return live[pid] and { pid = pid } or nil end,
}

local function run(...)
    sent, out, err, exitCode = {}, {}, {}, nil
    local env = setmetatable({
        require = function(name) assert(name == "process"); return processLib end,
        print = function(s) out[#out + 1] = s end,
        io = { stderr = { write = function(_, s) err[#err + 1] = s end } },
        os = { exit = function(c) exitCode = c; error("exit", 0) end },
    }, { __index = _G })
    local chunk = assert(loadfile("root/usr/ubin/kill.lua", "t", env))
    local ok, result = pcall(chunk, ...)
    if not ok then
        assert(result == "exit", result)
    else
        exitCode = result
    end
end

run("5")
assert(sent[1] == "5:15" and exitCode == 0, "default TERM")
run("-9", "5", "6")
assert(sent[1] == "5:9" and sent[2] == "6:9")
run("-INT", "5"); assert(sent[1] == "5:2")
run("-SIGQUIT", "5"); assert(sent[1] == "5:3")
run("-s", "usr1", "5"); assert(sent[1] == "5:10")
run("-n", "18", "5"); assert(sent[1] == "5:18")
run("--", "-7"); assert(sent[1] == "-7:15", "group with --")
run("-KILL", "--", "-7"); assert(sent[1] == "-7:9")
run("-INT", "-7"); assert(sent[1] == "-7:2", "a group after a signal")

run("-BOGUS", "5")
assert(exitCode == 1 and err[1]:find("invalid signal") and #sent == 0)
run("-99", "5"); assert(exitCode == 1)
run("5", "x", "1", "9")
assert(exitCode == 1 and sent[1] == "5:15" and sent[2] == "1:15" and sent[3] == "9:15")
assert(err[1]:find("x: arguments must be") and err[2]:find("Operation not permitted") and err[3]:find("No such process"))
run("-0", "5"); assert(exitCode == 0 and #sent == 0, "signal 0 only checks")
run("-0", "9"); assert(exitCode == 1)
run(); assert(exitCode == 1)

run("-l")
assert(out[1]:find("1%) SIGHUP") and out[1]:find("4%) SIGILL") and #out == 8, out[1])
run("-l", "130"); assert(out[1] == "INT", "exit status to name")
run("-l", "9"); assert(out[1] == "KILL")
run("-l", "term"); assert(out[1] == "15")

print("kill tests passed")
