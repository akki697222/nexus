-- Focused tests for the compressed-kernel boot path:
-- tools/pack_kernel.lua, root/boot/loader.lua and root/init.lua wiring.
-- Run from nexus with: lua tests/kernel_loader.lua
local function read(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

local compile = loadstring or load
local unpack_args = unpack or table.unpack

local libdeflate_source = read("root/usr/lib/libdeflate.lua")
local loader_source = read("root/boot/loader.lua")
local init_source = read("root/init.lua")
local packer_source = read("tools/pack_kernel.lua")

local function new_libdeflate()
    return assert(compile(libdeflate_source, "libdeflate.lua", "t", _ENV))()
end

local libdeflate = new_libdeflate()

-- Independent gzip encoder used as a reference (not LibDeflate's wrapper),
-- so the loader is tested against externally produced images too.
local crc_table = {}
for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
        if crc & 1 == 1 then crc = (crc >> 1) ~ 0xEDB88320 else crc = crc >> 1 end
    end
    crc_table[i] = crc
end
local function crc32(data)
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = crc_table[(crc ~ data:byte(i)) & 0xFF] ~ (crc >> 8)
    end
    return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end
local function le32(n)
    return string.char(n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255)
end
local function gzip_wrap(payload, source, flags, extra_header)
    local header = "\31\139\8" .. string.char(flags or 0) .. "\0\0\0\0\2\255"
    return header .. (extra_header or "") .. payload
        .. le32(crc32(source)) .. le32(#source % 2^32)
end

-- Mock OpenComputers boot filesystem backed by an in-memory file table.
local function new_component(files)
    local handles, next_handle = {}, 0
    local reads = {}
    local component = {
        invoke = function(address, method, ...)
            assert(address == "boot-address", "unexpected address: " .. tostring(address))
            local args = { ... }
            if method == "open" then
                local path = args[1]
                if not files[path] then return nil, "file not found" end
                next_handle = next_handle + 1
                handles[next_handle] = { path = path, pos = 1 }
                return next_handle
            elseif method == "read" then
                local handle = handles[args[1]]
                if not handle then return nil, "bad handle" end
                local data = files[handle.path]
                reads[#reads + 1] = handle.path
                if handle.pos > #data then return nil end
                local chunk = data:sub(handle.pos, handle.pos + 65535)
                handle.pos = handle.pos + #chunk
                return chunk
            elseif method == "close" then
                if not handles[args[1]] then return nil, "bad handle" end
                handles[args[1]] = nil
                return true
            end
            error("unexpected invoke: " .. tostring(method))
        end,
    }
    return component, reads
end

local function run_loader(files, kernel_args_sink)
    local component, reads = new_component(files)
    local computer = { getBootAddress = function() return "boot-address" end }
    local booted = {}
    local env = {
        component = component,
        computer = computer,
        loadfile = function(path, env2)
            local data = files[path]
            if not data then return nil, "file not found" end
            return compile(data, "=" .. path, "bt", env2 or _ENV)
        end,
        load = load,
        xpcall = xpcall,
        debug = debug,
        error = error,
        assert = assert,
        tostring = tostring,
        tonumber = tonumber,
        type = type,
        pairs = pairs,
        ipairs = ipairs,
        select = select,
        table = table,
        string = string,
        math = math,
        pcall = pcall,
        _ENV = _ENV,
        _VERSION = _VERSION,
    }
    -- The kernel stub records its arguments instead of running a real kernel.
    env._G = env
    local chunk = assert(compile(loader_source, "loader.lua", "t", env))
    local ok, err = pcall(chunk)
    return ok, err, reads, booted
end

local KERNEL_STUB = "return { ... }\n"
local function kernel_stub_files(image)
    return {
        ["/boot/kernel.lua.gz"] = image,
        ["/usr/lib/libdeflate.lua"] = libdeflate_source,
        ["/boot/kernel.lua"] = KERNEL_STUB,
    }
end

-- Capture what the kernel chunk receives by wrapping load in the loader env.
local function run_loader_capture(files)
    local component = new_component(files)
    local captured = {}
    local env = {
        component = component,
        computer = { getBootAddress = function() return "boot-address" end },
        loadfile = function(path, env2)
            local data = files[path]
            if not data then return nil, "file not found" end
            local chunk, err = compile(data, "=" .. path, "bt", env2 or _ENV)
            if not chunk then return nil, err end
            if path == "/boot/kernel.lua" then
                return function(...)
                    captured.args = { ... }
                    captured.name = "=" .. path
                    return chunk(...)
                end
            end
            return chunk
        end,
        load = function(source, name, mode, env2)
            local chunk, err = load(source, name, mode, env2)
            if not chunk then return nil, err end
            if name == "=/boot/kernel.lua.gz" then
                return function(...)
                    captured.args = { ... }
                    captured.name = name
                    return chunk(...)
                end
            end
            return chunk
        end,
        xpcall = xpcall,
        debug = debug,
        error = error,
        assert = assert,
        tostring = tostring,
        type = type,
        pairs = pairs,
        ipairs = ipairs,
        select = select,
        table = table,
        string = string,
        math = math,
        pcall = pcall,
        _VERSION = _VERSION,
    }
    local chunk = assert(compile(loader_source, "loader.lua", "t", env))
    local ok, err = pcall(chunk)
    return ok, err, captured
end

-- 1. Round trip: LibDeflate-compressed gzip image boots with init= argument.
local kernel_source = "-- test kernel\nlocal args = { ... }\nreturn args\n"
local payload = assert(libdeflate:CompressDeflate(kernel_source, { level = 8 }))
local image = gzip_wrap(payload, kernel_source)
local ok, err, captured = run_loader_capture(kernel_stub_files(image))
assert(ok, "compressed boot failed: " .. tostring(err))
assert(captured.name == "=/boot/kernel.lua.gz", "loader must boot the gz image")
assert(captured.args and captured.args[1] == "init=/usr/sbin/init.lua",
    "kernel must receive init= argument")

-- 2. External-tool compatibility: stored (uncompressed) deflate blocks are
-- valid raw DEFLATE too; build one by hand to prove the loader is not tied to
-- LibDeflate's compressor.
local function stored_deflate(data)
    local out = {}
    local pos = 1
    repeat
        local block = data:sub(pos, pos + 65534)
        pos = pos + #block
        local final = pos > #data and 1 or 0
        out[#out + 1] = string.char(final) .. le32(#block):sub(1, 2)
            .. le32((#block ~ 0xFFFF) & 0xFFFF):sub(1, 2) .. block
    until pos > #data
    return table.concat(out)
end
local stored_image = gzip_wrap(stored_deflate(kernel_source), kernel_source)
ok, err, captured = run_loader_capture(kernel_stub_files(stored_image))
assert(ok, "stored-block boot failed: " .. tostring(err))
assert(captured.name == "=/boot/kernel.lua.gz")

-- 3. gzip optional header fields (FEXTRA/FNAME/FCOMMENT/FHCRC) are skipped.
local extra = le32(4):sub(1, 2) .. "ABCD" .. "kernel.lua\0" .. "a comment\0" .. "\0\0"
local flagged_image = gzip_wrap(payload, kernel_source, 4 | 8 | 16 | 2, extra)
ok, err, captured = run_loader_capture(kernel_stub_files(flagged_image))
assert(ok, "flagged gzip boot failed: " .. tostring(err))
assert(captured.name == "=/boot/kernel.lua.gz")

-- 4. Corruption is detected: bad magic, bad CRC, bad size, truncated image.
local bad_magic = "\31\138" .. image:sub(3)
ok, err = run_loader(kernel_stub_files(bad_magic))
assert(not ok and tostring(err):find("not a gzip image", 1, true), "bad magic must fail")

local bad_crc = image:sub(1, #image - 8) .. le32(crc32(kernel_source) ~ 1) .. le32(#kernel_source)
ok, err = run_loader(kernel_stub_files(bad_crc))
assert(not ok and tostring(err):find("checksum mismatch", 1, true), "bad CRC must fail")

local bad_size = image:sub(1, #image - 4) .. le32(#kernel_source + 1)
ok, err = run_loader(kernel_stub_files(bad_size))
assert(not ok and tostring(err):find("size mismatch", 1, true), "bad ISIZE must fail")

ok, err = run_loader(kernel_stub_files(image:sub(1, 12)))
assert(not ok, "truncated image must fail")

-- 5. Missing LibDeflate is a clear error, not a silent fallback.
local files = kernel_stub_files(image)
files["/usr/lib/libdeflate.lua"] = nil
ok, err = run_loader(files)
assert(not ok and tostring(err):lower():find("libdeflate", 1, true), "missing library must fail loudly")

-- 6. Fallback: no gz image -> plain /boot/kernel.lua is loaded and booted.
files = { ["/boot/kernel.lua"] = KERNEL_STUB, ["/usr/lib/libdeflate.lua"] = libdeflate_source }
ok, err, captured = run_loader_capture(files)
assert(ok, "plain fallback failed: " .. tostring(err))
assert(captured.name == "=/boot/kernel.lua")
assert(captured.args and captured.args[1] == "init=/usr/sbin/init.lua")

-- 7. No kernel at all -> error mentions the kernel.
ok, err = run_loader({})
assert(not ok and tostring(err):find("Unable to load kernel", 1, true))

-- 8. root/init.lua delegates to boot/loader.lua.
do
    local loaded = {}
    local loader_files = { ["boot/loader.lua"] = "return true" }
    local handles, next_handle = {}, 0
    local env = {
        component = { invoke = function(_, method, ...)
            local args = { ... }
            if method == "open" then
                if not loader_files[args[1]] then return nil, "file not found" end
                next_handle = next_handle + 1
                handles[next_handle] = { path = args[1], pos = 1 }
                return next_handle
            elseif method == "read" then
                local handle = handles[args[1]]
                local data = loader_files[handle.path]
                if handle.pos > #data then return nil end
                local chunk = data:sub(handle.pos)
                handle.pos = #data + 1
                return chunk
            elseif method == "close" then
                handles[args[1]] = nil
                return true
            end
            error("unexpected invoke: " .. tostring(method))
        end },
        computer = { getBootAddress = function() return "boot-address" end },
        load = function(source, name, mode, env2)
            loaded[#loaded + 1] = name
            if name == "=boot/loader.lua" then
                return function() loaded.loader_ran = true end
            end
            return load(source, name, mode, env2)
        end,
        xpcall = xpcall,
        debug = debug,
        error = error,
        math = math,
        _ENV = _ENV,
    }
    local chunk = assert(compile(init_source, "init.lua", "t", env))
    assert(pcall(chunk))
    assert(loaded[1] == "=boot/loader.lua" and loaded.loader_ran,
        "init.lua must load and run boot/loader.lua")
end

-- 9. Packer output is a valid gzip image that the loader accepts.
do
    local tmp = os.tmpname()
    local input_path = tmp .. ".lua"
    local output_path = tmp .. ".gz"
    local input = assert(io.open(input_path, "wb"))
    input:write(kernel_source)
    input:close()

    local packer = assert(compile(packer_source, "pack_kernel.lua", "t", _ENV))
    -- pack_kernel reads arg and uses loadfile relative to cwd; run it with arg.
    local old_arg = arg
    arg = { input_path, output_path }
    local ok_pack, pack_err = pcall(packer)
    arg = old_arg
    assert(ok_pack, "packer failed: " .. tostring(pack_err))

    local packed = read(output_path)
    os.remove(input_path)
    os.remove(output_path)

    ok, err, captured = run_loader_capture(kernel_stub_files(packed))
    assert(ok, "packer image boot failed: " .. tostring(err))
    assert(captured.name == "=/boot/kernel.lua.gz")
end

io.write("kernel_loader tests passed\n")
