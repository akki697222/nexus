local argparse = require("argparse")
local process = require("process")
local system = require("system")

local parser = argparse("reboot", "Request a system reboot")
parser:parse({ ... })

local function fail(message)
    io.stderr:write("reboot: " .. message .. "\n")
    os.exit(1)
end

local current = process.getCurrent()
if not current or current.euid ~= 0 then fail("Permission denied") end

local ok, err = system.requestShutdown(true)
if not ok then fail("unable to request reboot: " .. tostring(err or "unknown error")) end
