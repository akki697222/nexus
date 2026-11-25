-- print3d.lua - print a .3dm model on a 3D printer
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Uses the printer3d driver through device.open; needs write access to the
-- printer node (group lp).

local argparse = require("argparse")
local device = require("device")

local parser = argparse("print3d", "Print a .3dm model on a 3D printer")
parser:argument("file", "Model file (.3dm)")
parser:argument("count", "Number of copies"):args("?"):convert(tonumber)
parser:option("-d --device", "Printer node", "/dev/printer0")
parser:flag("-s --status", "Only show the printer status")
local ok, args = parser:pparse({ ... })
if not ok then
    io.stderr:write("print3d: " .. tostring(args) .. "\n")
    os.exit(1)
end

local function fail(msg)
    io.stderr:write("print3d: " .. tostring(msg) .. "\n")
    os.exit(1)
end

if args.status then
    local p, err = device.open(args.device, "r")
    if not p then fail(args.device .. ": " .. err) end
    local state, progress = p.status()
    print(string.format("%s: %s%s, %d job(s) started", args.device, tostring(state),
        type(progress) == "number" and (" " .. progress .. "%") or "", p.jobs()))
    device.close(p)
    return
end

local f, err = io.open(args.file, "r")
if not f then fail(args.file .. ": " .. tostring(err)) end
local text = f:read("a")
f:close()

-- .3dm files are a single Lua table literal; read it as data only
local chunk, perr = load("return " .. text, "=" .. args.file, "t", {})
if not chunk then fail(args.file .. ": " .. tostring(perr)) end
local okm, model = pcall(chunk)
if not okm or type(model) ~= "table" then fail(args.file .. ": not a model") end

local p, oerr = device.open(args.device, "w")
if not p then fail(args.device .. ": " .. oerr) end
local done, perr2 = p.print(model, args.count or 1)
device.close(p)
if not done then fail(perr2) end
print(string.format("printing %d x %s (%d shapes)", args.count or 1,
    tostring(model.label or args.file), #model.shapes))
