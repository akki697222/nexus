-- sort.lua - sort lines of text files
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Keys follow POSIX: -k F[.C][OPTS][,F[.C][OPTS]] with OPTS from b d f i n g r.
-- Without -t, fields are separated by blanks and a field includes the blanks
-- before it. Lines that compare equal are ordered by a last-resort
-- whole-line comparison unless -s or -u is given.

local fs = require("filesystem")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("sort", "Write sorted concatenation of all FILE(s) to standard output.")
parser:flag("-b --ignore-leading-blanks", "ignore leading blanks"):target("b")
parser:flag("-d --dictionary-order", "consider only blanks and alphanumeric characters"):target("d")
parser:flag("-f --ignore-case", "fold lower case to upper case characters"):target("f")
parser:flag("-i --ignore-nonprinting", "consider only printable characters"):target("i")
parser:flag("-n --numeric-sort", "compare according to string numerical value"):target("n")
parser:flag("-g --general-numeric-sort", "compare according to general numerical value"):target("g")
parser:flag("-r --reverse", "reverse the result of comparisons"):target("r")
parser:flag("-c --check", "check for sorted input; do not sort"):target("check")
parser:flag("-C --check-silent", "like -c, but do not report first bad line"):target("check_silent")
parser:flag("-m --merge", "merge already sorted files; do not sort"):target("merge")
parser:flag("-s --stable", "stabilize sort by disabling last-resort comparison"):target("stable")
parser:flag("-u --unique", "output only the first of an equal run"):target("unique")
parser:flag("-z --zero-terminated", "line delimiter is NUL, not newline"):target("zero")
parser:option("-k --key", "sort via a key; KEYDEF gives location and type"):argname("KEYDEF"):count("*")
parser:option("-t --field-separator", "use SEP instead of non-blank to blank transition"):argname("SEP")
parser:option("-o --output", "write result to FILE instead of standard output"):argname("FILE")
parser:argument("file", "input file, '-' is standard input"):args("*")

local opts = textio.parse("sort", parser, { ... }, 2)

local function die(msg) textio.fail("sort", msg, nil, 2) end

if opts.field_separator and #opts.field_separator ~= 1 then
    die("multi-character tab '" .. opts.field_separator .. "'")
end
local sep = opts.field_separator

local globalFlags = {}
for c in ("bdfingr"):gmatch(".") do globalFlags[c] = opts[c] and true or nil end

-- parse one KEYDEF
local function parseKey(def)
    local function point(text, isEnd)
        local f, c, flags = text:match("^(%d+)%.?(%d*)([bdfignr]*)$")
        if not f then die("invalid number at field start: invalid count at start of '" .. def .. "'") end
        f = tonumber(f)
        if f == 0 then die("field number is zero: invalid field specification '" .. def .. "'") end
        return { field = f, char = c ~= "" and tonumber(c) or nil, flags = flags }
    end
    local a, b = def:match("^([^,]+),?(.*)$")
    if not a then die("invalid key '" .. def .. "'") end
    local key = { start = point(a, false) }
    if b ~= "" then key["end"] = point(b, true) end
    local flags = {}
    for _, p in ipairs({ key.start, key["end"] or { flags = "" } }) do
        for c in p.flags:gmatch(".") do flags[c] = true end
    end
    -- key flags replace the global ones
    local any = next(flags) ~= nil
    key.flags = any and flags or globalFlags
    return key
end

local keys = {}
for _, def in ipairs(opts.key) do keys[#keys + 1] = parseKey(def) end
if #keys == 0 then
    keys[1] = { start = { field = 1 }, flags = globalFlags, whole = true }
end

-- start offset of field n (1-based) and its end, as positions into line
local function fieldBounds(line, n)
    local pos = 1
    if sep then
        for _ = 2, n do
            local i = line:find(sep, pos, true)
            if not i then return #line + 1, #line end
            pos = i + 1
        end
        local i = line:find(sep, pos, true)
        return pos, (i or #line + 1) - 1
    end
    for _ = 1, n - 1 do
        local _, e = line:find("^[ \t]*[^ \t]*", pos)
        pos = e + 1
        if pos > #line then return #line + 1, #line end
    end
    local _, e = line:find("^[ \t]*[^ \t]*", pos)
    return pos, e
end

local function extract(line, key)
    if key.whole then
        if key.flags.b then return (line:gsub("^[ \t]+", "")) end
        return line
    end
    local s = key.start
    local from = fieldBounds(line, s.field)
    if key.flags.b or (s.char and key.start.flags:find("b", 1, true)) then
        local _, e = line:find("^[ \t]*", from)
        from = e + 1
    end
    if s.char then from = from + s.char - 1 end
    local to = #line
    local e = key["end"]
    if e then
        local fs_, fe = fieldBounds(line, e.field)
        if e.char and e.char > 0 then to = math.min(fs_ + e.char - 1, #line) else to = fe end
    end
    if from > to then return "" end
    return line:sub(from, to)
end

local function numeric(s, general)
    local n
    if general then
        n = tonumber(s:match("^%s*([+-]?%d*%.?%d*[eE][+-]?%d+)") or s:match("^%s*([+-]?%d*%.?%d+)"))
    else
        n = tonumber(s:match("^[ \t]*(%-?%d*%.?%d+)") or s:match("^[ \t]*(%-?%d+)"))
    end
    return n or -math.huge
end

local function prepare(text, flags)
    if flags.d then text = text:gsub("[^%w \t]", "") end
    if flags.i then text = text:gsub("[^\32-\126]", "") end
    if flags.f then text = text:upper() end
    return text
end

local function compare(a, b, key)
    local f = key.flags
    local x, y = extract(a, key), extract(b, key)
    local r
    if f.n or f.g then
        local nx, ny = numeric(x, f.g), numeric(y, f.g)
        r = nx < ny and -1 or nx > ny and 1 or 0
    else
        x, y = prepare(x, f), prepare(y, f)
        r = x < y and -1 or x > y and 1 or 0
    end
    if f.r then r = -r end
    return r
end

local function cmp(a, b)
    for _, key in ipairs(keys) do
        local r = compare(a, b, key)
        if r ~= 0 then return r end
    end
    return 0
end

local function lastResort(a, b)
    local r = a < b and -1 or a > b and 1 or 0
    if opts.r then r = -r end
    return r
end

-- read everything
local rows = {}
local eol = opts.zero and "\0" or "\n"
local status = textio.each("sort", opts.file, function(_, _, file)
    local read = textio.chunks(file)
    local buf = ""
    while true do
        local data = read()
        if not data then break end
        buf = buf .. data
        while true do
            local i = buf:find(eol, 1, true)
            if not i then break end
            rows[#rows + 1] = buf:sub(1, i - 1)
            buf = buf:sub(i + 1)
        end
    end
    if buf ~= "" then rows[#rows + 1] = buf end
end)
if status ~= 0 then return 2 end

if opts.check or opts.check_silent then
    for i = 2, #rows do
        local r = cmp(rows[i - 1], rows[i])
        if r == 0 and not opts.stable and not opts.unique then r = lastResort(rows[i - 1], rows[i]) end
        if r > 0 or (r == 0 and opts.unique) then
            if not opts.check_silent then
                io.stderr:write("sort: " .. (opts.file[1] or "-") .. ":" .. i .. ": disorder: " .. rows[i] .. "\n")
            end
            return 1
        end
    end
    return 0
end

local order = {}
for i = 1, #rows do order[i] = i end
table.sort(order, function(i, j)
    local r = cmp(rows[i], rows[j])
    if r == 0 and not opts.stable and not opts.unique then r = lastResort(rows[i], rows[j]) end
    if r ~= 0 then return r < 0 end
    return i < j
end)

local out = { write = function(_, ...) return io.write(...) end, close = function() end }
if opts.output then
    local err
    out, err = fs.open(opts.output, "wb")
    if not out then die(opts.output .. ": " .. tostring(err)) end
end
local lastLine
for _, idx in ipairs(order) do
    local line = rows[idx]
    if not (opts.unique and lastLine and cmp(lastLine, line) == 0) then
        out:write(line, eol)
        lastLine = line
    end
end
out:close()
return 0
