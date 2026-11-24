-- ln.lua - make links between files
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   ln -s [-fnv] TARGET [LINK_NAME]
--   ln -s [-fnv] TARGET... DIRECTORY
--   ln -s [-fnv] -t DIRECTORY TARGET...
--
-- Only symbolic links exist in the VFS, so -s is required.

local fs = require("filesystem")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("ln", "Create a link to TARGET with the name LINK_NAME.")
parser:flag("-s --symbolic", "make symbolic links instead of hard links")
parser:flag("-f --force", "remove existing destination files")
parser:flag("-n --no-dereference", "treat LINK_NAME as a normal file if it is a symlink to a directory")
parser:flag("-v --verbose", "print name of each linked file")
parser:flag("-T --no-target-directory", "treat LINK_NAME as a normal file always")
parser:flag("-L --logical", "(ignored)")
parser:flag("-P --physical", "(ignored)")
parser:option("-t --target-directory", "specify the DIRECTORY in which to create the links"):argname("DIRECTORY")
parser:argument("name", "TARGET [LINK_NAME] | TARGET... DIRECTORY"):args("+")

local opts = textio.parse("ln", parser, { ... })
if not opts.symbolic then
    textio.fail("ln", "hard links are not supported; use ln -s")
end

local function base(path) return (path:gsub("/+$", "")):match("([^/]+)$") or path end
local function isDir(path)
    if opts.no_target_directory then return false end
    if opts.no_dereference and fs.isLink(path) then return false end
    return fs.isDirectory(path)
end

local names, targets, dest = opts.name, {}, nil
if opts.target_directory then
    targets, dest = names, opts.target_directory
    if not fs.isDirectory(dest) then
        textio.fail("ln", "target '" .. dest .. "' is not a directory")
    end
elseif #names == 1 then
    targets, dest = { names[1] }, "."
else
    dest = names[#names]
    for i = 1, #names - 1 do targets[i] = names[i] end
end
local intoDir = opts.target_directory ~= nil or isDir(dest)
if #targets > 1 and not intoDir then
    textio.fail("ln", "target '" .. dest .. "' is not a directory")
end

local status = 0
for _, target in ipairs(targets) do
    local linkPath = dest
    if intoDir then linkPath = (dest:gsub("/+$", "")) .. "/" .. base(target) end
    if opts.force and fs.exists(linkPath) then fs.remove(linkPath) end
    local ok, err = fs.link(target, linkPath)
    if ok then
        if opts.verbose then io.write("'", linkPath, "' -> '", target, "'\n") end
    else
        io.stderr:write("ln: failed to create symbolic link '" .. linkPath .. "': " .. tostring(err) .. "\n")
        status = 1
    end
end
return status
