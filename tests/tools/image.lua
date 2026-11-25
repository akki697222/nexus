-- Tests for the NXIMG boot image: tools/nximg.lua and bootstrap/init.lua.
-- Run from nexus with: lua tests/tools/image.lua
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
            if address == "gpu" then
                local g = options.gpu
                g.calls[#g.calls + 1] = method
                if method == "getResolution" then return g.w, g.h end
                if method == "setResolution" then g.res = { a[1], a[2] } end
                if method == "set" then g.rows[a[2]] = a[3] end
                if method == "fill" and a[5] == " " then
                    for row = a[2], a[2] + a[4] - 1 do g.rows[row] = nil end
                end
                return true
            end
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
            local present = (kind == "data" and options.dataCard)
                or ((kind == "gpu" or kind == "screen") and options.gpu)
            assert(kind == "data" or kind == "gpu" or kind == "screen", kind)
            local done = not present
            return function()
                if done then return nil end
                done = true
                return kind
            end
        end,
    }
    local computer = { getBootAddress = function() return "boot" end,
        pullSignal = function() options.yields = (options.yields or 0) + 1 end }
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

-- 1b. With a GPU and screen, a progress bar is drawn per block, never from
-- inside load(), and only when the bar changes.
-- The boot screen is 50x16, which every GPU tier supports: the bar sits
-- on row 9 and the title two rows above it.
local gpu = { w = 80, h = 25, calls = {}, rows = {} }
ok, err = boot({ ["/boot/nexusos"] = image }, { dataCard = true, gpu = gpu })
assert(ok, err)
assert(gpu.calls[1] == "bind")
assert(gpu.res and gpu.res[1] == 50 and gpu.res[2] == 16, "boot screen resolution")
local bar = gpu.rows[9]
assert(bar and bar:find("100%", 1, true) and not bar:find("\u{2591}"), tostring(bar))
assert(gpu.rows[7]:find("Starting kernel", 1, true), tostring(gpu.rows[7]))
local sets = 0
for _, m in ipairs(gpu.calls) do if m == "set" then sets = sets + 1 end end
assert(sets <= calls + 4, "redraws only on change: " .. sets)
-- every row fits the 50 columns of the boot screen
for _, row in pairs(gpu.rows) do
    local cells = select(2, row:gsub("[^\128-\191]", ""))
    assert(cells <= 50, "row wider than the screen: " .. row)
end

-- 2. Without a data card a compressed image is inflated in Lua, yielding
-- between blocks, and the inflater is handed to the kernel.
local info0 = nximg.parseHeader(image)
local noCard = { dataCard = false }
ok, err, env, calls = boot({ ["/boot/nexusos"] = image }, noCard)
assert(ok, err)
assert(calls == 0 and env.KERNEL_ARGS[1] == "init=/usr/sbin/init.lua")
assert(noCard.yields == math.ceil(#stub / 1024), "one yield per block, got " .. tostring(noCard.yields))
local soft = assert(env.NEXUS_INFLATE, "loader passes its inflater to the kernel")

-- 2b. The Lua inflater against LibDeflate at every level (stored, fixed
-- and dynamic blocks) and against real zlib output.
local function pseudo(n, seed)
    local t, x = {}, seed
    for i = 1, n do
        x = (x * 1103515245 + 12345) % 2147483648
        t[i] = string.char(x % 256)
    end
    return table.concat(t)
end
local text = {}
for i = 0, 3999 do text[#text + 1] = string.char(32 + (i * 7 + (i // 13) * 3) % 90) end
text = table.concat(text) .. string.rep("the quick brown fox ", 50)
local samples = { "", "a", "hello hello hello hello world", pseudo(3000, 7), text,
    string.rep("x", 16384), init_source:sub(1, 16384),
    pseudo(26000, 3) .. pseudo(26000, 3):sub(1, 3000) } -- distances past 24576
for _, sample in ipairs(samples) do
    for level = 0, 9 do
        local z = libdeflate:CompressZlib(sample, { level = level })
        assert(soft(z) == sample, "level " .. level .. ", " .. #sample .. " bytes")
    end
end
local function unhex(h) return (h:gsub("..", function(c) return string.char(tonumber(c, 16)) end)) end
assert(soft(unhex("78012bc9ccab542849ad280100124003aa")) == "tiny text")
assert(soft(unhex("78daed925b5741611445ffcaa7120a118aa20845288aa228b7c3396ec735fcfbbefdb2c77aefadb15fd7c31c6bcc3195cb1f89a71f2bf5efc1747d747a1e4b3e3cd59abdd162e73ebb48640a2f8df670b639f086ae52b9e7b7567fbcdc1f072e6fb2c5d78f8e69ff1c9e84afeff2e5f72f63b2522e7ff4f6be54fdec5af3ad4631d6a1518c756a14633d1ac5589f463136a8518ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca5878ca587e0d3e1069f4e2ff8f404c0a72f0c3e8351f0198983cf58127c2632e03395039fd922f8cc97c167a90a3e2b75f0596b82cf461b7cb6fae0b363824f63023eadb99290242409494292902424094942929024240949429290fe12d2da34d46263f5c6aabbb4b73335b0774a36d964fb5fdb2f25b61935")) == text, "zlib -9")
assert(soft(unhex("7801ed97c952c24010865f65109020010204088b80a8b8e38afb0a8220124c4c20bcbdd53393ae397ab6fa9ac357ffd7dd99e961894cb1be7d787efb329a79b154bed2daebf61e079f4ea0654b9b3b471777af1fb6bfa617aa5bfba7d74fef5377b56e941bbbc797f76fe3f922ba61d6da076737cfc3af1f96c858cdcec9d5437ff2bd8ca5f2888d68d91262e37aa18ad8a4516e20366dd6da88cd59cd0e6221216221214f0b5848c8d3021612f2b48085843c2d6021214f0b5848c8d386e23c6d288e5810472c882316c4110be2880571c4cebc8886582788eb4a3d938652cfb4a9d4336729f52cd6957a565ab24d425cb64988cb360971d926212edb24c4659b84b86c9310e769c38ef3b461c76d5f1177578af822aa88331a241aa46e8f06894e247e74d08944571b5c1674b5d18e443b92d88a6947a21d8976247ab5c163109e577fd891bcf19039fe6430657d77beb4d9681e30fa4635a039f85fffc22f25b61935")) == text, "zlib -1")

-- corrupt input is rejected, never returned
local good = libdeflate:CompressZlib(text, { level = 6 })
local function rejects(z, what)
    local okz, e = pcall(soft, z)
    assert(not okz, what .. " was accepted")
    return e
end
assert(rejects(good:sub(1, -2), "short trailer"):find("adler32", 1, true))
assert(rejects(good:sub(1, -5) .. "\0\0\0\0", "bad adler"):find("adler32", 1, true))
rejects(good:sub(1, 20), "truncated stream")
rejects("\120\2" .. good:sub(3), "bad header")
rejects(good:sub(1, 2) .. "\255" .. good:sub(4), "bad block type")

-- a corrupt block fails the boot with the loader's message
ok, err = boot({ ["/boot/nexusos"] = image:sub(1, info0.dataOffset + 30) .. "\255\255"
    .. image:sub(info0.dataOffset + 33) }, { dataCard = false })
assert(not ok and tostring(err):find("^nexusos: inflate failed"), tostring(err))

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
