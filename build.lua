local props = require("properties")

local function expand_template(str, tbl)
    return (str:gsub("%${(.-)}", function(key)
        return tostring(tbl[key] or "")
    end))
end

local function expand_properties(tbl)
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            tbl[k] = expand_template(v, tbl)
        elseif type(v) == "table" then
            expand_properties(v)
        end
    end
end

local function copyFile(srcPath, dstPath)
    local srcFile, err = io.open(srcPath, "r")
    if not srcFile then
        return nil, "Failed to open source file: " .. err
    end

    local dstFile, err = io.open(dstPath, "w+")
    if not dstFile then
        srcFile:close()
        return nil, "Failed to open destination file: " .. err
    end

    while true do
        local chunk = srcFile:read(4096)
        if not chunk then break end
        dstFile:write(chunk)
    end

    srcFile:close()
    dstFile:close()
    return true
end

expand_properties(props)

local t = os.date("!*t")

local wdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local ftime = string.format("%s %s %02d %02d:%02d:%02d UTC %d",
    wdays[t.wday],
    months[t.month],
    t.day,
    t.hour,
    t.min,
    t.sec,
    t.year
)

local source = ""
source = source .. "-- " .. props.buildOutput .. " - built on " .. ftime .. "\n"
source = source .. "-- Copyright (c) 2025 Project Prime\n"
source = source .. "-- Released under the MIT license\n"
source = source .. "-- https://opensource.org/licenses/mit-license.php\n"
for index, value in ipairs(props.includes) do
    print("Include: " .. props.includeDir .. "/" .. value)
    local path = props.includeDir .. "/" .. value
    source = source .. "\n-- The source included from " .. path .. "\n"
    local file = io.open(path, "r")
    if not file then
        error("Failed to open file " .. path)
    end
    for line in file:lines("L") do
        if not line:match("^%-%-%-") then
            source = source .. line
        end
    end
    file:close()
end

local outputFile = props.buildDir .. "/" .. props.buildOutput

local outFile = io.open(outputFile, "w+")
if not outFile then
    error("Failed to open output file " .. outputFile)
end

outFile:write(source)
outFile:close()

print("Move: " .. outputFile .. " to ../ocelot/boot/boot/kernel.lua")
copyFile(outputFile, "../ocelot/boot/boot/kernel.lua")

print("Deploying ./root to ../ocelot/boot...")
local exitCode = os.execute("xcopy \".\\root\\*\" \"..\\ocelot\\boot\\\" /E /I /Y > nul")

if exitCode ~= 0 and exitCode ~= true then
    print("Warning: Failed to copy ./root directory.")
else
    print("Directory sync complete.")
end

print("Build complete!")