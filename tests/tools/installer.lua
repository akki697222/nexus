-- Tests for the installer (installer/src, joined by tools/mkinstaller.lua)
-- on a mocked machine (tests/lib/oc.lua): stage0 from an OS, stage1 booted
-- without one, with the dialogs, unattended, online with a self update,
-- from an install medium, cancelling and resuming.
-- Run from nexus with: lua tests/tools/installer.lua (needs build/kernel.lua)
local oc = dofile("tests/lib/oc.lua")
local quietIo = setmetatable({ write = function() end }, { __index = io })
local nximg = assert(loadfile("tools/nximg.lua"))()
local LD = assert(loadfile("tools/lib/libdeflate.lua"))()

local function read(path)
    local f = assert(io.open(path, "rb"))
    local v = f:read("a")
    f:close()
    return v
end
local function write(path, value)
    local f = assert(io.open(path, "wb"))
    f:write(value)
    f:close()
end
local function octal(s) return tonumber(s, 8) end

-- a release, as `lua tools/nximg.lua dist` makes it
local dist = os.tmpname()
os.remove(dist)
local realPrint = print
print = function() end
nximg.run({ "dist", dist })
print = realPrint
local NAMES = { "manifest.lua", "nexusos", "rootfs", "init.lua", "config.lua", "nexus-install.lua" }
local rel = {}
for _, name in ipairs(NAMES) do rel[name] = read(dist .. "/" .. name) end
local installer = rel["nexus-install.lua"]
local manifest = assert(load(rel["manifest.lua"], "=manifest", "t", {}))()
assert(manifest.format == 1 and manifest.installer == 1 and #manifest.groups >= 2)
local selfPath = dist .. "/nexus-install.lua"

-- dist/nexus-install.lua is what users wget (raw.githubusercontent.com does
-- not redirect, GitHub release downloads do): it must be the current build
do
    local f = assert(io.open("dist/nexus-install.lua", "rb"), "dist/nexus-install.lua is missing")
    local committed = f:read("a"):gsub("\r\n", "\n")
    f:close()
    assert(committed == installer, "dist/nexus-install.lua is out of date: lua tools/mkinstaller.lua dist/nexus-install.lua")
end

-- what the rootfs holds, to compare the installed files with
local rootfsInfo = nximg.parseHeader(rel.rootfs)
local inflate = function(z) return LD:DecompressZlib(z) end
local tree = {}
for _, name in ipairs({ "usr", "etc" }) do
    local raw = nximg.readSection(rel.rootfs, rootfsInfo, nximg.findSection(rootfsInfo, nximg.SECTION[name]), inflate)
    for _, e in ipairs(nximg.decodeFs(raw)) do
        e.data = e.kind == nximg.FS_FILE and raw:sub(e.offset + 1, e.offset + e.size) or nil
        tree["/" .. name .. "/" .. e.path] = e
    end
end
assert(tree["/usr/bin/sudo.lua"].mode == octal("4755"))

-- the shadow hash the kernel checks (src/sec/user.lua)
local shaEnv = { string = string, assert = assert, table = table, math = math }
assert(loadfile("src/lib/sha2.lua", "t", shaEnv))()
local function shadowHash(password)
    return (shaEnv.sha512(password .. "salt"):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function metaLine(disk, dir, name)
    local text = disk.get((dir == "/" and "" or dir) .. "/.meta") or ""
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, #name + 1) == name .. ":" then return line end
    end
end
-- mode, uid, gid of a .meta line
local function attrs(disk, path)
    local dir, name = path:match("^(.*)/([^/]+)$")
    local line = metaLine(disk, dir == "" and "/" or dir, name)
    assert(line, "no .meta entry for " .. path)
    local mode, uid, gid = line:match("^[^:]+:V%u+:%d+:%d+:%d+:(%d+):%d+:(%d+):(%d+):")
    return mode, tonumber(uid), tonumber(gid)
end

-- stage0 on an OS: returns the machine and the run results
local function stage0(boot, components, ...)
    local m = oc.machine({ boot = boot, components = components, os = true, print = function() end,
        io = quietIo, chunkname = "=" .. selfPath })
    return m, m.run(installer, ...)
end

local function bios(boot, components)
    return oc.machine({ boot = boot, components = components })
end

-- Checks a finished install on disk for user name and the groups left out.
local function checkInstalled(disk, user, password, left)
    left = left or {}
    assert(disk.get("/init.lua") == rel["init.lua"], "boot loader in place")
    assert(disk.get("/boot/config.lua") == rel["config.lua"])
    assert(not disk.proxy.exists("/.nexus-install"), "stage removed")
    assert(disk.label == "Nexus")
    local leftPaths = {}
    for _, g in ipairs(manifest.groups) do
        if left[g.id] then for _, p in ipairs(g.paths) do leftPaths["/" .. p] = true end end
    end
    for path, e in pairs(tree) do
        if leftPaths[path] then
            assert(not disk.proxy.exists(path), path .. " belongs to a group left out")
        elseif e.kind == nximg.FS_DIR then
            assert(disk.proxy.isDirectory(path), path)
        elseif path ~= "/etc/modules.lua" and path ~= "/usr/lib/drivers/drivers.idx" and path ~= "/etc/sudoers" then
            assert(disk.get(path) == e.data, path .. " differs from the rootfs")
        end
        if not leftPaths[path] then
            local mode, uid, gid = attrs(disk, path)
            assert(tonumber(mode, 8) == e.mode and uid == e.uid and gid == e.gid, path .. " has mode " .. mode)
        end
    end
    assert((attrs(disk, "/usr/bin/sudo.lua")) == "4755", "sudo keeps its set-user-ID bit")
    assert((attrs(disk, "/etc/sudoers")) == "440")
    assert(disk.get("/etc/sudoers"):sub(-#user - 17) == "\n" .. user .. " ALL=(root) ALL\n")
    assert(disk.get("/etc/passwd") == "root:x:0:0:root:/root:/bin/sh.lua\n" .. user .. ":x:1000:1000::/home/"
        .. user .. ":/bin/sh.lua\n")
    local shadow = disk.get("/etc/shadow")
    assert(shadow:match("^root:%*:"), "root stays locked")
    assert(shadow:find("\n" .. user .. ":" .. shadowHash(password) .. ":%d+:0:99999:7:::\n"), shadow)
    assert((attrs(disk, "/etc/shadow")) == "400")
    assert(disk.get("/etc/group") == "root:0:\n" .. user .. ":1000:" .. user .. "\n")
    local mode, uid, gid = attrs(disk, "/home/" .. user)
    assert(mode == "755" and uid == 1000 and gid == 1000)
    local _, puid = attrs(disk, "/home/" .. user .. "/.profile.lua")
    assert(puid == 1000, tostring(puid) .. " " .. tostring(metaLine(disk, "/home/" .. user, ".profile.lua")))
    assert(disk.get("/home/" .. user .. "/.profile.lua"):find('os.setenv("HOME", "/home/' .. user .. '")', 1, true))
    assert((attrs(disk, "/root")) == "700")
    assert((attrs(disk, "/boot/nexusos")) == "644" and (attrs(disk, "/init.lua")) == "644")
    -- group files left out: modules.lua and drivers.idx follow
    local modules, idx = disk.get("/etc/modules.lua"), disk.get("/usr/lib/drivers/drivers.idx")
    assert(modules:find("tty.lua", 1, true))
    for _, g in ipairs(manifest.groups) do
        for _, p in ipairs(g.modules or {}) do
            assert((modules:find(p, 1, true) ~= nil) == not left[g.id], "modules.lua and " .. g.id)
        end
        for _, p in ipairs(g.drivers or {}) do
            assert((idx:find('"' .. p .. '"', 1, true) ~= nil) == not left[g.id], "drivers.idx and " .. g.id)
        end
    end
    assert(load(idx, "=drivers.idx", "t", {}), "drivers.idx still loads")
    assert(load(modules, "=modules.lua", "t", {}), "modules.lua still loads")
end

-- 1. stage0 from an OS, offline release, then the dialogs (data card,
--    some parts left out).
do
    local hdd = oc.filesystem("a1-hdd", { label = "hdd" })
    hdd.put("/init.lua", "-- the old OS\n")
    hdd.put("/home/me/notes.txt", "old")
    local m, ok, why = stage0(hdd, { hdd }, "--from", dist, "-y")
    assert(not ok and why == "reboot", tostring(why))
    assert(hdd.get("/init.lua") == installer, "stage0 puts itself in /init.lua")
    assert(hdd.get("/.nexus-install/init.lua.orig") == "-- the old OS\n")
    for _, name in ipairs(NAMES) do
        assert(hdd.get("/.nexus-install/" .. name) == rel[name], name .. " copied")
    end
    local a = assert(load(hdd.get("/.nexus-install/answers.lua"), "=a", "t", {}))()
    assert(a.staged == true and a.restore_boot == "a1-hdd" and a.source == "offline")
    assert(hdd.get("/home/me/notes.txt") == "old", "stage0 erases nothing")

    local gpu, data = oc.gpu(), oc.data(inflate)
    m = bios(hdd, { hdd, gpu, oc.screen(), data })
    m.keys("enter")                                   -- welcome: install
    m.keys("enter")                                   -- the only writable disk
    m.keys("back", "back", "back", "back", "back", "box", "enter") -- hostname
    m.keys("alice", "enter", "pw", "enter", "pw", "enter")          -- user
    m.keys("space", "down", "space", "tab", "enter")  -- leave out debug and the first driver
    m.keys("enter")                                   -- compressed kernel
    m.keys("y")                                       -- write the changes
    m.keys("enter")                                   -- complete
    ok, why = m.run(installer)
    assert(not ok and why == "reboot", tostring(why) .. "\n" .. gpu.dump())
    assert(#m.signals == 0, "every key was used")
    local left = { [manifest.groups[1].id] = true, [manifest.groups[2].id] = true }
    checkInstalled(hdd, "alice", "pw", left)
    assert(hdd.get("/etc/hostname") == "box\n")
    assert(hdd.get("/boot/nexusos") == rel.nexusos)
    assert(not hdd.proxy.exists("/home/me"), "the disk was erased")
    assert(m.bootAddress == "a1-hdd")
    assert(data.calls > 0, "the data card inflates")
end

-- 2. Unattended through stage0's options: no screen, no data card,
--    uncompressed kernel, no optional parts.
local function unattended(extra)
    local hdd = oc.filesystem("b2-hdd")
    local args = { "--from", dist, "--no-reboot", "--unattended", "--user", "bob", "--password-hash",
        shadowHash("secret"), "--groups", "none", "--kernel", "store" }
    for _, v in ipairs(extra or {}) do args[#args + 1] = v end
    local _, ok, code = stage0(hdd, { hdd }, table.unpack(args))
    assert(ok and code == 0, tostring(code))
    assert(not hdd.proxy.exists("/.nexus-install/init.lua.orig"), "there was no /init.lua to keep")
    return hdd
end
do
    local hdd = unattended()
    local m = bios(hdd, { hdd })
    local ok, why = m.run(installer)
    assert(not ok and why == "reboot", tostring(why))
    local left = {}
    for _, g in ipairs(manifest.groups) do left[g.id] = true end
    checkInstalled(hdd, "bob", "secret", left)
    assert(hdd.get("/etc/hostname") == "nexus\n")
    local kernelImage = hdd.get("/boot/nexusos")
    local info = nximg.parseHeader(kernelImage)
    assert(info.compression == nximg.COMP_STORE and #info.sections == 1)
    local distInfo = nximg.parseHeader(rel.nexusos)
    local kernel = nximg.readSection(rel.nexusos, distInfo, distInfo.sections[1], inflate)
    assert(nximg.readSection(kernelImage, info, info.sections[1]) == kernel, "same kernel, uncompressed")
    assert(info.index[info.blockCount] + info.dataOffset == #kernelImage)
end

-- 3. Resuming: a failure after the erase, then a restart.
do
    local hdd = unattended()
    hdd.failWrites = "^/boot/config%.lua$"
    local m = bios(hdd, { hdd })
    local ok, why = m.run(installer)
    assert(not ok and tostring(why):find("/boot/config.lua", 1, true), tostring(why))
    local a = assert(load(hdd.get("/.nexus-install/answers.lua"), "=a", "t", {}))()
    assert(a.confirmed == true and a.user.name == "bob" and a.source == "offline")
    assert(hdd.get("/init.lua") == installer, "the installer still boots")
    assert(hdd.get("/.nexus-install/rootfs") == rel.rootfs, "the release is kept")
    hdd.failWrites = nil
    m = bios(hdd, { hdd })
    ok, why = m.run(installer)
    assert(not ok and why == "reboot", tostring(why))
    local left = {}
    for _, g in ipairs(manifest.groups) do left[g.id] = true end
    checkInstalled(hdd, "bob", "secret", left)
end

-- 4. Online: the channel names the release; the files are downloaded.
local CHANNEL = "https://raw.githubusercontent.com/akki697222/nexus/dev-oc/dist/channel.lua"
local function pages(base, files)
    local t = { [CHANNEL] = 'return { format = 1, base = "https://example.test/download/%s", '
        .. 'channels = { stable = "v9" } }' }
    for name, data in pairs(files) do t[base .. "/" .. name] = data end
    return t
end
do
    local hdd = oc.filesystem("c3-hdd")
    local _, ok, code = stage0(hdd, { hdd }, "--no-reboot", "--unattended", "--user", "carol",
        "--password-hash", shadowHash("pw"))
    assert(ok and code == 0)
    local inet = oc.internet(pages("https://example.test/download/v9", rel))
    local m = bios(hdd, { hdd, inet, oc.data(inflate) })
    local ok2, why = m.run(installer)
    assert(not ok2 and why == "reboot", tostring(why))
    assert(inet.requests[1] == CHANNEL and inet.requests[2] == "https://example.test/download/v9/manifest.lua")
    checkInstalled(hdd, "carol", "pw")
    assert(not hdd.proxy.exists("/.nexus-install"), "downloads removed")

    -- a release with a newer installer: it is fetched, kept and run instead
    hdd = oc.filesystem("c4-hdd")
    _, ok, code = stage0(hdd, { hdd }, "--no-reboot", "--unattended", "--user", "carol",
        "--password-hash", shadowHash("pw"))
    assert(ok and code == 0)
    local newer = "UPDATED_WITH = ...\ncomputer.shutdown(false)\n"
    local newManifest = rel["manifest.lua"]:gsub("installer = 1,", "installer = 2,")
        :gsub('crc32 = %d+,\n            name = "nexus%-install%.lua",\n            role = "installer",\n            size = %d+,',
            "crc32 = " .. nximg.crc32(newer) .. ',\n            name = "nexus-install.lua",\n'
            .. '            role = "installer",\n            size = ' .. #newer .. ",")
    assert(newManifest:find("size = " .. #newer, 1, true))
    local files = {}
    for k, v in pairs(rel) do files[k] = v end
    files["manifest.lua"], files["nexus-install.lua"] = newManifest, newer
    m = bios(hdd, { hdd, oc.internet(pages("https://example.test/download/v9", files)) })
    ok, why = m.run(installer)
    assert(not ok and why == "poweroff", tostring(why))
    assert(m.env.UPDATED_WITH == "--updated", "the new installer ran")
    assert(hdd.get("/init.lua") == newer, "and boots next time")
    assert(hdd.get("/.nexus-install/answers.lua"), "nothing was installed yet")
end

-- 4b. A card that does not follow redirects (OpenComputers Rebooted): the
--     release downloads answer 302, as GitHub's do, to absolute and
--     relative locations with any header case.
do
    local hdd = oc.filesystem("c5-hdd")
    local _, ok, code = stage0(hdd, { hdd }, "--no-reboot", "--unattended", "--user", "carol",
        "--password-hash", shadowHash("pw"), "--from", "https://github.test/download/v9")
    assert(ok and code == 0)
    local p = {}
    for name, data in pairs(rel) do
        p["https://github.test/download/v9/" .. name] = { redirect = "https://objects.test/a/" .. name,
            header = name == "rootfs" and "location" or "Location" }
        p["https://objects.test/a/" .. name] = { redirect = "/b/" .. name }
        p["https://objects.test/b/" .. name] = data
    end
    local inet = oc.internet(p)
    local m = bios(hdd, { hdd, inet, oc.data(inflate) })
    local ok2, why = m.run(installer)
    assert(not ok2 and why == "reboot", tostring(why))
    assert(inet.requests[3] == "https://objects.test/b/manifest.lua", tostring(inet.requests[3]))
    checkInstalled(hdd, "carol", "pw")

    -- a redirect loop is reported, nothing is erased
    hdd = oc.filesystem("c6-hdd")
    _, ok, code = stage0(hdd, { hdd }, "--no-reboot", "--unattended", "--user", "carol",
        "--password-hash", shadowHash("pw"), "--from", "https://loop.test")
    assert(ok and code == 0)
    hdd.put("/keep.txt", "still here")
    m = bios(hdd, { hdd, oc.internet({ ["https://loop.test/manifest.lua"] = { redirect = "https://loop.test/manifest.lua" } }) })
    ok2, why = m.run(installer)
    assert(not ok2 and tostring(why):find("too many redirects", 1, true), tostring(why))
    assert(hdd.get("/keep.txt") == "still here")
end

-- 4c. /init.lua left open by the boot menu that booted it, on a Windows
--     host: it cannot be removed, so stage0, stage1 and Cancel overwrite it.
do
    local hdd = oc.filesystem("c7-hdd")
    hdd.put("/init.lua", "-- the old OS\n")
    hdd.locked["/init.lua"] = true
    local _, ok, code = stage0(hdd, { hdd }, "--from", dist, "--no-reboot")
    assert(ok and code == 0, tostring(code))
    assert(hdd.get("/init.lua") == installer and not hdd.proxy.exists("/init.lua.new"))
    local gpu = oc.gpu()
    local m = bios(hdd, { hdd, gpu, oc.screen() })
    m.keys("down", "enter", "y")
    local ok2, why = m.run(installer)
    assert(not ok2 and why == "reboot", tostring(why))
    assert(hdd.get("/init.lua") == "-- the old OS\n", "Cancel restores it")

    _, ok, code = stage0(hdd, { hdd }, "--from", dist, "--no-reboot", "--unattended", "--user", "bob",
        "--password-hash", shadowHash("secret"))
    assert(ok and code == 0, tostring(code))
    m = bios(hdd, { hdd })
    ok2, why = m.run(installer)
    assert(not ok2 and why == "reboot", tostring(why))
    checkInstalled(hdd, "bob", "secret")
    assert(not hdd.proxy.exists("/init.lua.new"))

    -- stage0 reports a failure as a message
    local ro = oc.filesystem("c8-hdd")
    ro.put("/init.lua", "x")
    ro.locked["/init.lua"] = true
    ro.failWrites = "^/init%.lua$"
    local errors = {}
    local m0 = oc.machine({ boot = ro, components = { ro }, os = true, chunkname = "=" .. selfPath })
    m0.env.io = { stderr = { write = function(_, s) errors[#errors + 1] = s end }, open = io.open,
        write = function() end, read = function() end }
    m0.env.print = function() end
    local okm, codem = m0.run(installer, "--no-reboot")
    assert(okm and codem == 1 and errors[1] == "nexus-install: cannot replace /init.lua: it can be "
        .. "neither removed nor written\n", tostring(errors[1]))
    assert(ro.get("/init.lua") == "x" and not ro.proxy.exists("/init.lua.new"))
end

-- 5. Cancel puts the old system back, boot disk included.
do
    local a, b = oc.filesystem("d5-a", { label = "a" }), oc.filesystem("d5-b", { label = "b" })
    b.put("/init.lua", "-- b's OS\n")
    local m0, ok, code = stage0(a, { a, b }, "b", "--from", dist, "--no-reboot")
    assert(ok and code == 0, tostring(code))
    assert(m0.bootAddress == "d5-b", "stage0 boots the target next")
    local gpu = oc.gpu()
    local m = bios(b, { a, b, gpu, oc.screen() })
    m.keys("down", "enter", "y")
    local ok2, why = m.run(installer)
    assert(not ok2 and why == "reboot", tostring(why) .. gpu.dump())
    assert(b.get("/init.lua") == "-- b's OS\n" and not b.proxy.exists("/.nexus-install"))
    assert(m.bootAddress == "d5-a", "the old boot disk again")
end

-- 6. An install medium on a tier 1 screen (50x16, black and white),
--    going back once, installing to another disk.
do
    local media = oc.filesystem("e6-media", { label = "install" })
    media.put("/init.lua", installer)
    for _, name in ipairs(NAMES) do
        if name ~= "nexus-install.lua" then media.put("/.nexus-install/" .. name, rel[name]) end
    end
    local hdd = oc.filesystem("e7-hdd")
    local gpu = oc.gpu({ w = 50, h = 16, depth = 1 })
    local m = bios(media, { media, hdd, gpu, oc.screen(), oc.data(inflate) })
    m.keys("enter")                         -- welcome
    m.keys("esc")                           -- back from the disk list (source is automatic)
    m.keys("enter")                         -- welcome again
    m.keys("enter")                         -- preselected: not the medium
    m.keys("enter")                         -- hostname nexus
    m.keys("dave", "enter", "x", "enter", "x", "enter")
    m.keys("tab", "enter")                  -- default parts
    m.keys("down", "enter")                 -- uncompressed kernel
    m.keys("enter")                         -- confirm defaults to No: back to the kernel
    m.keys("up", "enter")                   -- compressed after all
    m.keys("left", "enter")                 -- Yes
    m.keys("enter")
    local ok, why = m.run(installer)
    assert(not ok and why == "reboot", tostring(why) .. "\n" .. gpu.dump())
    assert(#m.signals == 0)
    checkInstalled(hdd, "dave", "x")
    assert(hdd.get("/boot/nexusos") == rel.nexusos)
    assert(media.get("/init.lua") == installer and media.get("/.nexus-install/rootfs") == rel.rootfs,
        "the medium is left alone")
    assert(m.bootAddress == "e7-hdd")
    for y = 1, 16 do assert(utf8.len(gpu.text(y)) == 50) end
end

-- 7. stage0 refusals
do
    local hdd = oc.filesystem("f8-hdd")
    local m = oc.machine({ boot = hdd, components = { hdd }, os = true, noRawApi = true,
        chunkname = "=" .. selfPath })
    local errors = {}
    m.env.io = { stderr = { write = function(_, s) errors[#errors + 1] = s end }, open = io.open,
        write = function() end, read = function() end }
    local ok, code = m.run(installer, "-y")
    assert(ok and code == 1 and errors[1]:find("no component access"), tostring(errors[1]))
    assert(not hdd.proxy.exists("/init.lua"))

    local ro = oc.filesystem("f9-ro", { readOnly = true })
    m = oc.machine({ boot = ro, components = { ro }, os = true, chunkname = "=" .. selfPath })
    errors = {}
    m.env.io = { stderr = { write = function(_, s) errors[#errors + 1] = s end }, open = io.open,
        write = function() end, read = function() end }
    ok, code = m.run(installer, "-y")
    assert(ok and code == 1 and errors[1]:find("read%-only"), tostring(errors[1]))
    errors = {}
    m = oc.machine({ boot = hdd, components = { hdd }, os = true, chunkname = "=" .. selfPath })
    m.env.io = { stderr = { write = function(_, s) errors[#errors + 1] = s end }, open = io.open,
        write = function() end, read = function() end }
    ok, code = m.run(installer, "--unattended")
    assert(ok and code == 1 and errors[1]:find("needs %-%-user"), tostring(errors[1]))
    ok, code = m.run(installer, "--from", dist .. "/nope")
    assert(ok and code == 1 and not hdd.proxy.exists("/init.lua"))
end

-- 8. A broken release is refused before anything is erased.
do
    local hdd = unattended()
    local bad = hdd.get("/.nexus-install/rootfs")
    hdd.files["/.nexus-install/rootfs"] = bad:sub(1, 100) .. "X" .. bad:sub(102)
    hdd.put("/keep.txt", "still here")
    local m = bios(hdd, { hdd })
    local ok, why = m.run(installer)
    assert(not ok and tostring(why):find("checksum mismatch", 1, true), tostring(why))
    assert(hdd.get("/keep.txt") == "still here")
end

os.execute((package.config:sub(1, 1) == "\\" and 'rmdir /s /q "' or 'rm -rf "') .. dist .. '"')
print("installer tests passed")
