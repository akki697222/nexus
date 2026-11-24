-- date.lua - print the system date and time
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   date [-u] [-d STRING] [-R | -I[FMT]] [+FORMAT]
--
-- STRING is @EPOCH, YYYY-MM-DD, or YYYY-MM-DD HH:MM[:SS] (also with T).

local fs = require("filesystem")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("date", "Display the current time in the given FORMAT.")
parser:flag("-u --utc --universal", "print Coordinated Universal Time (UTC)"):target("utc")
parser:option("-d --date", "display time described by STRING, not 'now'"):argname("STRING")
parser:option("-r --reference", "display the last modification time of FILE"):argname("FILE")
parser:flag("-R --rfc-email", "output date and time in RFC 5322 format"):target("rfc")
parser:option("-I --iso-8601", "output date/time in ISO 8601 format; FMT is date, hours, minutes or seconds")
    :argname("FMT"):args("?"):target("iso")
parser:argument("format", "+FORMAT"):args("?")

local opts = textio.parse("date", parser, { ... })

local when = os.time()
if opts.reference then
    local m = fs.lastModified and fs.lastModified(opts.reference)
    if not m then textio.fail("date", opts.reference .. ": No such file or directory") end
    when = math.floor(m > 1e11 and m / 1000 or m)
end
if opts.date then
    local epoch = opts.date:match("^@(%-?%d+)$")
    if epoch then
        when = tonumber(epoch)
    else
        local y, mo, d, rest = opts.date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T]?(.*)$")
        if not y then textio.fail("date", "invalid date '" .. opts.date .. "'") end
        local h, mi, s = 0, 0, 0
        if rest ~= "" then
            local hh, mm, ss = rest:match("^(%d%d?):(%d%d):?(%d*)$")
            if not hh then textio.fail("date", "invalid date '" .. opts.date .. "'") end
            h, mi, s = tonumber(hh), tonumber(mm), tonumber(ss) or 0
        end
        when = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = h, min = mi, sec = s })
    end
end

local format = "%a %b %e %H:%M:%S %Z %Y"
if opts.rfc then
    format = "%a, %d %b %Y %H:%M:%S %z"
elseif opts.iso then
    local mode = opts.iso
    if type(mode) == "table" then mode = mode[1] end
    if mode == nil or mode == true then mode = "date" end
    local F = { date = "%Y-%m-%d", hours = "%Y-%m-%dT%H%z", minutes = "%Y-%m-%dT%H:%M%z", seconds = "%Y-%m-%dT%H:%M:%S%z" }
    format = F[mode] or textio.fail("date", "invalid argument '" .. tostring(mode) .. "' for '--iso-8601'")
end
if opts.format then
    if opts.format:sub(1, 1) ~= "+" then textio.fail("date", "invalid date '" .. opts.format .. "'") end
    format = opts.format:sub(2)
end
if opts.utc then format = "!" .. format end

-- %e, %Z, %z and %s are not in every os.date; fill them in if refused
local function render(fmt)
    local ok, text = pcall(os.date, fmt, when)
    if ok then return text end
    local utc = fmt:sub(1, 1) == "!"
    local plain = fmt:gsub("%%e", "%%d"):gsub("%%Z", utc and "UTC" or ""):gsub("%%z", "+0000"):gsub("%%s", tostring(when))
    ok, text = pcall(os.date, plain, when)
    if not ok then textio.fail("date", "invalid format '" .. fmt .. "'") end
    return text
end
io.write(render(format), "\n")
return 0
