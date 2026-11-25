-- tools/kbuild.lua - joins the kernel sources into build/kernel.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   lua tools/kbuild.lua          (from nexus/; any OS, Lua 5.3+)
--
-- properties.prelude comes first, as it is: the names sources share. Every
-- source in properties.includes follows in a `do ... end` block of its own,
-- so its locals stay its own and the 200 locals of the chunk are not used up
-- by the kernel as a whole. Lines starting with "---" (annotations) are left
-- out. build.lua runs this before deploying; it can also be loaded and
-- called: kbuild.build(props) returns the output path.

local kbuild = {}

local function readLines(path, out)
    local file, err = io.open(path, "r")
    if not file then error("cannot open " .. path .. ": " .. tostring(err), 0) end
    for line in file:lines("L") do
        if not line:match("^%-%-%-") then out[#out + 1] = line end
    end
    file:close()
    -- a source whose last line has no newline must not run into "end"
    if #out > 0 and out[#out]:sub(-1) ~= "\n" then out[#out + 1] = "\n" end
end

local function timestamp()
    local t = os.date("!*t")
    local wdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
    return string.format("%s %s %02d %02d:%02d:%02d UTC %d",
        wdays[t.wday], months[t.month], t.day, t.hour, t.min, t.sec, t.year)
end

---@param props table properties.lua
---@return string path of the kernel image
function kbuild.build(props)
    local out = {
        "-- " .. props.buildOutput .. " - built on " .. timestamp() .. "\n",
        "-- Copyright (c) 2026 akki697222\n",
        "-- Released under the MIT license\n",
        "-- https://opensource.org/licenses/mit-license.php\n",
    }
    local dir = props.includeDir
    if props.prelude then
        out[#out + 1] = "\n-- The source included from " .. dir .. "/" .. props.prelude .. "\n"
        readLines(dir .. "/" .. props.prelude, out)
    end
    for _, name in ipairs(props.includes) do
        local path = dir .. "/" .. name
        out[#out + 1] = "\n-- The source included from " .. path .. "\ndo\n"
        readLines(path, out)
        out[#out + 1] = "end\n"
    end
    local source = table.concat(out)
    local ok, err = load(source, "=" .. props.buildOutput, "t")
    if not ok then error("the kernel does not compile: " .. tostring(err), 0) end
    local output = props.buildDir .. "/" .. props.buildOutput
    local file, openErr = io.open(output, "wb")
    if not file then error("cannot write " .. output .. ": " .. tostring(openErr), 0) end
    file:write(source)
    file:close()
    return output
end

-- run as a script
if arg and arg[0] and arg[0]:match("kbuild%.lua$") then
    package.path = "./?.lua;" .. package.path
    local props = require("properties")
    os.execute("mkdir " .. props.buildDir .. (package.config:sub(1, 1) == "\\" and " 2>nul" or " -p"))
    local output = kbuild.build(props)
    print("kernel: " .. output .. " (" .. #props.includes .. " sources)")
end

return kbuild
