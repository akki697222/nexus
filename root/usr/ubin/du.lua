-- du.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")

local parser = argparse("du", "Estimate apparent file space usage")
parser:add_help(false)
parser:description("Report logical VFS apparent bytes. VFS does not expose block allocation; sizes are rounded up to KiB by default.")
parser:flag("-s --summarize", "Show only totals for explicit operands")
parser:flag("-a --all", "Show files as well as directories")
parser:flag("-h --human-readable", "Show human-readable apparent sizes")
parser:flag("-k --kilobytes", "Show apparent sizes in 1 KiB units")
parser:flag("-x --one-file-system", "Do not descend into nested mount points")
parser:flag("--help", "Show this help message and exit."):action(function()
    print(parser:get_help())
    os.exit(0)
end)
parser:argument("path", "file or directory"):args("*")

local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("du: " .. tostring(args) .. "\n")
    os.exit(1)
end

if #args.path == 0 then args.path[1] = "." end

local function report(path, reason)
    io.stderr:write("du: '" .. tostring(path) .. "': " .. tostring(reason) .. "\n")
end

local function canonical(path)
    return fs.resolve(path) or path
end

local function collect_mounts()
    local mounts = {}
    if not args.one_file_system or type(fs.mounts) ~= "function" then return mounts end
    for _, path in fs.mounts() do
        mounts[canonical(path)] = true
    end
    return mounts
end

local mounts = collect_mounts()

local function actual_path(path)
    if not args.one_file_system then return canonical(path) end
    if type(fs.realPath) == "function" then
        local real = fs.realPath(path)
        if real then return canonical(real) end
    end
    return canonical(path)
end

local function is_mount_boundary(path, start_path)
    if not args.one_file_system then return false end
    local real = actual_path(path)
    if real == start_path then return false end
    return mounts[real] == true
end

local function read_children(path)
    local ok_list, iterator, err = pcall(fs.list, path)
    if not ok_list then return nil, iterator end
    if not iterator then return nil, err or "Unable to read directory" end

    local names = {}
    local ok_iter, iter_err = pcall(function()
        for name in iterator do names[#names + 1] = name end
    end)
    if not ok_iter then return nil, iter_err end
    table.sort(names)
    return names
end

local function child_display_path(parent, name)
    if parent == "/" then return "/" .. name end
    return parent:gsub("/+$", "") .. "/" .. name
end

local function size_of(path, attr)
    if attr.type == "VLNK" then
        -- The VFS reports zero for links and does not expose target-text length.
        return math.max(0, tonumber(attr.size) or 0)
    elseif attr.type == "VREG" then
        local readable, can_err = fs.can(path, "r")
        if not readable then return nil, can_err or "Permission denied" end
        return math.max(0, tonumber(attr.size) or 0)
    elseif attr.type == "VDIR" then
        return math.max(0, tonumber(attr.size) or 0)
    end
    -- Device nodes and other special VFS entries are intentionally omitted.
    return 0
end

local function walk(path, shown_path, start_path, entries, explicit, attr)
    if not attr then
        local attr_err
        attr, attr_err = fs.attributes(path)
        if not attr then return nil, attr_err or "No such file or directory" end
    end

    local own_size, size_err = size_of(path, attr)
    if own_size == nil then return nil, size_err end

    if attr.type ~= "VDIR" then
        if not args.summarize and (args.all or explicit) then
            entries[#entries + 1] = { own_size, shown_path }
        end
        return own_size
    end

    local total = own_size
    do
        local real = actual_path(path)
        if not fs.can(path, "x") or not fs.can(path, "r")
            or (real ~= path and (not fs.can(real, "x") or not fs.can(real, "r"))) then
            return nil, "Permission denied"
        end
        local names, list_err = read_children(path)
        if not names then return nil, list_err end
        for _, name in ipairs(names) do
            local child_path = canonical(path .. "/" .. name)
            local child_display = child_display_path(shown_path, name)
            local child_attr, child_attr_err = fs.attributes(child_path)
            if not child_attr then
                return nil, child_attr_err or "Unable to stat entry"
            end

            if child_attr.type == "VDIR" and is_mount_boundary(child_path, start_path) then
                -- Count the mount directory's own VFS size but do not cross it.
                local mount_size = tonumber(child_attr.size) or 0
                total = total + mount_size
                if not args.summarize then
                    entries[#entries + 1] = { mount_size, child_display }
                end
            else
                local child_total, child_err = walk(child_path, child_display,
                    start_path, entries, false, child_attr)
                if child_total == nil then return nil, child_err end
                total = total + child_total
            end
        end
    end

    if not args.summarize then entries[#entries + 1] = { total, shown_path } end
    return total
end

local function format_size(bytes)
    if args.human_readable then
        local units = { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" }
        local value, unit = bytes, 1
        while value >= 1024 and unit < #units do
            value, unit = value / 1024, unit + 1
        end
        if unit == 1 then return string.format("%dB", value) end
        return string.format("%.1f%s", value, units[unit])
    end

    -- Aggregate bytes first, then round the final total upward to a KiB.
    return tostring(math.ceil(bytes / 1024))
end

local failed = false
for _, operand in ipairs(args.path) do
    local total, walk_err
    local entries = {}
    if operand == "" then
        walk_err = "empty path"
    else
        local path = canonical(operand)
        local real_start = args.one_file_system and actual_path(path) or path
        total, walk_err = walk(path, operand, real_start, entries, true)
    end
    if total == nil then
        report(operand, walk_err)
        failed = true
    else
        if args.summarize then entries = { { total, operand } } end
        for _, entry in ipairs(entries) do
            print(format_size(entry[1]) .. "\t" .. entry[2])
        end
    end
end

os.exit(failed and 1 or 0)
