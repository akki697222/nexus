-- tools/mkinstaller.lua - joins the installer sources into install.lua
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   lua tools/mkinstaller.lua [--plain] [out]
--       (from nexus/; default build/install.lua; --plain: not minified)
--
-- installer/src/prelude.lua comes first, as it is: the names the parts
-- share. Every part follows in a do ... end block of its own, as in
-- tools/kbuild.lua. Two parts come from other files so they exist once:
-- the CRC-32 and the zlib inflater are the {{shared blocks of
-- bootstrap/init.lua, and SHA-512 is src/lib/sha2.lua (password hashes
-- the kernel accepts). Lines starting with "---" are left out. The result
-- must compile, or nothing is written. `lua tools/nximg.lua dist` calls
-- build() for the release file.

local mkinstaller = {}

-- in this order; "bootstrap:<name>" is a {{shared block of bootstrap/init.lua
mkinstaller.PARTS = {
    "bootstrap:crc32",
    "bootstrap:softInflate",
    "src/lib/sha2.lua",
    "installer/src/meta.lua",
    "installer/src/util.lua",
    "installer/src/disk.lua",
    "installer/src/img.lua",
    "installer/src/net.lua",
    "installer/src/source.lua",
    "installer/src/install.lua",
    "installer/src/tui.lua",
    "installer/src/stage1.lua",
    "installer/src/stage0.lua",
    "installer/src/main.lua",
}

local function read(path)
    local file, err = io.open(path, "rb")
    if not file then error("cannot open " .. path .. ": " .. tostring(err), 0) end
    local text = file:read("a")
    file:close()
    return (text:gsub("\r\n", "\n"))
end

local function strip(text)
    local out = {}
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
        if not line:match("^%s*%-%-%-") then out[#out + 1] = line end
    end
    return table.concat(out, "\n") .. "\n"
end

local function shared(name)
    local text = read("bootstrap/init.lua")
    local block = text:match("%-%- {{shared " .. name .. "\n(.-)%-%- }}shared")
    if not block then error("bootstrap/init.lua has no {{shared " .. name .. " block", 0) end
    return block
end

-- What the minified file keeps of the comments: what it is and the
-- copyright notices of what it is made of.
mkinstaller.HEADER = [[
-- nexus-install.lua - Nexus installer, minified (tools/mkinstaller.lua)
-- built from installer/src of https://github.com/akki697222/nexus
-- Copyright (c) 2026 akki697222 - SPDX-License-Identifier: MIT
-- SHA-2: Copyright (c) 2018 Phil Leblanc, after Roberto Ierusalimschy - MIT
]]

-- Returns the installer source, minified (tools/minify.lua) unless
-- opts.plain: it has to fit OpenOS's 64 KB tmpfs.
function mkinstaller.build(opts)
    local parts = { strip(read("installer/src/prelude.lua")) }
    for _, part in ipairs(mkinstaller.PARTS) do
        local name = part:match("^bootstrap:(.+)$")
        local text = name and shared(name) or read(part)
        parts[#parts + 1] = "do -- " .. part .. "\n" .. strip(text) .. "end\n"
    end
    local source = table.concat(parts)
    if not (opts and opts.plain) then
        local minify = assert(loadfile("tools/minify.lua"))()
        source = mkinstaller.HEADER .. minify(source, true)
    end
    local ok, err = load(source, "=install.lua", "t", {})
    if not ok then error("the installer does not compile: " .. tostring(err), 0) end
    return source
end

if arg and arg[0] and arg[0]:match("mkinstaller%.lua$") then
    local plain = arg[1] == "--plain"
    local out = arg[plain and 2 or 1] or "build/install.lua"
    local ok, result = pcall(mkinstaller.build, { plain = plain })
    if not ok then
        io.stderr:write("mkinstaller: " .. tostring(result) .. "\n")
        os.exit(1)
    end
    local file = assert(io.open(out, "wb"))
    file:write(result)
    file:close()
    print(string.format("%s: %d bytes", out, #result))
end

return mkinstaller
