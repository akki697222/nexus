-- basename.lua - strip directory and suffix from file names
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   basename NAME [SUFFIX]
--   basename -a [-s SUFFIX] [-z] NAME ...

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("basename", "Print NAME with any leading directory components removed.")
parser:flag("-a --multiple", "support multiple arguments and treat each as a NAME")
parser:option("-s --suffix", "remove a trailing SUFFIX; implies -a"):argname("SUFFIX")
parser:flag("-z --zero", "end each output line with NUL, not newline")
parser:argument("name", "NAME [SUFFIX]"):args("+")

local opts = textio.parse("basename", parser, { ... })
local names, suffix = opts.name, opts.suffix

if not (opts.multiple or suffix) then
    if #names > 2 then
        textio.fail("basename", "extra operand '" .. names[3] .. "'")
    end
    suffix = names[2]
    names = { names[1] }
end

for _, name in ipairs(names) do
    local base = name:gsub("/+$", "")
    if base == "" and name ~= "" then base = "/" else base = base:match("([^/]*)$") end
    if suffix and suffix ~= "" and #base > #suffix and base:sub(-#suffix) == suffix then
        base = base:sub(1, #base - #suffix)
    end
    io.write(base, opts.zero and "\0" or "\n")
end
return 0
