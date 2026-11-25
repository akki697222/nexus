-- tools/nximg.lua - build and inspect Nexus boot images (NXIMG)
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Host-side tool (Lua 5.3+). Run from the nexus root:
--   lua tools/nximg.lua build  <out> [--kernel f] [--usr dir] [--etc dir]
--                                    [--store] [--block n] [--lib f] [--attrs f]
--                                    [--sections kernel,usr,etc]
--   lua tools/nximg.lua info    <image> [usr|etc]
--   lua tools/nximg.lua verify  <image> [--lib f]
--   lua tools/nximg.lua extract <image> <kernel|usr|etc> <dest> [--lib f]
--   lua tools/nximg.lua dist    <dir> [build options]
--       the files nexus-install installs from:
--       nexusos            kernel only (boot image, /boot/nexusos)
--       rootfs             usr and etc sections (unpacked onto the disk)
--       init.lua           bootstrap/init.lua (/init.lua)
--       config.lua         root/boot/config.lua (/boot/config.lua)
--       nexus-install.lua  the installer (tools/mkinstaller.lua)
--       manifest.lua       sizes, checksums and optional groups
--   lua tools/nximg.lua media   <dist dir> <out dir>
--       an install medium: <out>/init.lua is the installer and
--       <out>/.nexus-install/ holds the distribution (offline install)
--
-- Image layout (all integers little endian)
--
--   header (32 bytes)
--     0  "NXIMG\0"
--     6  version u8 (1)
--     7  compression u8   0 = store, 1 = zlib
--     8  block size u32   uncompressed bytes per block
--    12  section count u16
--    14  reserved u16
--    16  block count u32
--    20  data offset u32  file offset of block 0
--    24  crc32 u32        of bytes [32, data offset): section table + index
--    28  crc32 u32        of bytes [0, 28)
--
--   section table: count x 24 bytes
--     type u8 (1 kernel, 2 usr, 3 etc) | flags u8 | reserved u16
--     | raw size u32 | first block u32 | block count u32 | crc32 u32
--     | reserved u32
--
--   block index: (block count + 1) x u32, offsets relative to data offset;
--   block i is [index[i], index[i + 1]).
--
--   blocks: every section starts on a new block and is cut into
--   block-size pieces. With zlib each block is a complete zlib stream, so
--   an OpenComputers data card can inflate it as is (data.inflate).
--
-- Filesystem sections (usr, etc) hold an NXFS tree:
--   "NXFS" | version u8 (1) | reserved u8 x3 | entry count u32 | toc size u32
--   entry: pathlen u16 | type u8 (1 file, 2 dir) | reserved u8
--          | mode u16 | uid u16 | gid u16 | reserved u16
--          | offset u32 (from section start) | size u32 | path
-- Paths are relative to the mount point, "/"-separated, sorted, without a
-- leading or trailing "/". File data follows the TOC, in TOC order.

local nximg = {}

nximg.MAGIC = "NXIMG\0"
nximg.VERSION = 1
nximg.HEADER_SIZE = 32
nximg.SECTION_SIZE = 24
nximg.COMP_STORE = 0
nximg.COMP_ZLIB = 1
nximg.SECTION = { kernel = 1, usr = 2, etc = 3 }
nximg.SECTION_NAME = { [1] = "kernel", [2] = "usr", [3] = "etc" }
nximg.FS_MAGIC = "NXFS"
nximg.FS_FILE = 1
nximg.FS_DIR = 2
nximg.DEFAULT_BLOCK = 16384

local function u16(n) return string.pack("<I2", n) end
local function u32(n) return string.pack("<I4", n) end

local crc_table = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if crc & 1 == 1 then crc = (crc >> 1) ~ 0xEDB88320 else crc = crc >> 1 end
    end
    crc_table[i] = crc
end

function nximg.crc32(data, crc)
    crc = (crc or 0) ~ 0xFFFFFFFF
    for i = 1, #data do
        crc = crc_table[(crc ~ data:byte(i)) & 0xFF] ~ (crc >> 8)
    end
    return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

local function octal(s) return tonumber(s, 8) end

-- Default ownership/mode rules; paths are absolute (as mounted).
-- An --attrs file returns { ["/usr/bin/x.lua"] = { mode = "0755", uid = 0, gid = 0 } }.
nximg.DEFAULT_ATTRS = {
    ["/usr/bin/sudo.lua"] = { mode = "4755" },
    ["/etc/sudoers"] = { mode = "0440" },
}

local function default_mode(abs, kind)
    if kind == nximg.FS_DIR then return octal("0755") end
    if abs:match("^/usr/s?bin/") or abs:match("^/usr/ubin/") then return octal("0755") end
    return octal("0644")
end

---------------------------------------------------------------------------
-- NXFS (filesystem section) encoding / decoding
---------------------------------------------------------------------------

-- entries: { { path = "bin/sh.lua", kind = 1|2, data = "...", mode, uid, gid } }
function nximg.encodeFs(entries)
    table.sort(entries, function(a, b) return a.path < b.path end)
    local toc_size = 16
    for _, e in ipairs(entries) do
        if #e.path == 0 or #e.path > 65535 then error("bad path length: " .. e.path) end
        toc_size = toc_size + 20 + #e.path
    end
    local toc = { nximg.FS_MAGIC, string.char(1, 0, 0, 0), u32(#entries), u32(toc_size) }
    local data, offset = {}, toc_size
    for _, e in ipairs(entries) do
        local size = e.kind == nximg.FS_FILE and #e.data or 0
        toc[#toc + 1] = u16(#e.path) .. string.char(e.kind, 0)
            .. u16(e.mode) .. u16(e.uid or 0) .. u16(e.gid or 0) .. u16(0)
            .. u32(size > 0 and offset or 0) .. u32(size) .. e.path
        if size > 0 then
            data[#data + 1] = e.data
            offset = offset + size
        end
    end
    return table.concat(toc) .. table.concat(data)
end

function nximg.decodeFs(raw)
    if raw:sub(1, 4) ~= nximg.FS_MAGIC then error("not an NXFS section", 0) end
    if raw:byte(5) ~= 1 then error("unsupported NXFS version", 0) end
    local count, toc_size = string.unpack("<I4I4", raw, 9)
    local entries, pos = {}, 17
    for _ = 1, count do
        local pathlen, kind, _, mode, uid, gid, _, offset, size =
            string.unpack("<I2BBI2I2I2I2I4I4", raw, pos)
        pos = pos + 20
        local path = raw:sub(pos, pos + pathlen - 1)
        pos = pos + pathlen
        entries[#entries + 1] = { path = path, kind = kind, mode = mode, uid = uid,
            gid = gid, offset = offset, size = size }
    end
    if pos - 1 ~= toc_size then error("NXFS toc size mismatch", 0) end
    return entries
end

---------------------------------------------------------------------------
-- Image encoding / decoding
---------------------------------------------------------------------------

-- sections: { { type = n, data = "raw" } }, options: { compression, blockSize, deflate }
-- deflate(raw) must return a complete zlib stream.
function nximg.encode(sections, options)
    local comp = options.compression or nximg.COMP_ZLIB
    local bs = options.blockSize or nximg.DEFAULT_BLOCK
    if bs < 512 or bs > 65536 then error("block size must be 512..65536") end
    local table_parts, blocks, index = {}, {}, { 0 }
    local offset = 0
    for _, section in ipairs(sections) do
        local raw = section.data
        local first, n = #blocks, 0
        for pos = 1, math.max(#raw, 1), bs do
            local piece = raw:sub(pos, pos + bs - 1)
            if #piece == 0 then break end
            local stored = piece
            if comp == nximg.COMP_ZLIB then
                stored = assert(options.deflate(piece), "deflate failed")
            end
            blocks[#blocks + 1] = stored
            offset = offset + #stored
            index[#index + 1] = offset
            n = n + 1
        end
        table_parts[#table_parts + 1] = string.char(section.type, 0) .. u16(0)
            .. u32(#raw) .. u32(first) .. u32(n) .. u32(nximg.crc32(raw)) .. u32(0)
    end
    local index_parts = {}
    for i, v in ipairs(index) do index_parts[i] = u32(v) end
    local meta = table.concat(table_parts) .. table.concat(index_parts)
    local data_offset = nximg.HEADER_SIZE + #meta
    local head = nximg.MAGIC .. string.char(nximg.VERSION, comp) .. u32(bs)
        .. u16(#sections) .. u16(0) .. u32(#blocks) .. u32(data_offset) .. u32(nximg.crc32(meta))
    head = head .. u32(nximg.crc32(head))
    return head .. meta .. table.concat(blocks)
end

-- Parses header, section table and index from the start of an image.
function nximg.parseHeader(image)
    if #image < nximg.HEADER_SIZE or image:sub(1, 6) ~= nximg.MAGIC then
        error("not a Nexus boot image", 0)
    end
    local version, comp, bs, nsec, _, nblocks, data_offset, meta_crc, head_crc =
        string.unpack("<BBI4I2I2I4I4I4I4", image, 7)
    if version ~= nximg.VERSION then error("unsupported image version " .. version, 0) end
    if nximg.crc32(image:sub(1, 28)) ~= head_crc then error("header checksum mismatch", 0) end
    if #image < data_offset then error("truncated image header", 0) end
    if nximg.crc32(image:sub(33, data_offset)) ~= meta_crc then error("index checksum mismatch", 0) end
    local info = { compression = comp, blockSize = bs, blockCount = nblocks,
        dataOffset = data_offset, sections = {}, index = {} }
    local pos = 33
    for _ = 1, nsec do
        local typ, flags, _, raw, first, n, crc = string.unpack("<BBI2I4I4I4I4", image, pos)
        info.sections[#info.sections + 1] = { type = typ, flags = flags, rawSize = raw,
            firstBlock = first, blockCount = n, crc = crc }
        pos = pos + nximg.SECTION_SIZE
    end
    for i = 0, nblocks do
        info.index[i] = string.unpack("<I4", image, pos)
        pos = pos + 4
    end
    return info
end

function nximg.findSection(info, typ)
    for _, s in ipairs(info.sections) do
        if s.type == typ then return s end
    end
end

-- inflate(zlibStream) -> raw; only needed for compressed images.
function nximg.readSection(image, info, section, inflate)
    local parts = {}
    for i = section.firstBlock, section.firstBlock + section.blockCount - 1 do
        local a, b = info.index[i], info.index[i + 1]
        local stored = image:sub(info.dataOffset + a + 1, info.dataOffset + b)
        if #stored ~= b - a then error("truncated image data", 0) end
        local raw = stored
        if info.compression == nximg.COMP_ZLIB then
            raw = inflate(stored)
            if type(raw) ~= "string" then error("cannot inflate block " .. i, 0) end
        end
        local last = i == section.firstBlock + section.blockCount - 1
        local want = last and (section.rawSize - (section.blockCount - 1) * info.blockSize)
            or info.blockSize
        if #raw ~= want then error("block " .. i .. " has wrong size", 0) end
        parts[#parts + 1] = raw
    end
    local raw = table.concat(parts)
    if nximg.crc32(raw) ~= section.crc then
        error(nximg.SECTION_NAME[section.type] .. " section checksum mismatch", 0)
    end
    return raw
end

---------------------------------------------------------------------------
-- Command line
---------------------------------------------------------------------------

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("cannot read " .. path .. ": " .. tostring(err), 0) end
    local data = f:read("a")
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then error("cannot write " .. path .. ": " .. tostring(err), 0) end
    f:write(data)
    f:close()
end

local windows = package.config:sub(1, 1) == "\\"

local function list_tree(dir)
    local function run(command)
        local pipe = assert(io.popen(command, "r"))
        local out = {}
        for line in pipe:lines() do out[#out + 1] = (line:gsub("\\", "/"):gsub("\r$", "")) end
        pipe:close()
        return out
    end
    local base
    if windows then
        base = run('cd /d "' .. dir .. '" && cd')[1]
    else
        base = run('cd "' .. dir .. '" && pwd')[1]
    end
    if not base then error("cannot open directory " .. dir, 0) end
    base = base:gsub("/+$", "")
    local dirs, files
    if windows then
        dirs = run('dir /b /s /ad "' .. base .. '" 2>nul')
        files = run('dir /b /s /a-d "' .. base .. '" 2>nul')
    else
        dirs = run('find "' .. base .. '" -mindepth 1 -type d 2>/dev/null')
        files = run('find "' .. base .. '" -type f 2>/dev/null')
    end
    local function rel(p)
        if p:sub(1, #base + 1) == base .. "/" then return p:sub(#base + 2) end
    end
    local result = {}
    for _, p in ipairs(dirs) do
        local r = rel(p)
        if r then result[#result + 1] = { path = r, kind = nximg.FS_DIR } end
    end
    for _, p in ipairs(files) do
        local r = rel(p)
        if r then result[#result + 1] = { path = r, kind = nximg.FS_FILE, host = p } end
    end
    return result
end

local function build_fs(dir, mount, attrs)
    local entries = list_tree(dir)
    for _, e in ipairs(entries) do
        local abs = mount .. "/" .. e.path
        local a = attrs[abs] or {}
        e.mode = a.mode and (type(a.mode) == "string" and octal(a.mode) or a.mode)
            or default_mode(abs, e.kind)
        e.uid, e.gid = a.uid or 0, a.gid or 0
        if e.kind == nximg.FS_FILE then e.data = read_file(e.host) end
    end
    return nximg.encodeFs(entries), #entries
end

local function load_libdeflate(path)
    local candidates = path and { path } or { "tools/lib/libdeflate.lua" }
    for _, p in ipairs(candidates) do
        local chunk = loadfile(p)
        if chunk then return chunk() end
    end
    error("LibDeflate not found (tried " .. table.concat(candidates, ", ") .. "); pass --lib", 0)
end

local function parse_options(args, first)
    local opts, positional = {}, {}
    local i = first
    while i <= #args do
        local a = args[i]
        if a == "--store" then
            opts.store = true
        elseif a:sub(1, 2) == "--" then
            opts[a:sub(3)] = assert(args[i + 1], a .. " needs a value")
            i = i + 1
        else
            positional[#positional + 1] = a
        end
        i = i + 1
    end
    return opts, positional
end

local function cmd_build(args)
    local opts, pos = parse_options(args, 2)
    local out = assert(pos[1], "usage: nximg build <out> [options]")
    local attrs = {}
    for k, v in pairs(nximg.DEFAULT_ATTRS) do attrs[k] = v end
    if opts.attrs then
        for k, v in pairs(assert(loadfile(opts.attrs))()) do attrs[k] = v end
    end
    local kernel = read_file(opts.kernel or "build/kernel.lua")
    -- refresh the driver index the kernel's devmgr requires
    local depmod = assert(loadfile("tools/depmod.lua"))()
    if not depmod.run((opts.usr or "root/usr") .. "/lib/drivers", nil, true) then
        error("depmod failed", 0)
    end
    local wanted = {}
    for name in (opts.sections or "kernel,usr,etc"):gmatch("[^,]+") do
        if not nximg.SECTION[name] then error("unknown section " .. name, 0) end
        wanted[name] = true
    end
    local sections, report = {}, {}
    if wanted.kernel then
        sections[#sections + 1] = { type = nximg.SECTION.kernel, data = kernel }
        report[#report + 1] = string.format("kernel %d B", #kernel)
    end
    for _, name in ipairs({ "usr", "etc" }) do
        if wanted[name] then
            local raw, n = build_fs(opts[name] or ("root/" .. name), "/" .. name, attrs)
            sections[#sections + 1] = { type = nximg.SECTION[name], data = raw }
            report[#report + 1] = string.format("%s %d entries %d B", name, n, #raw)
        end
    end
    if #sections == 0 then error("no sections", 0) end
    local comp = opts.store and nximg.COMP_STORE or nximg.COMP_ZLIB
    local deflate
    if comp == nximg.COMP_ZLIB then
        local lib = load_libdeflate(opts.lib)
        deflate = function(raw) return lib:CompressZlib(raw, { level = 9 }) end
    end
    local image = nximg.encode(sections,
        { compression = comp, blockSize = tonumber(opts.block) or nximg.DEFAULT_BLOCK, deflate = deflate })
    write_file(out, image)
    print(string.format("%s: %s, %s -> %d B", out, comp == 1 and "zlib" or "store",
        table.concat(report, ", "), #image))
    return image
end

local function open_image(path, libpath)
    local image = read_file(path)
    local info = nximg.parseHeader(image)
    local inflate
    if info.compression == nximg.COMP_ZLIB then
        local lib
        inflate = function(z)
            lib = lib or load_libdeflate(libpath)
            return lib:DecompressZlib(z)
        end
    end
    return image, info, inflate
end

local function mode_string(mode)
    return string.format("%04o", mode)
end

local function cmd_info(args)
    local opts, pos = parse_options(args, 2)
    local image, info, inflate = open_image(assert(pos[1], "usage: nximg info <image> [usr|etc]"), opts.lib)
    print(string.format("NXIMG v%d  %s  block %d  %d blocks  data @%d  %d bytes",
        nximg.VERSION, info.compression == 1 and "zlib" or "store", info.blockSize,
        info.blockCount, info.dataOffset, #image))
    for _, s in ipairs(info.sections) do
        local stored = info.index[s.firstBlock + s.blockCount] - info.index[s.firstBlock]
        print(string.format("  %-6s raw %7d  stored %7d  blocks %3d+%-3d crc %08x",
            nximg.SECTION_NAME[s.type] or ("#" .. s.type), s.rawSize, stored,
            s.firstBlock, s.blockCount, s.crc))
    end
    if pos[2] then
        local s = assert(nximg.findSection(info, nximg.SECTION[pos[2]]), "no section " .. pos[2])
        for _, e in ipairs(nximg.decodeFs(nximg.readSection(image, info, s, inflate))) do
            print(string.format("  %s %s %4d:%-4d %7d  %s", e.kind == nximg.FS_DIR and "d" or "-",
                mode_string(e.mode), e.uid, e.gid, e.size, e.path))
        end
    end
end

local function cmd_verify(args)
    local opts, pos = parse_options(args, 2)
    local image, info, inflate = open_image(assert(pos[1], "usage: nximg verify <image>"), opts.lib)
    if info.index[info.blockCount] + info.dataOffset ~= #image then
        error("image size does not match its index", 0)
    end
    for _, s in ipairs(info.sections) do
        local raw = nximg.readSection(image, info, s, inflate)
        if s.type ~= nximg.SECTION.kernel then nximg.decodeFs(raw) end
        print("ok " .. (nximg.SECTION_NAME[s.type] or s.type))
    end
end

local function cmd_extract(args)
    local opts, pos = parse_options(args, 2)
    local path, name, dest = pos[1], pos[2], pos[3]
    assert(path and name and dest, "usage: nximg extract <image> <kernel|usr|etc> <dest>")
    local image, info, inflate = open_image(path, opts.lib)
    local s = assert(nximg.findSection(info, nximg.SECTION[name]), "no section " .. name)
    local raw = nximg.readSection(image, info, s, inflate)
    if s.type == nximg.SECTION.kernel then
        write_file(dest, raw)
        return
    end
    local function mkdir(p)
        if windows then
            os.execute('if not exist "' .. p:gsub("/", "\\") .. '" mkdir "' .. p:gsub("/", "\\") .. '"')
        else
            os.execute('mkdir -p "' .. p .. '"')
        end
    end
    mkdir(dest)
    for _, e in ipairs(nximg.decodeFs(raw)) do
        local target = dest .. "/" .. e.path
        if e.kind == nximg.FS_DIR then
            mkdir(target)
        else
            write_file(target, raw:sub(e.offset + 1, e.offset + e.size))
        end
    end
end

local function mkdir_p(p)
    if windows then
        os.execute('if not exist "' .. p:gsub("/", "\\") .. '" mkdir "' .. p:gsub("/", "\\") .. '"')
    else
        os.execute('mkdir -p "' .. p .. '"')
    end
end

-- The installer's revision, from installer/src/prelude.lua.
local function installer_rev()
    local rev = read_file("installer/src/prelude.lua"):match("local INSTALLER_REV = (%d+)")
    return tonumber((assert(rev, "INSTALLER_REV not found in installer/src/prelude.lua")))
end

-- Serializes plain data (strings, numbers, booleans, tables) as Lua.
local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then error("cannot serialize " .. t) end
    local inner = indent .. "    "
    local parts = {}
    local n = #v
    for i = 1, n do parts[#parts + 1] = inner .. serialize(v[i], inner) .. ",\n" end
    local keys = {}
    for k in pairs(v) do
        if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = inner .. k .. " = " .. serialize(v[k], inner) .. ",\n"
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts) .. indent .. "}"
end
nximg.serialize = serialize

-- Optional groups for the manifest: installer/groups.lua and one group per
-- driver of drivers.idx. Paths that are not in the rootfs are dropped, and
-- groups left without a path.
local function manifest_groups(usr_dir, etc_dir)
    local present = {}
    for _, e in ipairs(list_tree(usr_dir)) do present["usr/" .. e.path] = true end
    for _, e in ipairs(list_tree(etc_dir)) do present["etc/" .. e.path] = true end
    local groups = {}
    for _, g in ipairs(assert(loadfile("installer/groups.lua"))()) do
        local paths = {}
        for _, p in ipairs(g.paths) do
            if present[p] then paths[#paths + 1] = p end
        end
        if #paths > 0 then
            groups[#groups + 1] = { id = g.id, name = g.name, desc = g.desc, default = g.default ~= false,
                paths = paths, modules = g.modules }
        end
    end
    local index = assert(loadfile(usr_dir .. "/lib/drivers/drivers.idx", "t", {}))()
    for _, d in ipairs(index.drivers) do
        local path = d.path:gsub("^/", "")
        if present[path] then
            groups[#groups + 1] = { id = "driver:" .. d.name, name = d.desc or d.name, default = true,
                paths = { path }, drivers = { d.path }, devgroup = d.group }
        end
    end
    return groups
end

local function cmd_dist(args)
    local dir = assert(args[2], "usage: nximg dist <dir> [build options]")
    local opts = parse_options(args, 3)
    mkdir_p(dir)
    local passthrough = {}
    for i = 3, #args do passthrough[#passthrough + 1] = args[i] end
    local function build(out, sections)
        local a = { "build", out }
        for _, v in ipairs(passthrough) do a[#a + 1] = v end
        a[#a + 1] = "--sections"
        a[#a + 1] = sections
        return cmd_build(a)
    end
    local kernelImage = build(dir .. "/nexusos", "kernel")
    local rootfs = build(dir .. "/rootfs", "usr,etc")
    local info = nximg.parseHeader(rootfs)
    local unpacked = 0
    for _, sec in ipairs(info.sections) do unpacked = unpacked + sec.rawSize end

    local mkinstaller = assert(loadfile("tools/mkinstaller.lua"))()
    local installer = mkinstaller.build()
    local files = {
        { name = "nexusos", role = "kernel", data = kernelImage },
        { name = "rootfs", role = "rootfs", data = rootfs },
        { name = "init.lua", role = "boot", data = read_file("bootstrap/init.lua") },
        { name = "config.lua", role = "config", data = read_file("root/boot/config.lua") },
        { name = "nexus-install.lua", role = "installer", data = installer },
    }
    local config = assert(loadfile("root/boot/config.lua"))()
    local manifest = {
        format = 1,
        installer = installer_rev(),
        version = config.kernel_version.ver,
        -- bytes the installed system takes, about (files without .meta)
        installed = #kernelImage + unpacked + #files[3].data + #files[4].data,
        -- the kernel uncompressed (an uncompressed /boot/nexusos is about this)
        kernelRaw = nximg.parseHeader(kernelImage).sections[1].rawSize,
        files = {},
        groups = manifest_groups(opts.usr or "root/usr", opts.etc or "root/etc"),
    }
    for _, f in ipairs(files) do
        write_file(dir .. "/" .. f.name, f.data)
        manifest.files[#manifest.files + 1] = { name = f.name, role = f.role, size = #f.data,
            crc32 = nximg.crc32(f.data) }
    end
    write_file(dir .. "/manifest.lua",
        "-- generated by tools/nximg.lua dist; do not edit\nreturn " .. serialize(manifest) .. "\n")
    print(dir .. ": nexusos, rootfs, init.lua, config.lua, nexus-install.lua, manifest.lua")
end

-- An install medium from a dist directory: the installer as /init.lua and
-- the distribution in /.nexus-install, for an offline install from any disk
-- (a floppy fits).
local function cmd_media(args)
    local dist, out = args[2], args[3]
    assert(dist and out, "usage: nximg media <dist dir> <out dir>")
    local manifest_text = read_file(dist .. "/manifest.lua")
    local manifest = assert(load(manifest_text, "=manifest", "t", {}))()
    mkdir_p(out .. "/.nexus-install")
    local total = #manifest_text
    for _, f in ipairs(manifest.files) do
        local data = read_file(dist .. "/" .. f.name)
        if f.role == "installer" then
            write_file(out .. "/init.lua", data)
        else
            write_file(out .. "/.nexus-install/" .. f.name, data)
        end
        total = total + #data
    end
    write_file(out .. "/.nexus-install/manifest.lua", manifest_text)
    print(string.format("%s: install medium, %d bytes", out, total))
end

-- Writes the .meta files of a deployed tree (build.lua copies root/ to a
-- development disk): one per directory below `mount`, with the same modes
-- and owners an image or the installer would give. The .meta of the
-- parent of `mount` is left alone.
function nximg.deployMeta(src, dest, mount, attrs)
    attrs = attrs or nximg.DEFAULT_ATTRS
    local env = { string = string, math = math, table = table, pairs = pairs, ipairs = ipairs }
    assert(loadfile("installer/src/meta.lua", "t", env))()
    local set = env.meta.new()
    for _, e in ipairs(list_tree(src)) do
        local abs = mount .. "/" .. e.path
        local a = attrs[abs] or {}
        local mode = a.mode and (type(a.mode) == "string" and octal(a.mode) or a.mode) or default_mode(abs, e.kind)
        set.add(abs, e.kind == nximg.FS_DIR, mode, a.uid or 0, a.gid or 0)
    end
    local count = 0
    set.each(os.time(), function(dir, text)
        if dir == mount or dir:sub(1, #mount + 1) == mount .. "/" then
            local target = dest .. dir:sub(#mount + 1)
            local probe = io.open(target .. "/.meta", "ab")
            if probe then probe:close() else mkdir_p(target) end
            write_file(target .. "/.meta", text)
            count = count + 1
        end
    end)
    return count
end

local commands = { build = cmd_build, info = cmd_info, verify = cmd_verify, extract = cmd_extract,
    dist = cmd_dist, media = cmd_media }

-- For build.lua: run a subcommand with an argv-style table, e.g.
-- nximg.run({ "build", "out/nexusos", "--store" }). Errors are raised.
function nximg.run(args)
    local command = commands[args[1] or ""]
    if not command then error("unknown command " .. tostring(args[1]), 0) end
    return command(args)
end

-- Run as a script only when this file is the program (not when loaded by a test).
if arg and arg[0] and arg[0]:match("nximg%.lua$") then
    local command = commands[arg[1] or ""]
    if not command then
        io.stderr:write("usage: lua tools/nximg.lua <build|info|verify|extract|dist|media> ...\n")
        os.exit(1)
    end
    local ok, err = pcall(command, arg)
    if not ok then
        io.stderr:write("nximg: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

return nximg
