-- rm.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")

local parser = argparse("rm", "Remove files or directories")
parser:flag("-r -R --recursive", "Remove directories and their contents")
parser:flag("-f --force", "Ignore nonexistent paths")
parser:argument("path"):args("*")

local function report(path, reason)
    io.stderr:write("rm: '" .. tostring(path) .. "': " .. tostring(reason) .. "\n")
end

local function has_meta_component(path)
    for part in path:gmatch("[^/]+") do
        if part == ".meta" then return true end
    end
    return false
end

local function explicit_dot_component(path)
    local trimmed = path:gsub("/+$", "")
    local last = trimmed:match("([^/]*)$")
    return last == "." or last == ".."
end

local function mount_paths()
    local paths = {}
    for _, path in fs.mounts() do
        paths[#paths + 1] = fs.resolve(path)
    end
    return paths
end

local function contains_mount(path, mounts)
    local real = fs.realPath(path) or fs.resolve(path)
    for _, mount in ipairs(mounts) do
        if mount == real or (real == "/" and mount:sub(1, 1) == "/")
            or mount:sub(1, #real + 1) == real .. "/" then
            return true
        end
    end
    return false
end

local function remove_tree(path, attr, mounts)
    if attr.type ~= "VDIR" then return fs.remove(path) end
    if contains_mount(path, mounts) then return false, "Refusing to remove a mount point or traverse into one" end
    if not fs.can(path, "r") or not fs.can(path, "x") then
        return false, "Permission denied"
    end

    local entries, err = fs.list(path)
    if not entries then return false, err or "Unable to read directory" end
    for name in entries do
        local child = fs.resolve(path .. "/" .. name)
        local child_attr, child_err = fs.attributes(child)
        if not child_attr then return false, child_err or "No such file or directory" end
        local ok, remove_err = remove_tree(child, child_attr, mounts)
        if not ok then return false, remove_err end
    end
    return fs.remove(path)
end

local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("rm: " .. tostring(args) .. "\n")
    os.exit(1)
end
if #args.path == 0 then
    if args.force then os.exit(0) end
    io.stderr:write("rm: missing file operand\n")
    os.exit(1)
end

local failed = false
local mounts = args.recursive and mount_paths() or nil
for _, path in ipairs(args.path) do
    local problem
    if path == "" then
        problem = "empty path"
    elseif has_meta_component(path) then
        problem = "Operation not permitted"
    elseif explicit_dot_component(path) then
        problem = "Refusing to remove '.' or '..'"
    else
        local attr, attr_err = fs.attributes(path)
        if not attr then
            if not (args.force and attr_err == "No such file or directory") then
                problem = attr_err or "No such file or directory"
            end
        elseif attr.type == "VDIR" and not args.recursive then
            problem = "Is a directory"
        else
            local removed, err
            if args.recursive then
                removed, err = remove_tree(path, attr, mounts)
            else
                removed, err = fs.remove(path)
            end
            if not removed then problem = err or "Unable to remove" end
        end
    end

    if problem then
        report(path, problem)
        failed = true
    end
end

os.exit(failed and 1 or 0)
