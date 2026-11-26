-- installer/src/install.lua - putting the system on the target disk
--
-- install.run(ctx) erases the target, unpacks the rootfs (usr and etc
-- sections) as files, writes the accounts, the kernel and the .meta files
-- with the modes and owners of the image, and last replaces /init.lua with
-- the boot loader: until then a restart comes back to the installer.
--
--   ctx.target    filesystem proxy of the target
--   ctx.plan      { hostname, user = { name, hash }, groups = { [id] = true },
--                   kernel = "zlib" | "store" }
--   ctx.manifest  checked manifest (source.check)
--   ctx.files     role -> { fs, path } (source.prepare)
--   ctx.keep      paths on the target the erase keeps
--   ctx.progress  function(fraction, text)
--   ctx.onErase   called once the disk is erased (optional)

install = {}

local function octal(s) return tonumber(s, 8) end

-- the first user, as on Linux; development builds also make a "debug" user
-- with uid 100 (root/usr/sbin/debug-account.lua)
local USER_UID = 1000

-- Bytes the install needs on the target, about.
function install.spaceNeeded(m, plan)
    local need = m.installed or 0
    if plan.kernel == "store" then need = need + (m.kernelRaw or 0) end
    return math.floor(need * 1.1) + 16384
end

-- What the deselected groups leave out: paths relative to / (usr/...),
-- kernel modules (/etc/modules.lua) and drivers (modules.idx).
local function excluded(m, plan)
    local paths, modules, drivers = {}, {}, {}
    for _, g in ipairs(m.groups) do
        if not plan.groups[g.id] then
            for _, p in ipairs(g.paths or {}) do paths[p] = true end
            for _, p in ipairs(g.modules or {}) do modules[#modules + 1] = p end
            for _, p in ipairs(g.drivers or {}) do drivers[#drivers + 1] = p end
        end
    end
    return paths, modules, drivers
end

-- Drops the lines that name one of the paths in quotes. /etc/modules.lua
-- lists one module a line and depmod writes one index entry per line.
function install.dropLines(text, paths)
    if #paths == 0 then return text end
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local keep = true
        for _, p in ipairs(paths) do
            if line:find('"' .. p .. '"', 1, true) then
                keep = false
                break
            end
        end
        if keep then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end

-- the .profile.lua user.create (src/sec/user.lua) gives a new user
local function profile(home)
    return 'local colors = require("colors")\n'
        .. 'local process = require("process")\n'
        .. 'os.setenv("HISTSIZE", "10")\n'
        .. 'os.setenv("HOME", "' .. home .. '")\n'
        .. 'os.setenv("PWD", "' .. home .. '")\n'
        .. 'os.setenv("PS1", colors.green .. "$USERNAME@$HOSTNAME" .. colors.reset .. ":" .. colors.bright_blue .. "$PWD" .. colors.reset .. "$ ")\n'
        .. 'process.cwd(os.getenv("HOME"))\n'
end

-- Writes /boot/nexusos without compression: the kernel blocks inflated,
-- one section, the same CRC-32 (it is of the uncompressed kernel).
function install.storeKernel(file, fs, path, inflate)
    local reader = img.reader(file.fs, file.path)
    local info = img.open(reader, "nexusos")
    local k = info.sections[img.SECTION.kernel]
    if not k then error("nexusos has no kernel", 0) end
    local bs, n = info.blockSize, k.blockCount
    local index, offset = {}, 0
    for i = 0, n - 1 do
        index[#index + 1] = string.pack("<I4", offset)
        offset = offset + (i == n - 1 and (k.rawSize - (n - 1) * bs) or bs)
    end
    index[#index + 1] = string.pack("<I4", offset)
    local metaRaw = string.pack("<BBI2I4I4I4I4I4", img.SECTION.kernel, 0, 0, k.rawSize, 0, n, k.crc, 0)
        .. table.concat(index)
    local head = "NXIMG\0" .. string.pack("<BBI4I2I2I4I4I4", 1, 0, bs, 1, 0, n, 32 + #metaRaw, crc32(metaRaw))
    head = head .. string.pack("<I4", crc32(head))
    local write, close = disk.writer(fs, path)
    write(head .. metaRaw)
    for raw in img.blocks(info, k, inflate) do write(raw) end
    close()
    reader.close()
end

function install.run(ctx)
    local fs, plan, m, files, progress = ctx.target, ctx.plan, ctx.manifest, ctx.files, ctx.progress
    local now = util.realTime()
    local attrs = meta.new()
    local paths, modules, drivers = excluded(m, plan)
    local name = plan.user.name
    local inflate = img.inflater()

    progress(0, "Erasing the disk")
    disk.wipe(fs, "/", ctx.keep)
    if ctx.onErase then ctx.onErase() end

    -- /usr and /etc from the rootfs
    local reader = img.reader(files.rootfs.fs, files.rootfs.path)
    local info = img.open(reader, "rootfs")
    local total, done = 0, 0
    for _, mount in ipairs({ "usr", "etc" }) do
        local section = info.sections[img.SECTION[mount]]
        if not section then error("rootfs has no " .. mount .. " section", 0) end
        total = total + section.rawSize
    end
    local transforms = {
        ["etc/modules.lua"] = function(text) return install.dropLines(text, modules) end,
        ["usr/lib/modules/modules.idx"] = function(text) return install.dropLines(text, drivers) end,
        ["etc/sudoers"] = function(text)
            if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end
            return text .. name .. " ALL=(root) ALL\n"
        end,
    }
    for _, mount in ipairs({ "usr", "etc" }) do
        disk.mkdir(fs, "/" .. mount)
        attrs.add("/" .. mount, true, octal("755"), 0, 0)
        img.unpack(info, info.sections[img.SECTION[mount]], inflate, function(e)
            local rel = mount .. "/" .. e.path
            if paths[rel] then return nil end
            local path = "/" .. rel
            attrs.add(path, e.dir, e.mode, e.uid, e.gid)
            if e.dir then
                disk.mkdir(fs, path)
                return nil
            end
            local transform = transforms[rel]
            if transform then
                local parts = {}
                return function(chunk)
                    if chunk then
                        parts[#parts + 1] = chunk
                    else
                        disk.writeAll(fs, path, transform(table.concat(parts)))
                    end
                end
            end
            local write, close = disk.writer(fs, path)
            return function(chunk)
                if not chunk then return close() end
                write(chunk)
                done = done + #chunk
                progress(0.05 + 0.7 * done / total, "Unpacking the system")
            end
        end)
    end
    reader.close()

    -- the kernel
    progress(0.75, "Installing the kernel")
    disk.mkdir(fs, "/boot")
    attrs.add("/boot", true, octal("755"), 0, 0)
    if plan.kernel == "store" then
        install.storeKernel(files.kernel, fs, "/boot/nexusos", inflate)
    else
        disk.copy(files.kernel.fs, files.kernel.path, fs, "/boot/nexusos")
    end
    attrs.add("/boot/nexusos", false, octal("644"), 0, 0)
    disk.copy(files.config.fs, files.config.path, fs, "/boot/config.lua")
    attrs.add("/boot/config.lua", false, octal("644"), 0, 0)

    -- hostname and accounts: root stays locked, the user may use sudo
    progress(0.92, "Configuring the system")
    local home = "/home/" .. name
    local function put(path, data, mode, uid)
        disk.writeAll(fs, path, data)
        attrs.add(path, false, octal(mode), uid or 0, uid or 0)
    end
    put("/etc/hostname", plan.hostname .. "\n", "644")
    put("/etc/passwd", "root:x:0:0:root:/root:/bin/sh.lua\n"
        .. string.format("%s:x:%d:%d::%s:/bin/sh.lua\n", name, USER_UID, USER_UID, home), "644")
    put("/etc/shadow", "root:*:0:0:99999:7:::\n"
        .. string.format("%s:%s:%d:0:99999:7:::\n", name, plan.user.hash, now), "400")
    -- the user also gets the device groups of the installed drivers
    -- (/dev/eth0 is root:ethernet 0660); gids from 100, as devmgr picks
    local groupLines, gid, seen = { "root:0:", string.format("%s:%d:%s", name, USER_UID, name) }, 100, {}
    for _, g in ipairs(m.groups) do
        local dg = g.devgroup
        if plan.groups[g.id] and type(dg) == "string" and dg:match("^[%w_%-]+$") and not seen[dg] then
            seen[dg] = true
            groupLines[#groupLines + 1] = string.format("%s:%d:%s", dg, gid, name)
            gid = gid + 1
        end
    end
    put("/etc/group", table.concat(groupLines, "\n") .. "\n", "644")
    for _, dir in ipairs({ { "/root", "700", 0 }, { "/home", "755", 0 }, { home, "755", USER_UID } }) do
        disk.mkdir(fs, dir[1])
        attrs.add(dir[1], true, octal(dir[2]), dir[3], dir[3])
    end
    put(home .. "/.profile.lua", profile(home), "644", USER_UID)

    -- modes and owners
    progress(0.97, "Writing file modes")
    attrs.add("/init.lua", false, octal("644"), 0, 0)
    attrs.each(now, function(dir, text)
        disk.writeAll(fs, (dir == "/" and "" or dir) .. "/.meta", text)
        util.yield()
    end)

    -- last: from here on the disk boots Nexus
    progress(0.99, "Installing the boot loader")
    local loader, err = disk.readAll(files.boot.fs, files.boot.path)
    if not loader then error(err, 0) end
    disk.replace(fs, "/init.lua", loader)
    fs.setLabel("Nexus")
    if computer.setBootAddress then computer.setBootAddress(fs.address) end
    disk.removeTree(fs, STAGE)
    progress(1, "Installation complete")
end
