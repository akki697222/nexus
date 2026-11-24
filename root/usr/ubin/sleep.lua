-- sleep.lua - delay for a specified amount of time
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- NUMBER may be fractional and take a suffix: s (default), m, h, d.
-- Several arguments add up.

local event = require("event")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("sleep", "Pause for NUMBER seconds.")
parser:argument("number", "NUMBER[s|m|h|d]"):args("+")

local opts = textio.parse("sleep", parser, { ... })

local UNITS = { s = 1, m = 60, h = 3600, d = 86400 }
local total = 0
for _, a in ipairs(opts.number) do
    local num, unit = a:match("^(%d*%.?%d+)([smhd]?)$")
    if not num then textio.fail("sleep", "invalid time interval '" .. a .. "'") end
    total = total + tonumber(num) * UNITS[unit == "" and "s" or unit]
end

-- block on an event that is never sent; the pull times out after `total`
event.pull(total, "\0sleep")
return 0
