-- mv.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")
local fileops = require("fileops")

local parser = argparse("mv", "Move or rename files and directories")
parser:argument("operands", "source(s) and destination"):args("+")

local parsed, args = parser:pparse({...})
if not parsed then
    io.stderr:write("mv: " .. tostring(args) .. "\n")
    return 1
end

local operands = args.operands or {}
if #operands < 2 then
    io.stderr:write("mv: missing file operand\n")
    return 1
end

for _, path in ipairs(operands) do
    if path == "" then
        io.stderr:write("mv: empty path operand\n")
        return 1
    elseif fileops.isReservedPath(path) then
        io.stderr:write("mv: " .. path .. ": reserved path component .meta\n")
        return 1
    end
end

local targetOperand = operands[#operands]
local targetPath = fs.resolve(targetOperand)
local sources = {}
for i = 1, #operands - 1 do sources[i] = operands[i] end

local function attributes(path)
    local ok, value, err = pcall(fs.attributes, path)
    if not ok then return nil, value end
    return value, err
end

local targetAttrs, targetErr = attributes(targetPath)
if #sources > 1 and not fileops.isDirectory(targetPath, targetAttrs) then
    io.stderr:write("mv: target '" .. targetOperand .. "' is not an existing directory\n")
    return 1
end

local status = 0
for _, sourceOperand in ipairs(sources) do
    local source = fs.resolve(sourceOperand)
    local sourceAttrs, sourceErr = attributes(source)
    if not sourceAttrs then
        io.stderr:write("mv: " .. sourceOperand .. ": " .. tostring(sourceErr or "No such file or directory") .. "\n")
        status = 1
    else
        local destination = targetPath
        local currentTargetAttrs = attributes(targetPath)
        if fileops.isDirectory(targetPath, currentTargetAttrs) then
            local name = fileops.basename(source)
            if not name then
                io.stderr:write("mv: " .. sourceOperand .. ": cannot move the root directory by name\n")
                status = 1
                goto continue
            end
            destination = fileops.join(targetPath, name)
        elseif currentTargetAttrs then
            io.stderr:write("mv: " .. sourceOperand .. " -> " .. targetPath .. ": target already exists\n")
            status = 1
            goto continue
        elseif targetErr and tostring(targetErr):lower():find("permission", 1, true) then
            io.stderr:write("mv: " .. targetPath .. ": " .. tostring(targetErr) .. "\n")
            status = 1
            goto continue
        end

        local sourceCanonical = fs.realPath(source) or source
        local destinationCanonical = fileops.canonicalCandidate(destination)
        if sourceCanonical == destinationCanonical then
            io.stderr:write("mv: " .. sourceOperand .. " -> " .. destination .. ": source and target are the same path\n")
            status = 1
            goto continue
        end
        if sourceAttrs.type == "VDIR"
            and fileops.isSameOrDescendant(destinationCanonical, sourceCanonical) then
            io.stderr:write("mv: " .. sourceOperand .. " -> " .. destination .. ": target is inside the source directory\n")
            status = 1
            goto continue
        end

        local destinationAttrs, destinationErr = attributes(destination)
        if destinationAttrs then
            io.stderr:write("mv: " .. sourceOperand .. " -> " .. destination .. ": target already exists\n")
            status = 1
            goto continue
        end
        if destinationErr and tostring(destinationErr):lower():find("permission", 1, true) then
            io.stderr:write("mv: " .. destination .. ": " .. tostring(destinationErr) .. "\n")
            status = 1
            goto continue
        end

        local ok, moved, err = pcall(fs.rename, source, destination)
        if not ok then
            io.stderr:write("mv: " .. sourceOperand .. " -> " .. destination .. ": " .. tostring(moved) .. "\n")
            status = 1
        elseif moved ~= true then
            io.stderr:write("mv: " .. sourceOperand .. " -> " .. destination .. ": " .. tostring(err or "rename failed") .. "\n")
            status = 1
        end
    end
    ::continue::
end

return status
