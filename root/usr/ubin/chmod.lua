-- chmod.lua - change file mode bits
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   chmod [-R] [-v | -c] [-f] MODE[,MODE]... FILE...
--   chmod [-R] [-v | -c] [-f] --reference=RFILE FILE...
--
-- MODE is octal (755, 0644, 4755) or symbolic: [ugoa]*[-+=][rwxXst]* or
-- [ugoa]*[-+=][ugo], comma separated (u+x, go-w, a=r, g=u, +t, u+s).
-- Without u/g/o/a, + and - apply to all classes minus the umask (022) and
-- = to all. Symbolic links met during -R are not followed.
--
-- Nexus stores modes as decimal digits (755 means rwxr-xr-x); this command
-- works on real permission bits and converts at the edges.

local fs = require("filesystem")

local UMASK = tonumber("022", 8)
local S_ISUID, S_ISGID, S_ISVTX = tonumber("4000", 8), tonumber("2000", 8), tonumber("1000", 8)

local function usage()
    io.stderr:write("usage: chmod [-R] [-v|-c] [-f] MODE[,MODE]... FILE...\n"
        .. "       chmod [-R] [-v|-c] [-f] --reference=RFILE FILE...\n")
    os.exit(1)
end

-- Nexus mode (decimal digits) <-> permission bits
local function toBits(nexusMode) return tonumber(tostring(math.tointeger(nexusMode) or 0), 8) or 0 end
local function toNexus(bits) return math.tointeger(tonumber(string.format("%o", bits))) end

local function symbolic(bits, isDir)
    local function triple(r, w, x, special, specialChar)
        local s = ((bits & r) ~= 0 and "r" or "-") .. ((bits & w) ~= 0 and "w" or "-")
        local hasX = (bits & x) ~= 0
        if (bits & special) ~= 0 then
            s = s .. (hasX and specialChar or specialChar:upper())
        else
            s = s .. (hasX and "x" or "-")
        end
        return s
    end
    return triple(256, 128, 64, S_ISUID, "s") .. triple(32, 16, 8, S_ISGID, "s") .. triple(4, 2, 1, S_ISVTX, "t")
end

-- Parses MODE into a function(bits, isDir) -> bits, or nil + error.
local CLASS = { u = { r = 256, w = 128, x = 64, s = S_ISUID, shift = 6 },
                g = { r = 32, w = 16, x = 8, s = S_ISGID, shift = 3 },
                o = { r = 4, w = 2, x = 1, shift = 0 } }

local function parseMode(text)
    if text:match("^[0-7]+$") then
        if #text > 4 then return nil, "invalid mode: '" .. text .. "'" end
        local value = tonumber(text, 8)
        return function() return value end
    end
    local clauses = {}
    for clause in (text .. ","):gmatch("([^,]*),") do
        local who, rest = clause:match("^([ugoa]*)(.*)$")
        if rest == "" then return nil, "invalid mode: '" .. text .. "'" end
        local ops = {}
        while rest ~= "" do
            local op, perms, tail = rest:match("^([-+=])([rwxXst]*)(.*)$")
            local copy
            if not op then return nil, "invalid mode: '" .. text .. "'" end
            if perms == "" then
                local c, t2 = tail:match("^([ugo])(.*)$")
                if c then copy, tail = c, t2 end
            end
            ops[#ops + 1] = { op = op, perms = perms, copy = copy }
            rest = tail
        end
        clauses[#clauses + 1] = { who = who, ops = ops }
    end

    return function(bits, isDir)
        local original = bits
        for _, clause in ipairs(clauses) do
            local classes, masked = {}, clause.who == ""
            local who = clause.who:gsub("a", "ugo")
            if who == "" then who = "ugo" end
            for c in who:gmatch(".") do classes[c] = true end
            for _, o in ipairs(clause.ops) do
                local set = 0
                if o.copy then
                    local src = CLASS[o.copy]
                    local triple = (bits >> src.shift) & 7
                    for c in pairs(classes) do set = set | (triple << CLASS[c].shift) end
                else
                    for p in o.perms:gmatch(".") do
                        for c in pairs(classes) do
                            local cl = CLASS[c]
                            if p == "r" or p == "w" or p == "x" then
                                set = set | cl[p]
                            elseif p == "X" then
                                if isDir or (original & tonumber("111", 8)) ~= 0 then set = set | cl.x end
                            elseif p == "s" and cl.s then
                                set = set | cl.s
                            elseif p == "t" and c == "o" then
                                set = set | S_ISVTX
                            end
                        end
                    end
                end
                if masked then set = set & ~UMASK end
                if o.op == "+" then
                    bits = bits | set
                elseif o.op == "-" then
                    bits = bits & ~set
                else
                    -- '=' clears the named classes' rwx (and their special bit) first
                    local clear = 0
                    for c in pairs(classes) do
                        local cl = CLASS[c]
                        clear = clear | cl.r | cl.w | cl.x | (cl.s or 0)
                        if c == "o" then clear = clear | S_ISVTX end
                    end
                    -- like GNU chmod: '=' on a directory keeps setuid/setgid unless named
                    if isDir then clear = clear & ~(S_ISUID | S_ISGID) end
                    bits = (bits & ~clear) | set
                end
            end
        end
        return bits
    end
end

-- Arguments -----------------------------------------------------------------

local args = { ... }
local recursive, verbose, changesOnly, quiet = false, false, false, false
local reference
local operands = {}
local i = 1
local endOfOptions = false
while i <= #args do
    local a = args[i]
    if endOfOptions or a == "-" or not a:match("^%-") then
        operands[#operands + 1] = a
    elseif a == "--" then
        endOfOptions = true
    elseif a:match("^%-[rwxXst]+$") or a:match("^%-[ugo]$") then
        operands[#operands + 1] = a -- a symbolic mode such as -w
    elseif a == "--recursive" then recursive = true
    elseif a == "--verbose" then verbose = true
    elseif a == "--changes" then changesOnly = true
    elseif a == "--silent" or a == "--quiet" then quiet = true
    elseif a:match("^%-%-reference=") then reference = a:match("^%-%-reference=(.*)$")
    elseif a == "--help" then usage()
    elseif a:match("^%-[Rvcf]+$") then
        for flag in a:sub(2):gmatch(".") do
            if flag == "R" then recursive = true
            elseif flag == "v" then verbose = true
            elseif flag == "c" then changesOnly = true
            elseif flag == "f" then quiet = true end
        end
    else
        io.stderr:write("chmod: invalid option -- '" .. a .. "'\n")
        usage()
    end
    i = i + 1
end

local apply
if reference then
    local attr = fs.attributes(reference)
    if not attr then
        io.stderr:write("chmod: cannot stat '" .. reference .. "': No such file or directory\n")
        os.exit(1)
    end
    local refBits = toBits(attr.mode)
    apply = function() return refBits end
else
    local modeText = table.remove(operands, 1)
    if not modeText then usage() end
    local err
    apply, err = parseMode(modeText)
    if not apply then
        io.stderr:write("chmod: " .. err .. "\n")
        os.exit(1)
    end
end
if #operands == 0 then
    io.stderr:write("chmod: missing operand\n")
    usage()
end

-- Work ------------------------------------------------------------------------

local status = 0
local function fail(message)
    status = 1
    if not quiet then io.stderr:write("chmod: " .. message .. "\n") end
end

local function change(path, attr)
    local isDir = attr.type == "VDIR"
    local before = toBits(attr.mode)
    local after = apply(before, isDir) & tonumber("7777", 8)
    if after ~= before then
        local ok, err = fs.chmod(path, toNexus(after))
        if ok == nil and err then
            fail(string.format("changing permissions of '%s': %s", path, err))
            return
        end
    end
    if verbose or (changesOnly and after ~= before) then
        if after == before then
            io.write(string.format("mode of '%s' retained as %04o (%s)\n", path, after, symbolic(after, isDir)))
        else
            io.write(string.format("mode of '%s' changed from %04o (%s) to %04o (%s)\n",
                path, before, symbolic(before, isDir), after, symbolic(after, isDir)))
        end
    end
end

local function walk(path, top, depth)
    local attr = fs.attributes(path)
    if not attr then
        fail(string.format("cannot access '%s': No such file or directory", path))
        return
    end
    if attr.type == "VLNK" then
        -- operands are followed like in Unix; links met while recursing are not
        if not top then return end
        if (depth or 0) >= 8 then
            fail(string.format("cannot access '%s': Too many levels of symbolic links", path))
            return
        end
        local target = attr.link or (fs.readlink and fs.readlink(path))
        if not target then
            fail(string.format("cannot access '%s': Broken symbolic link", path))
            return
        end
        if target:sub(1, 1) ~= "/" then target = fs.concat(fs.path(path), target) end
        return walk(target, true, (depth or 0) + 1)
    end
    change(path, attr)
    if recursive and fs.isDirectory(path) and not (attr.type == "VLNK" and not top) then
        local iter = fs.list(path)
        if iter then
            for name in iter do
                walk(fs.concat(path, (name:gsub("/$", ""))), false)
            end
        end
    end
end

for _, path in ipairs(operands) do walk(path, true) end
os.exit(status)
