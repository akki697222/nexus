-- uname.lua - print system information
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- With no option, -s is assumed.

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("uname", "Print certain system information.")
parser:flag("-a --all", "print all information")
parser:flag("-s --kernel-name", "print the kernel name"):target("s")
parser:flag("-n --nodename", "print the network node hostname"):target("n")
parser:flag("-r --kernel-release", "print the kernel release"):target("r")
parser:flag("-v --kernel-version", "print the kernel version"):target("v")
parser:flag("-m --machine", "print the machine hardware name"):target("m")
parser:flag("-p --processor", "print the processor type"):target("p")
parser:flag("-i --hardware-platform", "print the hardware platform"):target("i")
parser:flag("-o --operating-system", "print the operating system"):target("o")

local opts = textio.parse("uname", parser, { ... })

-- _OSVERSION looks like "Nexus 0.0.6-oc"
local name, release = tostring(_OSVERSION or "Nexus"):match("^(%S+)%s+(.+)$")
name = name or tostring(_OSVERSION or "Nexus")
release = release or "unknown"

local function hostname()
    local file = io.open("/etc/hostname", "r")
    local text = file and file:read("*l")
    if file then file:close() end
    return (text and text ~= "") and text or "localhost"
end

local any = opts.s or opts.n or opts.r or opts.v or opts.m or opts.p or opts.i or opts.o
local all = opts.all
local fields = {}
if all or opts.s or not any then fields[#fields + 1] = name end
if all or opts.n then fields[#fields + 1] = hostname() end
if all or opts.r then fields[#fields + 1] = release end
if all or opts.v then fields[#fields + 1] = tostring(_OSDIST or _OSVERSION or name) end
if all or opts.m then fields[#fields + 1] = "opencomputers" end
-- like GNU, -p and -i print "unknown" and are left out of -a
if opts.p then fields[#fields + 1] = "unknown" end
if opts.i then fields[#fields + 1] = "unknown" end
if all or opts.o then fields[#fields + 1] = name end
io.write(table.concat(fields, " "), "\n")
return 0
