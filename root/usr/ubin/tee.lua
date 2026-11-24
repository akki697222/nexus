-- tee.lua - read from standard input and write to standard output and files
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local fs = require("filesystem")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("tee", "Copy standard input to each FILE, and also to standard output.")
parser:flag("-a --append", "append to the given FILEs, do not overwrite")
parser:flag("-i --ignore-interrupts", "ignore interrupt signals")
parser:argument("file", "output file"):args("*")

local opts = textio.parse("tee", parser, { ... })

local status = 0
local outs = {}
for _, path in ipairs(opts.file) do
    local file, err
    if fs.isDirectory(path) then
        err = "Is a directory"
    else
        file, err = fs.open(path, opts.append and "ab" or "wb")
    end
    if file then
        outs[#outs + 1] = file
    else
        io.stderr:write("tee: " .. path .. ": " .. tostring(err) .. "\n")
        status = 1
    end
end

local read = textio.chunks(io.stdin)
while true do
    local data = read()
    if not data then break end
    io.write(data)
    for _, file in ipairs(outs) do file:write(data) end
end
for _, file in ipairs(outs) do file:close() end
return status
