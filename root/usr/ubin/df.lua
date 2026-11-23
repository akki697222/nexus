-- df.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")

local parser = argparse("df", "Report mounted filesystem space usage")
parser:add_help(false)
parser:flag("-a --all", "Include pseudo and filesystems with unknown capacity")
parser:flag("-h --human-readable", "Print sizes in human-readable units")
parser:flag("-k", "Use 1KiB blocks (the default)")
parser:flag("--help", "Show this help message and exit."):action(function()
    print(parser:get_help())
    os.exit(0)
end)
parser:argument("path", "filesystem path"):args("*")

local rawArgs = {...}
for _, token in ipairs(rawArgs) do
    if token == "" then
        io.stderr:write("df: empty path operand\n")
        return 1
    end
end
local parsed, args = parser:pparse(rawArgs)
if not parsed then
    io.stderr:write("df: " .. tostring(args) .. "\n")
    return 1
end

local function stat(path)
    local ok, result, err = pcall(fs.statfs, path)
    if not ok then return nil, result end
    if not result then return nil, err or "No such file system" end
    return result
end

local records = {}
local status = 0
local operands = args.path or {}
if #operands > 0 then
    for _, path in ipairs(operands) do
        local info, err = stat(path)
        if info then
            info._operand = path
            records[#records + 1] = info
        else
            io.stderr:write("df: " .. tostring(path) .. ": " .. tostring(err) .. "\n")
            status = 1
        end
    end
else
    if type(fs.mounts) ~= "function" then
        io.stderr:write("df: filesystem mount listing is unavailable\n")
        return 1
    end
    local ok, iterator = pcall(fs.mounts)
    if not ok or type(iterator) ~= "function" then
        io.stderr:write("df: could not list mounted filesystems\n")
        return 1
    end
    for _, mountPath in iterator do
        local info, err = stat(mountPath)
        if info then
            records[#records + 1] = info
        else
            io.stderr:write("df: " .. tostring(mountPath) .. ": " .. tostring(err) .. "\n")
            status = 1
        end
    end
end

local function hasCapacity(info)
    return type(info.total) == "number" and info.total > 0
end

if #operands == 0 and not args.all then
    local visible = {}
    for _, info in ipairs(records) do
        if hasCapacity(info) then visible[#visible + 1] = info end
    end
    records = visible
end

if #operands == 0 then
    table.sort(records, function(a, b)
        local ap, bp = tostring(a.mountPath or ""), tostring(b.mountPath or "")
        if ap ~= bp then return ap < bp end
        return tostring(a.address or a.label or "") < tostring(b.address or b.label or "")
    end)
end

local function formatSize(bytes)
    if type(bytes) ~= "number" then return "-" end
    if bytes == math.huge then return "unlimited" end
    if not args.human_readable then return tostring(math.floor(bytes / 1024)) end
    if bytes < 1024 then return string.format("%.0fB", bytes) end
    local units = { "K", "M", "G", "T", "P", "E" }
    local value, unit = bytes / 1024, 1
    while value >= 1024 and unit < #units do
        value, unit = value / 1024, unit + 1
    end
    return string.format("%.1f%s", value, units[unit])
end

local function usage(info)
    local total, used = info.total, info.used
    if type(total) ~= "number" or type(used) ~= "number" then return "-" end
    if total == math.huge then return used == math.huge and "-" or "0%" end
    if total <= 0 then return used <= 0 and "0%" or "100%" end
    return tostring(math.floor(math.min(100, used / total * 100) + 0.5)) .. "%"
end

local blockHeader = args.human_readable and "Size" or "1K-blocks"
print(string.format("%-22s %10s %10s %10s %4s %s",
    "Filesystem", blockHeader, "Used", "Available", "Use%", "Mounted on"))
for _, info in ipairs(records) do
    local source = info.label
    if type(source) ~= "string" or source == "" then source = info.address end
    if type(source) ~= "string" or source == "" then source = "unknown" end
    local available
    if type(info.total) == "number" and type(info.used) == "number" then
        if info.total == math.huge and info.used == math.huge then
            available = nil
        else
            available = math.max(0, info.total - info.used)
        end
    end
    print(string.format("%-22s %10s %10s %10s %4s %s",
        source, formatSize(info.total), formatSize(info.used),
        formatSize(available), usage(info), tostring(info.mountPath or info._operand or "?")))
end

return status
