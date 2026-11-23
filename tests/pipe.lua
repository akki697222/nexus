-- Focused VFS anonymous-pipe tests. Run from nexus/: lua tests/pipe.lua
local file = assert(io.open("src/vfs.lua", "r"))
local source = file:read("*a")
file:close()
-- Expose the kernel-only descriptor helpers to this isolated test chunk.
source = assert(source:gsub("local vfsk = {}", "vfsk = {}", 1))

local saved = {}
for _, name in ipairs({ "vfs", "vfsk", "process", "config", "fnv1a_hash", "devfs" }) do
    saved[name] = _G[name]
end

local current = { fd = {} }
process = {
    getCurrent = function() return current end,
    blockIO = function(channel) coroutine.yield(channel) end,
    wakeIO = function() end,
}
config = { filesystem_read_bytes = 64 }
fnv1a_hash = function(value) return #value end
devfs = { close = function() end }
assert(load(source, "src/vfs.lua"))()

local function reset()
    current.fd = {}
end

local function close(fd)
    assert(vfs.close(fd))
end

-- A reader can block before data arrives, then read the bytes after wakeup.
do
    reset()
    local r, w = assert(vfs.pipe())
    local result
    local reader = coroutine.create(function() result = vfs.read(r, 3) end)
    local ok, channel = coroutine.resume(reader)
    assert(ok and channel, "reader did not block on an empty pipe")
    assert(vfs.write(w, "abc") == 3)
    assert(coroutine.resume(reader))
    assert(result == "abc")
    close(w)
    assert(vfs.read(r, 1) == nil, "closed writer should produce EOF")
    close(r)
end

-- Default pipe reads follow file:read() line behavior; *L retains each line's
-- newline without consuming a byte from the following line.
do
    reset()
    local r, w = assert(vfs.pipe())
    assert(vfs.write(w, "first\nsecond\n") == 13)
    close(w)
    assert(vfs.read(r) == "first")
    assert(vfs.read(r, "*L") == "second\n")
    assert(vfs.read(r) == nil)
    close(r)
end

-- A single write/read may exceed capacity; line and all reads drain in chunks.
do
    reset()
    local r, w = assert(vfs.pipe())
    local payload = string.rep("x", 24000) .. "\nend"
    local writeResult
    local writer = coroutine.create(function()
        writeResult = vfs.write(w, payload)
        close(w)
    end)
    local readResult
    local reader = coroutine.create(function()
        readResult = vfs.read(r, "*L") .. vfs.read(r, "*a")
    end)
    local ok = coroutine.resume(writer)
    assert(ok and coroutine.status(writer) == "suspended", "large write should wait for room")
    while coroutine.status(writer) ~= "dead" or coroutine.status(reader) ~= "dead" do
        if coroutine.status(writer) ~= "dead" then assert(coroutine.resume(writer)) end
        if coroutine.status(reader) ~= "dead" then assert(coroutine.resume(reader)) end
    end
    assert(writeResult == #payload)
    assert(readResult == payload, "incremental line/all reads changed the byte stream")
    close(r)
end

-- dup shares endpoint lifetime: EOF follows the last writer close. A closed
-- reader makes writes fail, and pipe seek is explicitly unsupported.
do
    reset()
    local r, w = assert(vfs.pipe())
    local w2 = assert(vfs.dup(w))
    close(w)
    assert(vfs.write(w2, "z") == 1)
    assert(vfs.seek(r, "set", 0) == nil)
    close(w2)
    assert(vfs.read(r, "*l") == "z")
    assert(vfs.read(r, 1) == nil)
    close(r)

    local r2, w3 = assert(vfs.pipe())
    close(r2)
    local ok, err = vfs.write(w3, "x")
    assert(ok == nil and err == "Broken pipe")
    close(w3)

    local r3, w4 = assert(vfs.pipe())
    local partial, partialErr
    local writer = coroutine.create(function()
        partial, partialErr = vfs.write(w4, string.rep("p", 20000))
    end)
    assert(coroutine.resume(writer))
    assert(coroutine.status(writer) == "suspended")
    close(r3)
    assert(coroutine.resume(writer))
    assert(partial == 8192 and partialErr == "Broken pipe")
    close(w4)
end

-- stdio remapping validates every source before incref and uses raw keys.
do
    reset()
    local r, w = assert(vfs.pipe())
    local tbl = current.fd
    local readDesc, writeDesc = tbl[r + 1], tbl[w + 1]
    assert(r >= 3 and w >= 3 and tbl[1] == nil and tbl[2] == nil)
    local inherited = assert(vfsk.inheritFds(tbl, { [0] = r, [1] = w }))
    assert(inherited[1] == readDesc and inherited[2] == writeDesc)
    assert(readDesc.ref == 2 and writeDesc.ref == 2)
    local defaultOut = { flag = "a" }
    tbl[2] = defaultOut
    local partial = assert(vfsk.inheritFds(tbl, { [0] = r }))
    assert(partial[1] == readDesc and partial[2] == defaultOut and partial[3] == nil,
        "unmapped standard descriptors should keep their existing source")
    vfsk.closeAllFds(partial)
    assert(readDesc.ref == 2 and writeDesc.ref == 2)
    local bad, err = vfsk.inheritFds(tbl, { [0] = w })
    assert(bad == nil and err and readDesc.ref == 2 and writeDesc.ref == 2)
    local called = false
    local metatableMap = setmetatable({}, { __pairs = function()
        called = true
        error("metatable callback must not run")
    end })
    assert(vfsk.inheritFds(tbl, metatableMap))
    assert(not called)
    vfsk.closeAllFds(inherited)
    close(r)
    close(w)
end

for name, value in pairs(saved) do _G[name] = value end
print("pipe tests passed")
