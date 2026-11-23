-- rmdir.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")

local parser = argparse("rmdir", "Remove empty directories")
parser:argument("directory"):args("+")

local function report(path, reason)
    io.stderr:write("rmdir: '" .. tostring(path) .. "': " .. tostring(reason) .. "\n")
end

local function has_meta_component(path)
    for part in path:gmatch("[^/]+") do
        if part == ".meta" then return true end
    end
    return false
end

local function remove_one(path)
    if path == "" then return false, "empty path" end
    if has_meta_component(path) then return false, "Operation not permitted" end
    local trimmed = path:gsub("/+$", "")
    local last = trimmed:match("([^/]*)$")
    if last == "." or last == ".." then return false, "Refusing to remove '.' or '..'" end

    local attr, err = fs.attributes(path)
    if not attr then return false, err or "No such file or directory" end
    if attr.type ~= "VDIR" then return false, "Not a directory" end
    -- vfs.remove performs the emptiness and parent write/search checks.
    return fs.remove(path)
end

local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("rmdir: " .. tostring(args) .. "\n")
    os.exit(1)
end

local failed = false
for _, path in ipairs(args.directory) do
    local removed, err = remove_one(path)
    if not removed then
        report(path, err)
        failed = true
    end
end

os.exit(failed and 1 or 0)
