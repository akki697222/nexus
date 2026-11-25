-- installer/src/main.lua - which stage runs
--
-- Booted by the BIOS there is no OS, so no require: stage1. Run as a
-- program from an OS: stage0.

local args = table.pack(...)
if require == nil and package == nil then
    stage1.main(table.unpack(args, 1, args.n))
else
    return stage0.main(args)
end
