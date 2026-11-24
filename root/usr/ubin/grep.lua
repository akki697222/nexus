-- grep.lua - print lines that match patterns
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Patterns are translated to Lua patterns, so only a regex subset works:
-- . * [set] [^set] [[:class:]] ^ $ \w \d \s, and with -E also + ? |.
-- Groups and counted repeats ({n,m}) are not supported; use -F for plain
-- text. Exit status: 0 if a line was selected, 1 if none, 2 on error.

local fs = require("filesystem")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("grep", "Search for PATTERNS in each FILE."):add_help("--help")
parser:flag("-E --extended-regexp", "PATTERNS are extended regular expressions"):target("E")
parser:flag("-F --fixed-strings", "PATTERNS are strings"):target("F")
parser:flag("-G --basic-regexp", "PATTERNS are basic regular expressions (default)"):target("G")
parser:option("-e --regexp", "use PATTERNS for matching"):argname("PATTERNS"):count("*")
parser:option("-f --file", "take PATTERNS from FILE"):argname("FILE"):count("*"):target("patfile")
parser:flag("-i --ignore-case", "ignore case distinctions in patterns and data"):target("i")
parser:flag("-y", "obsolete synonym for -i"):target("i")
parser:flag("--no-ignore-case", "do not ignore case distinctions (default)")
parser:flag("-v --invert-match", "select non-matching lines"):target("v")
parser:flag("-w --word-regexp", "match only whole words"):target("w")
parser:flag("-x --line-regexp", "match only whole lines"):target("x")
parser:flag("-c --count", "print only a count of selected lines per FILE"):target("c")
parser:option("--color --colour", "(accepted and ignored)"):args("?")
parser:flag("-L --files-without-match", "print only names of FILEs with no selected lines"):target("L")
parser:flag("-l --files-with-matches", "print only names of FILEs with selected lines"):target("l")
parser:option("-m --max-count", "stop after NUM selected lines"):argname("NUM"):convert(tonumber):target("m")
parser:flag("-o --only-matching", "show only nonempty parts of lines that match"):target("o")
parser:flag("-q --quiet --silent", "suppress all normal output"):target("q")
parser:flag("-s --no-messages", "suppress error messages"):target("s")
parser:flag("-H --with-filename", "print file name with output lines"):target("H")
parser:flag("-h --no-filename", "suppress the file name prefix on output"):target("h")
parser:flag("-n --line-number", "print line number with output lines"):target("n")
parser:option("-A --after-context", "print NUM lines of trailing context"):argname("NUM"):convert(tonumber):target("A")
parser:option("-B --before-context", "print NUM lines of leading context"):argname("NUM"):convert(tonumber):target("B")
parser:option("-C --context", "print NUM lines of output context"):argname("NUM"):convert(tonumber):target("C")
parser:flag("-r --recursive", "read all files under each directory, recursively"):target("r")
parser:flag("-R --dereference-recursive", "likewise, but follow all symlinks"):target("R")
parser:flag("-a --text", "(ignored)")
parser:flag("-I", "(ignored)")
parser:flag("-U --binary", "(ignored)")
parser:argument("pattern", "PATTERNS"):args("?")
parser:argument("file", "FILE, '-' is standard input"):args("*")

local opts = textio.parse("grep", parser, { ... }, 2)
local function die(msg) textio.fail("grep", msg, nil, 2) end

-- gather patterns
local patterns = {}
for _, p in ipairs(opts.regexp) do patterns[#patterns + 1] = p end
for _, path in ipairs(opts.patfile) do
    local file, err = textio.open(path)
    if not file then die(path .. ": " .. tostring(err)) end
    local readLine = textio.reader(file)
    while true do
        local line = readLine()
        if not line then break end
        patterns[#patterns + 1] = line
    end
    textio.close(file)
end
local files = opts.file
if #opts.regexp == 0 and #opts.patfile == 0 then
    if not opts.pattern then
        io.stderr:write("Usage: grep [OPTION]... PATTERNS [FILE]...\nTry 'grep --help' for more information.\n")
        os.exit(2)
    end
    patterns[1] = opts.pattern
elseif opts.pattern then
    table.insert(files, 1, opts.pattern)
end

local recursive = opts.r or opts.R
if #files == 0 and recursive then files = { "." } end

local CLASSES = {
    alpha = "%a", digit = "%d", alnum = "%w", lower = "%l", upper = "%u",
    space = "%s", punct = "%p", xdigit = "%x", cntrl = "%c",
}

-- translate one regex alternative into a Lua pattern
local function translate(re)
    local ere = opts.E ~= nil
    local out, i, n = {}, 1, #re
    local function lit(c)
        if opts.i then c = c:lower() end
        out[#out + 1] = c:find("^%w$") and c or ("%" .. c)
    end
    while i <= n do
        local c = re:sub(i, i)
        if c == "\\" then
            local d = re:sub(i + 1, i + 1)
            if d == "w" then out[#out + 1] = "[%w_]"
            elseif d == "W" then out[#out + 1] = "[^%w_]"
            elseif d == "d" then out[#out + 1] = "%d"
            elseif d == "s" then out[#out + 1] = "%s"
            elseif d == "S" then out[#out + 1] = "%S"
            elseif d == "<" then out[#out + 1] = "%f[%w_]"
            elseif d == ">" then out[#out + 1] = "%f[^%w_]"
            elseif d == "" then lit("\\")
            elseif d:find("^%p$") then lit(d)
            else out[#out + 1] = d end
            i = i + 2
        elseif c == "." then out[#out + 1] = "."; i = i + 1
        elseif c == "*" and #out > 0 then out[#out + 1] = "*"; i = i + 1
        elseif (c == "+" or c == "?") and ere and #out > 0 then out[#out + 1] = c; i = i + 1
        elseif c == "^" and i == 1 then out[#out + 1] = "^"; i = i + 1
        elseif c == "$" and i == n then out[#out + 1] = "$"; i = i + 1
        elseif c == "[" then
            local j = i + 1
            local set = { "[" }
            if re:sub(j, j) == "^" then set[#set + 1] = "^"; j = j + 1 end
            local first = true
            while j <= n and (re:sub(j, j) ~= "]" or first) do
                first = false
                local class = re:match("^%[:(%a+):%]", j)
                if class then
                    set[#set + 1] = CLASSES[class] or ""
                    j = j + #class + 4
                else
                    local ch = re:sub(j, j)
                    if opts.i then ch = ch:lower() end
                    set[#set + 1] = (ch == "%" and "%%") or (ch == "]" and "%]") or ch
                    j = j + 1
                end
            end
            if j > n then die("Unmatched [, [^, [:, [., or [=") end
            set[#set + 1] = "]"
            out[#out + 1] = table.concat(set)
            i = j + 1
        elseif (c == "(" or c == ")" or c == "{" or c == "}") and ere then
            die("'" .. c .. "' is not supported (use -F or simplify the pattern)")
        else
            lit(c)
            i = i + 1
        end
    end
    local pat = table.concat(out)
    if opts.x then
        if pat:sub(1, 1) ~= "^" then pat = "^" .. pat end
        if pat:sub(-1) ~= "$" or pat:sub(-2) == "%$" then pat = pat .. "$" end
    end
    return pat
end

local matchers = {}
for _, p in ipairs(patterns) do
    if opts.F then
        matchers[#matchers + 1] = { plain = opts.i and p:lower() or p }
    else
        local alts = {}
        if opts.E then
            for alt in (p .. "|"):gmatch("(.-)|") do alts[#alts + 1] = alt end
        else
            local from = 1
            while true do
                local s, e = p:find("\\|", from, true)
                if not s then alts[#alts + 1] = p:sub(from); break end
                alts[#alts + 1] = p:sub(from, s - 1)
                from = e + 1
            end
        end
        for _, alt in ipairs(alts) do
            local lua = translate(alt)
            matchers[#matchers + 1] = { lua = lua, anchored = lua:sub(1, 1) == "^" }
        end
    end
end

local function isWordByte(b) return b and (b == 95 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)) end

-- earliest (then longest) match at or after init: s, e
local function matchAt(line, init)
    local hay = opts.i and line:lower() or line
    local bs, be
    for _, m in ipairs(matchers) do
        local s, e
        if m.plain then
            if opts.x then
                if hay == m.plain then s, e = 1, #hay end
            else
                s, e = hay:find(m.plain, init, true)
            end
        elseif m.anchored and init > 1 then
            s = nil
        else
            s, e = hay:find(m.lua, init)
        end
        if s and (not bs or s < bs or (s == bs and e > be)) then bs, be = s, e end
    end
    return bs, be
end

-- a match that satisfies -w (checked on the original line)
local function findMatch(line, init)
    init = init or 1
    while init <= #line + 1 do
        local s, e = matchAt(line, init)
        if not s then return nil end
        if not opts.w
            or (not isWordByte(line:byte(s - 1)) and not isWordByte(line:byte(e + 1))) then
            return s, e
        end
        init = s + 1
    end
end

local ctxAfter = opts.A or opts.C or 0
local ctxBefore = opts.B or opts.C or 0
local filenames = (#files > 1 or recursive ~= nil)
if opts.H then filenames = true end
if opts.h then filenames = false end
local listOnly = opts.l or opts.L
local quietOut = opts.q or opts.c or listOnly
local anyMatch, status = false, 0
local printedGroup = false

local function prefix(name, n, sepc)
    return (filenames and (name .. sepc) or "") .. (opts.n and (n .. sepc) or "")
end

local function scan(name, readLine)
    local count, n = 0, 0
    local before = {}      -- ring of { n, line }
    local afterLeft = 0
    local lastPrinted = 0
    local stopping = false -- -m reached: only trailing context is left to print
    local function printLine(num, line, sepc)
        io.write(prefix(name, num, sepc), line, "\n")
        lastPrinted = num
    end
    while true do
        local line = readLine()
        if not line then break end
        n = n + 1
        local s, e = findMatch(line)
        local selected = (s ~= nil) ~= (opts.v ~= nil)
        if stopping then
            if afterLeft <= 0 or quietOut then break end
            printLine(n, line, "-")
            afterLeft = afterLeft - 1
            if afterLeft <= 0 then break end
        elseif selected then
            count = count + 1
            anyMatch = true
            if opts.q then os.exit(0) end
            if listOnly then break end
            if not quietOut then
                local useCtx = ctxAfter > 0 or ctxBefore > 0
                if useCtx then
                    local firstNum = before[1] and before[1][1] or n
                    if printedGroup and firstNum > lastPrinted + 1 then io.write("--\n") end
                    for _, b in ipairs(before) do printLine(b[1], b[2], "-") end
                    before = {}
                    printedGroup = true
                end
                if opts.o and not opts.v then
                    local init = 1
                    while s do
                        if e >= s then io.write(prefix(name, n, ":"), line:sub(s, e), "\n") end
                        init = math.max(e + 1, s + 1)
                        s, e = findMatch(line, init)
                    end
                else
                    printLine(n, line, ":")
                end
                afterLeft = ctxAfter
            end
            if opts.m and count >= opts.m then
                if afterLeft > 0 and not quietOut then stopping = true else break end
            end
        elseif not quietOut then
            if afterLeft > 0 then
                printLine(n, line, "-")
                afterLeft = afterLeft - 1
            elseif ctxBefore > 0 then
                before[#before + 1] = { n, line }
                if #before > ctxBefore then table.remove(before, 1) end
            end
        end
    end
    if opts.c then io.write(filenames and (name .. ":") or "", count, "\n") end
    if opts.l and count > 0 then io.write(name, "\n") end
    if opts.L and count == 0 then io.write(name, "\n") end
end

local function run(path)
    local function report(err)
        if not opts.s then io.stderr:write("grep: " .. path .. ": " .. tostring(err) .. "\n") end
        status = 2
    end
    if path ~= "-" and fs.isDirectory(path) then
        if not recursive then return report("Is a directory") end
        local iter, err = fs.list(path)
        if not iter then return report(err) end
        for entry in iter do
            run((path:gsub("/$", "")) .. "/" .. (entry:gsub("/$", "")))
        end
        return
    end
    local file, err = textio.open(path)
    if not file then return report(err) end
    local ok, e = pcall(scan, path == "-" and "(standard input)" or path, textio.reader(file))
    textio.close(file)
    if not ok then report(e) end
end

if #files == 0 then files = { "-" } end
for _, path in ipairs(files) do run(path) end
if status ~= 0 and not (opts.q and anyMatch) then return status end
return anyMatch and 0 or 1
