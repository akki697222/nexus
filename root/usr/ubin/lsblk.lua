-- lsblk.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local argparse = require("argparse")
local filesystem = require("filesystem")
local device = require("device")

local parser = argparse("lsblk", "List managed block devices")
parser:flag("-b --bytes", "Print sizes in bytes")
local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("lsblk: " .. tostring(args) .. "\n")
    os.exit(1)
end

local function validSize(value)
    local size = tonumber(value)
    if not size or size ~= size then return nil end
    -- OpenComputers reports an unbounded filesystem's total as -1.
    if size == -1 then return math.huge end
    if size < 0 or size == math.huge or size % 1 ~= 0 then return nil end
    return size
end

local function formatSize(size)
    if size == nil then return "?" end
    if size == math.huge then return "unlimited" end
    if args.bytes then return tostring(size) end
    local units = { "B", "K", "M", "G", "T", "P" }
    local value, unit = size, 1
    while value >= 1024 and unit < #units do
        value, unit = value / 1024, unit + 1
    end
    if unit == 1 then return string.format("%d%s", value, units[unit]) end
    return string.format("%.1f%s", value, units[unit])
end

local mounted = {}
for info, path in filesystem.mounts() do
    if info.address then
        local entries = mounted[info.address] or {}
        entries[#entries + 1] = { path = path, label = info.label, readOnly = info.readOnly }
        mounted[info.address] = entries
    end
end

local rows = {}
for address, manifest in pairs(device.list()) do
    if (manifest.type == "volume" or manifest.type == "floppy") and manifest.node then
        local paths, modes, label = {}, {}
        for _, mount in ipairs(mounted[address] or {}) do
            paths[#paths + 1] = mount.path
            modes[mount.readOnly and "ro" or "rw"] = true
            if mount.label and mount.label ~= "" then label = mount.label end
        end
        table.sort(paths)
        local mode
        if modes.ro and modes.rw then mode = "mixed"
        elseif modes.ro then mode = "ro"
        elseif modes.rw then mode = "rw"
        else mode = "?" end
        rows[#rows + 1] = {
            "/dev/" .. manifest.node,
            manifest.type == "floppy" and "floppy" or "disk",
            formatSize(validSize(manifest.size)),
            mode,
            (label or manifest.product or manifest.desc or "device") .. " [" .. address .. "]",
            #paths > 0 and table.concat(paths, ",") or "-",
        }
    end
end
table.sort(rows, function(a, b) return a[1] < b[1] end)

local headers = { "NAME", "TYPE", "SIZE", "MODE", "LABEL", "MOUNTPOINTS" }
local widths = {}
for i, header in ipairs(headers) do widths[i] = #header end
for _, row in ipairs(rows) do
    for i, value in ipairs(row) do widths[i] = math.max(widths[i], #value) end
end
local function printRow(values)
    io.write(string.format("%-" .. widths[1] .. "s  %-" .. widths[2] .. "s  %" .. widths[3]
        .. "s  %-" .. widths[4] .. "s  %-" .. widths[5] .. "s  %s\n", table.unpack(values)))
end
printRow(headers)
for _, row in ipairs(rows) do printRow(row) end
