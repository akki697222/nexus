-- Tests for the NXIMG boot image: tools/nximg.lua and bootstrap/init.lua.
-- Run from nexus with: lua tests/image.lua
local nximg = assert(loadfile("tools/nximg.lua"))()
local libdeflate = assert(loadfile("tools/lib/libdeflate.lua"))()

local function read(path)
    local f = assert(io.open(path, "rb"))
    local v = f:read("a")
    f:close()
    return v
end

local init_source = read("bootstrap/init.lua")
local deflate = function(raw) return libdeflate:CompressZlib(raw, { level = 9 }) end
local inflate = function(z) return libdeflate:DecompressZlib(z) end

local function fs_section(entries)
    return nximg.encodeFs(entries)
end

local function make_image(kernel, options)
    options = options or {}
    return nximg.encode({
        { type = nximg.SECTION.kernel, data = kernel },
        { type = nximg.SECTION.usr, data = fs_section({
            { path = "bin", kind = nximg.FS_DIR, mode = tonumber("755", 8) },
            { path = "bin/sudo.lua", kind = nximg.FS_FILE, mode = tonumber("4755", 8), data = "return 1" },
        }) },
        { type = nximg.SECTION.etc, data = fs_section({
            { path = "sudoers", kind = nximg.FS_FILE, mode = tonumber("440", 8), data = "root ALL" },
        }) },
    }, { compression = options.compression or nximg.COMP_ZLIB,
         blockSize = options.blockSize or 1024, deflate = deflate })
end

-- Minimal OpenComputers environment: boot filesystem (reads capped at
-- 2048 bytes like OC's maxReadBuffer) and an optional data card.
local function boot(files, options)
    options = options or {}
    local handles, nh = {}, 0
    local inflate_calls = 0
    local component = {
        invoke = function(address, method, ...)
            local a = { ... }
            if address == "data" then
                assert(method == "inflate")
                inflate_calls = inflate_calls + 1
                return inflate(a[1])
            end
            assert(address == "boot")
            if method == "open" then
                local data = files[a[1]] or files["/" .. a[1]]
                if not data then return nil, "file not found" end
                nh = nh + 1
                handles[nh] = { data = data, pos = 1 }
                return nh
            elseif method == "seek" then
                assert(a[2] == "set")
                handles[a[1]].pos = a[3] + 1
                return a[3]
            elseif method == "read" then
                local h = handles[a[1]]
                if h.pos > #h.data then return nil end
                local n = math.min(a[2] == math.huge and #h.data or a[2], 2048)
                local s = h.data:sub(h.pos, h.pos + n - 1)
                h.pos = h.pos + #s
                return s
            elseif method == "close" then
                handles[a[1]] = nil
                return true
            end
            error("unexpected method " .. method)
        end,
        list = function(kind)
            assert(kind == "data")
            local done = not options.dataCard
            return function()
                if done then return nil end
                done = true
                return "data"
            end
        end,
    }
    local computer = { getBootAddress = function() return "boot" end }
    -- OC's component.invoke may yield (call budget); yielding inside the
    -- load() reader fails, so any invoke during load() is an error here.
    local loading = false
    local raw_invoke = component.invoke
    component.invoke = function(...)
        if loading then error("attempt to yield across a C-call boundary") end
        return raw_invoke(...)
    end
    local function guarded_load(...)
        loading = true
        local results = table.pack(pcall(load, ...))
        loading = false
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end
    local env = setmetatable({ component = component, computer = computer, load = guarded_load },
        { __index = _G })
    env._G = env
    local chunk = assert(load(init_source, "=init.lua", "t", env))
    local ok, err = pcall(chunk)
    return ok, err, env, inflate_calls
end

-- Kernel stub records its arguments and the loadfile it was given.
local stub = [[
KERNEL_ARGS = { ... }
KERNEL_LOADFILE = loadfile
return "booted"
]] .. string.rep("-- padding to span several blocks\n", 200)

-- 1. Compressed image boots via the data card and passes kernel args.
local image = make_image(stub)
local ok, err, env, calls = boot({ ["/boot/nexusos"] = image }, { dataCard = true })
assert(ok, err)
assert(env.KERNEL_ARGS[1] == "init=/usr/sbin/init.lua")
assert(env.KERNEL_ARGS[2] == "image=/boot/nexusos")
assert(type(env.KERNEL_LOADFILE) == "function", "kernel needs loadfile")
assert(calls == math.ceil(#stub / 1024), "one inflate per kernel block, got " .. calls)

-- 2. Compressed image without a data card is refused with a clear message.
ok, err = boot({ ["/boot/nexusos"] = image }, { dataCard = false })
assert(not ok and tostring(err):find("needs a data card", 1, true), err)

-- 3. Store image boots without a data card.
local store = make_image(stub, { compression = nximg.COMP_STORE })
ok, err, env, calls = boot({ ["/boot/nexusos"] = store }, { dataCard = false })
assert(ok, err)
assert(calls == 0 and env.KERNEL_ARGS[1] == "init=/usr/sbin/init.lua")

-- 4. Corruption is detected: header, index, store payload, zlib payload.
local function flip(s, pos)
    return s:sub(1, pos - 1) .. string.char(s:byte(pos) ~ 0x55) .. s:sub(pos + 1)
end
local info = nximg.parseHeader(image)
ok, err = boot({ ["/boot/nexusos"] = flip(image, 10) }, { dataCard = true })
assert(not ok and tostring(err):find("header checksum", 1, true), err)
ok, err = boot({ ["/boot/nexusos"] = flip(image, 40) }, { dataCard = true })
assert(not ok and tostring(err):find("index checksum", 1, true), err)
ok, err = boot({ ["/boot/nexusos"] = flip(store, info.dataOffset + 300) }, { dataCard = false })
assert(not ok and tostring(err):find("checksum mismatch", 1, true), err)
ok = boot({ ["/boot/nexusos"] = flip(image, info.dataOffset + 30) }, { dataCard = true })
assert(not ok, "corrupt zlib block must not boot")

-- 5. Truncated image and missing image.
-- (the loader reads only the kernel section, so cut inside its blocks)
ok, err = boot({ ["/boot/nexusos"] = image:sub(1, info.dataOffset + 100) }, { dataCard = true })
assert(not ok and tostring(err):find("truncated image", 1, true), err)
ok, err = boot({}, { dataCard = true })
assert(not ok and tostring(err):find("cannot open", 1, true), err)

-- 6. The real kernel streams through the loader and compiles.
local real = read("build/kernel.lua")
local real_image = make_image(real, { blockSize = nximg.DEFAULT_BLOCK })
ok, err = boot({ ["/boot/nexusos"] = real_image }, { dataCard = true })
-- Running the real kernel fails in this mock; it must fail *inside* the
-- kernel (after loading), not in the loader.
assert(not ok and not tostring(err):find("^nexusos:"), "loader rejected the real kernel: " .. tostring(err))

-- 7. Host side: sections, NXFS metadata and attributes round-trip.
info = nximg.parseHeader(image)
local usr = nximg.decodeFs(nximg.readSection(image, info, nximg.findSection(info, nximg.SECTION.usr), inflate))
assert(#usr == 2 and usr[2].path == "bin/sudo.lua" and usr[2].mode == tonumber("4755", 8))
local etc_raw = nximg.readSection(image, info, nximg.findSection(info, nximg.SECTION.etc), inflate)
local etc = nximg.decodeFs(etc_raw)
assert(etc[1].mode == tonumber("440", 8))
assert(etc_raw:sub(etc[1].offset + 1, etc[1].offset + etc[1].size) == "root ALL")
assert(nximg.readSection(image, info, nximg.findSection(info, nximg.SECTION.kernel), inflate) == stub)

-- 8. Every zlib block is a standalone stream (what the data card expects).
for i = 0, info.blockCount - 1 do
    local z = image:sub(info.dataOffset + info.index[i] + 1, info.dataOffset + info.index[i + 1])
    assert(z:byte(1) == 0x78, "block " .. i .. " lacks a zlib header")
    assert(inflate(z), "block " .. i .. " does not inflate on its own")
end

io.write("image tests passed\n")
