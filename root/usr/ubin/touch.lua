-- touch.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")

local parser = argparse("touch", "Update file timestamps")
parser:flag("-c --no-create", "Do not create missing files")
parser:argument("file"):args("+")

local function report(path, reason)
    io.stderr:write("touch: '" .. tostring(path) .. "': " .. tostring(reason) .. "\n")
end

local function has_meta_component(path)
    for part in path:gmatch("[^/]+") do
        if part == ".meta" then return true end
    end
    return false
end

local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("touch: " .. tostring(args) .. "\n")
    os.exit(1)
end

local failed = false
for _, path in ipairs(args.file) do
    local problem
    if path == "" then
        problem = "empty path"
    elseif has_meta_component(path) then
        problem = "Operation not permitted"
    elseif args.no_create then
        local attr, err = fs.attributes(path)
        if attr then
            local touched, touch_err = fs.touch(path)
            if not touched and touch_err ~= "No such file or directory" then
                problem = touch_err or "Unable to update timestamp"
            end
        elseif err ~= "No such file or directory" then
            problem = err or "Unable to inspect path"
        end
    else
        local touched, err = fs.touch(path)
        if not touched then problem = err or "Unable to update timestamp" end
    end

    if problem then
        report(path, problem)
        failed = true
    end
end

os.exit(failed and 1 or 0)
