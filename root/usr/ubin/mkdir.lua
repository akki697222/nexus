-- mkdir.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")

local parser = argparse("mkdir", "Create directories")
parser:flag("-p --parents", "Create parent directories as needed")
parser:argument("directory"):args("+")

local function report(path, reason)
    io.stderr:write("mkdir: '" .. tostring(path) .. "': " .. tostring(reason) .. "\n")
end

local function has_meta_component(path)
    for part in path:gmatch("[^/]+") do
        if part == ".meta" then return true end
    end
    return false
end

local function mkdir_one(path, parents)
    if path == "" then return false, "empty path" end
    if has_meta_component(path) then return false, "Operation not permitted" end

    local resolved = fs.resolve(path)
    if not resolved or resolved == "" then return false, "invalid path" end

    if not parents then return fs.makeDirectory(resolved) end

    local current = resolved:sub(1, 1) == "/" and "/" or "."
    for part in resolved:gmatch("[^/]+") do
        current = current == "/" and ("/" .. part) or (current .. "/" .. part)
        if fs.exists(current) then
            if not fs.isDirectory(current) then return false, "File exists" end
        else
            local ok, err = fs.makeDirectory(current)
            if not ok then return false, err end
        end
    end
    return true
end

local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("mkdir: " .. tostring(args) .. "\n")
    os.exit(1)
end

local failed = false
for _, path in ipairs(args.directory) do
    local created, err = mkdir_one(path, args.parents)
    if not created then
        report(path, err)
        failed = true
    end
end

os.exit(failed and 1 or 0)
