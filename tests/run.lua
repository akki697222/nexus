-- tests/run.lua - runs the tests, from nexus/ (Lua 5.3+, any OS):
--
--   lua tests/run.lua [-v] [filter ...]
--
-- Builds build/kernel.lua first (tools/kbuild.lua; tests/tools/image.lua
-- boots it), then runs every tests/<group>/<name>.lua in a Lua process of
-- its own and prints one line per test and a summary. A filter keeps the
-- tests whose "group/name" contains it (kernel, sh_, tty_repeat). -v prints
-- the output of passing tests too; a failing test always shows its output.
-- The exit status is 0 when every test passed.

local GROUPS = { "kernel", "drivers", "userland", "tools" }

local verbose = false
local filters = {}
for _, a in ipairs(arg) do
    if a == "-v" then verbose = true else filters[#filters + 1] = a end
end

if not io.open("properties.lua", "r") then
    io.stderr:write("run.lua: run it from the nexus directory\n")
    os.exit(2)
end

-- the interpreter running this script, for the tests
local lua = arg[-1] or "lua"
local windows = package.config:sub(1, 1) == "\\"
local function quote(s) return '"' .. s .. '"' end

local function list(dir)
    local cmd = windows and ('dir /b ' .. quote(dir:gsub("/", "\\")) .. ' 2>nul')
        or ('ls -1 ' .. quote(dir) .. ' 2>/dev/null')
    local names = {}
    local p = io.popen(cmd)
    for line in p:lines() do
        line = line:gsub("\r$", "")
        if line:match("%.lua$") then names[#names + 1] = line end
    end
    p:close()
    table.sort(names)
    return names
end

local function wanted(id)
    if #filters == 0 then return true end
    for _, f in ipairs(filters) do
        if id:find(f, 1, true) then return true end
    end
    return false
end

-- run a command, returning its output and whether it exited with 0
local function run(cmd)
    local p = io.popen(cmd .. " 2>&1")
    local out = p:read("a")
    local ok, _, code = p:close()
    return out, ok == true and (code == nil or code == 0)
end

do
    local out, ok = run(quote(lua) .. " tools/kbuild.lua")
    if not ok then
        io.write("build failed:\n", out)
        os.exit(1)
    end
end

local passed, failed = 0, {}
local started = os.time()
for _, group in ipairs(GROUPS) do
    for _, name in ipairs(list("tests/" .. group)) do
        local id = group .. "/" .. name:gsub("%.lua$", "")
        if wanted(id) then
            local out, ok = run(quote(lua) .. " " .. quote("tests/" .. group .. "/" .. name))
            if ok then
                passed = passed + 1
                io.write("ok    ", id, "\n")
                if verbose and out ~= "" then io.write(out) end
            else
                failed[#failed + 1] = id
                io.write("FAIL  ", id, "\n", (out:gsub("([^\n])$", "%1\n")))
            end
            io.flush()
        end
    end
end

io.write(string.format("\n%d passed, %d failed (%ds)\n", passed, #failed, os.time() - started))
if #failed > 0 then
    io.write("failed: ", table.concat(failed, " "), "\n")
    os.exit(1)
end
if passed == 0 then
    io.write("no test matched\n")
    os.exit(1)
end
