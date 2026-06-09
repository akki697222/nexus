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

local deployToOC = false
for i = 1, #arg do
    if arg[i] == "oc" then
        deployToOC = true
        break
    end
end

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
source = source .. "-- Copyright (c) 2026 akki697222\n"
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

if props.overwrite then
    local bootDeploy = "..\\ocelot\\boot"

    print("Overwrite mode: Clearing " .. bootDeploy .. "\\* ...")
    local r1 = os.execute("rd /s /q \"" .. bootDeploy .. "\" > nul 2>&1 && mkdir \"" .. bootDeploy .. "\"")
    if r1 ~= 0 and r1 ~= true then
        print("Warning: Failed to clear " .. bootDeploy)
    end

    if deployToOC then
        local ocDeploy = "D:\\Projects\\OpenComputers\\run\\saves\\dev1.20.1\\opencomputers\\63f96e0b-5ef3-4762-9105-5381c1b3f313"
        print("Overwrite mode: Clearing " .. ocDeploy .. "\\* ...")
        local r2 = os.execute("rd /s /q \"" .. ocDeploy .. "\" > nul 2>&1 && mkdir \"" .. ocDeploy .. "\"")
        if r2 ~= 0 and r2 ~= true then
            print("Warning: Failed to clear " .. ocDeploy)
        end
    end
end

print("Move: " .. outputFile .. " to ../ocelot/boot/boot/kernel.lua")
copyFile(outputFile, "../ocelot/boot/boot/kernel.lua")

print("Deploying ./root to ../ocelot/boot...")
local exitCode = os.execute("xcopy \".\\root\\*\" \"..\\ocelot\\boot\\\" /E /I /Y > nul")

if exitCode ~= 0 and exitCode ~= true then
    print("Warning: Failed to copy ./root directory.")
else
    print("Directory sync complete.")
end

if deployToOC then
    local ocDeploy = "D:\\Projects\\OpenComputers\\run\\saves\\dev1.20.1\\opencomputers\\63f96e0b-5ef3-4762-9105-5381c1b3f313"
    
    os.execute("if not exist \"" .. ocDeploy .. "\\boot\" mkdir \"" .. ocDeploy .. "\\boot\"")
    
    print("Move: " .. outputFile .. " to " .. ocDeploy .. "/boot/kernel.lua")
    local ok, err = copyFile(outputFile, ocDeploy .. "\\boot\\kernel.lua")
    if not ok then
        print("Warning: Failed to copy kernel.lua to OC: " .. (err or ""))
    end

    print("Deploying ./root to " .. ocDeploy .. "...")
    local r3 = os.execute("xcopy \".\\root\\*\" \"" .. ocDeploy .. "\\\" /E /I /Y > nul")
    if r3 ~= 0 and r3 ~= true then
        print("Warning: Failed to sync root to OC save directory.")
    else
        print("OC save directory sync complete.")
    end
end

print("Build complete!")