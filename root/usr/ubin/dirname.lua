-- dirname.lua - strip the last component from file names
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT

local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("dirname", "Output each NAME with its last non-slash component removed.")
parser:flag("-z --zero", "end each output line with NUL, not newline")
parser:argument("name", "path name"):args("+")

local opts = textio.parse("dirname", parser, { ... })

for _, name in ipairs(opts.name) do
    local p = name:gsub("/+$", "")
    if p == "" then
        p = name:sub(1, 1) == "/" and "/" or "."
    elseif not p:find("/", 1, true) then
        p = "."
    else
        p = p:gsub("/+[^/]*$", "")
        if p == "" then p = "/" end
    end
    io.write(p, opts.zero and "\0" or "\n")
end
return 0
