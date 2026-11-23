-- cp.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")
local fileops = require("fileops")

local parser = argparse("cp", "Copy files and directories")
parser:flag("-R -r", "Copy directories recursively")
parser:argument("operands", "source(s) and destination"):args("+")

local parsed, args = parser:pparse({...})
if not parsed then
    io.stderr:write("cp: " .. tostring(args) .. "\n")
    return 1
end

local operands = args.operands or {}
if #operands < 2 then
    io.stderr:write("cp: missing file operand\n")
    return 1
end

local targetOperand = operands[#operands]
local sources = {}
for i = 1, #operands - 1 do sources[i] = operands[i] end

for _, path in ipairs(operands) do
    if path == "" then
        io.stderr:write("cp: empty path operand\n")
        return 1
    elseif fileops.isReservedPath(path) then
        io.stderr:write("cp: " .. path .. ": reserved path component .meta\n")
        return 1
    end
end

local targetPath = fs.resolve(targetOperand)
local targetAttrs = fs.attributes(targetPath)
if #sources > 1 and not fileops.isDirectory(targetPath, targetAttrs) then
    io.stderr:write("cp: target '" .. targetOperand .. "' is not an existing directory\n")
    return 1
end

local status = 0
local function report(source, destination, reason)
    io.stderr:write("cp: " .. tostring(source)
        .. (destination and (" -> " .. tostring(destination)) or "")
        .. ": " .. tostring(reason or "operation failed") .. "\n")
    status = 1
end

local function attributes(path)
    local ok, value, err = pcall(fs.attributes, path)
    if not ok then return nil, value end
    return value, err
end

local mountPaths = {}
if type(fs.mounts) == "function" then
    local ok, iterator = pcall(fs.mounts)
    if ok and type(iterator) == "function" then
        for _, path in iterator do
            if type(path) == "string" then
                mountPaths[#mountPaths + 1] = fs.realPath(path) or fs.resolve(path)
            end
        end
    end
end

local function closeFile(handle, path)
    local ok, result, err = pcall(handle.close, handle)
    if not ok then return nil, result end
    if result == false or (result == nil and err ~= nil) then
        return nil, err or ("could not close " .. path)
    end
    return true
end

local function hasNestedMount(source)
    local root = fs.realPath(source) or source
    for _, path in ipairs(mountPaths) do
        if path and path ~= root and fileops.isSameOrDescendant(path, root) then
            return true, path
        end
    end
    return false
end

local function copyRegular(source, destination)
    local existing, statErr = attributes(destination)
    if existing then return nil, "target already exists" end
    if statErr and tostring(statErr):lower():find("permission", 1, true) then
        return nil, statErr
    end

    local opened, input, openErr = pcall(fs.open, source, "rb")
    if not opened then return nil, input end
    if not input then return nil, openErr or "could not open source" end
    local output
    local outputCreated = false
    local failure

    local ok, caught = pcall(function()
        output, openErr = fs.open(destination, "wb")
        if not output then error(openErr or "could not create target", 0) end
        outputCreated = true
        while true do
            local chunk, readErr = input:read(4096)
            if chunk == nil then
                if readErr then error(readErr, 0) end
                break
            end
            if chunk == "" then error(readErr or "read returned an empty chunk", 0) end
            local wrote, writeErr = output:write(chunk)
            if wrote == false or wrote == nil or (type(wrote) == "number" and wrote < #chunk) then
                error(writeErr or "could not write target", 0)
            end
        end
    end)
    if not ok then failure = caught end

    local sourceClosed, sourceCloseErr = closeFile(input, source)
    if not sourceClosed and not failure then failure = sourceCloseErr end
    if output then
        local targetClosed, targetCloseErr = closeFile(output, destination)
        if not targetClosed and not failure then failure = targetCloseErr end
    end

    if failure then
        if outputCreated then
            local removed, result, removeErr = pcall(fs.remove, destination)
            if not removed or result ~= true then
                failure = tostring(failure) .. "; cleanup failed: "
                    .. tostring(removed and (removeErr or result) or result)
            end
        end
        return nil, failure
    end
    return true
end

local function copyNode(source, destination, recursive)
    local sourceAttrs, sourceErr = attributes(source)
    if not sourceAttrs then return nil, sourceErr or "No such file or directory" end
    if sourceAttrs.type == "VLNK" then return nil, "symbolic links are not supported" end

    local sourceCanonical = fs.realPath(source) or source
    local destinationCanonical = fileops.canonicalCandidate(destination)
    if destinationCanonical == sourceCanonical then
        return nil, "source and target are the same path"
    end

    if sourceAttrs.type == "VREG" then
        return copyRegular(source, destination)
    end
    if sourceAttrs.type ~= "VDIR" then
        return nil, "unsupported source type " .. tostring(sourceAttrs.type)
    end
    if not recursive then return nil, "-R is required to copy a directory" end

    if type(fs.can) == "function" then
        if not fs.can(source, "r") or not fs.can(source, "x") then
            return nil, "Permission denied"
        end
    end

    if fileops.isSameOrDescendant(destinationCanonical, sourceCanonical) then
        return nil, "target is inside the source directory"
    end
    local nestedMount, mountPath = hasNestedMount(source)
    if nestedMount then
        return nil, "source contains a mounted filesystem at " .. tostring(mountPath)
    end

    local targetAttrs, targetErr = attributes(destination)
    if targetAttrs then return nil, "target already exists" end
    local made, makeErr = fs.makeDirectory(destination)
    if not made then return nil, makeErr or targetErr or "could not create target directory" end

    local iterator, listErr = fs.list(source)
    if not iterator then
        pcall(fs.remove, destination)
        return nil, listErr or "could not list source directory"
    end
    for name in iterator do
        if name ~= "." and name ~= ".." then
            local childSource = fileops.join(source, name)
            local childTarget = fileops.join(destination, name)
            if name == ".meta" then
                report(childSource, childTarget, "reserved path component .meta")
            else
                local ok, err = copyNode(childSource, childTarget, recursive)
                if not ok then report(childSource, childTarget, err) end
            end
        end
    end
    return true
end

for _, sourceOperand in ipairs(sources) do
    local source = fs.resolve(sourceOperand)
    local sourceAttrs, sourceErr = attributes(source)
    if not sourceAttrs then
        report(sourceOperand, nil, sourceErr or "No such file or directory")
    else
        local destination = targetPath
        local currentTargetAttrs = attributes(targetPath)
        if fileops.isDirectory(targetPath, currentTargetAttrs) then
            local name = fileops.basename(source)
            if not name then
                report(sourceOperand, targetPath, "cannot copy the root directory by name")
                goto continue
            end
            destination = fileops.join(targetPath, name)
        elseif currentTargetAttrs then
            if (fs.realPath(source) or source) == (fs.realPath(targetPath) or targetPath) then
                report(sourceOperand, targetPath, "source and target are the same path")
            else
                report(sourceOperand, targetPath, "target already exists")
            end
            goto continue
        end

        local ok, err = copyNode(source, destination, args.R or args.r)
        if not ok then report(sourceOperand, destination, err) end
    end
    ::continue::
end

return status
