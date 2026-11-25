-- installer/src/stage0.lua - starting the installer from a running OS
--
-- Puts this file on the target disk as /init.lua and restarts into it
-- (stage1). The old /init.lua is kept in /.nexus-install/init.lua.orig, so
-- cancelling in stage1 gives the old system back; nothing is erased here.
-- Needs the raw component and computer APIs from the OS (globals or
-- require); OSes that do not give them to programs are not supported, use
-- an install medium there.

stage0 = {}

local USAGE = [[
usage: nexus-install [<address|label>] [options]
  Prepares the disk (default: the boot disk) and restarts into the
  installer. Nothing is erased before you confirm there.
  --from <dir|url>       release to install: a directory made by
                         `lua tools/nximg.lua dist` (copied to the disk,
                         installs offline) or its URL
  --answers <file>       answers.lua to start from
  --hostname <name>      --user <name>      --password-hash <hex>
  --groups <all|none|id,...>                --kernel <zlib|store>
  --unattended           install without questions (needs --user and
                         --password-hash, the /etc/shadow hash)
  -y, --yes              restart without asking
  --no-reboot            prepare only
  --self <file>          this installer's file, if it cannot be found]]

local VALUE = { from = true, answers = true, hostname = true, user = true, ["password-hash"] = true,
    groups = true, kernel = true, self = true }

local function parse(args)
    local opts = {}
    local i = 1
    while i <= args.n do
        local a = args[i]
        local long = a:match("^%-%-(.+)$")
        if long and VALUE[long] then
            i = i + 1
            if args[i] == nil then return nil, a .. " needs a value" end
            opts[long] = args[i]
        elseif a == "-y" or a == "--yes" then
            opts.yes = true
        elseif a == "--unattended" then
            opts.unattended = true
        elseif a == "--no-reboot" then
            opts.noReboot = true
        elseif a == "-h" or a == "--help" then
            opts.help = true
        elseif a:sub(1, 1) == "-" then
            return nil, "unknown option " .. a
        elseif opts.target then
            return nil, "more than one target"
        else
            opts.target = a
        end
        i = i + 1
    end
    return opts
end

local function api(name)
    local ok, lib = pcall(require, name)
    if ok and type(lib) == "table" then return lib end
end

local function readHostFile(path)
    local file = io.open(path, "rb")
    if not file then return nil, "cannot open " .. path end
    local text = file:read("*a")
    file:close()
    return text
end

-- This file's text: from --self, the chunk name (OC's sandboxed getinfo
-- adds a level of its own), the OS's process info or $_ (OpenOS).
local function ownSource(given)
    local candidates = { given }
    if debug and debug.getinfo then
        for level = 1, 3 do
            local info = debug.getinfo(level, "S")
            local path = info and type(info.source) == "string" and info.source:match("^[@=](/.+)$")
            if path then candidates[#candidates + 1] = path end
        end
    end
    local process = api("process")
    if process and process.info then
        local info = process.info()
        if info and type(info.path) == "string" then candidates[#candidates + 1] = info.path end
    end
    candidates[#candidates + 1] = os.getenv and os.getenv("_")
    for i = 1, #candidates + 1 do
        local path = candidates[i]
        if type(path) == "string" then
            local text = readHostFile(path)
            if text and text:find("local INSTALLER_REV = ", 1, true) then return text end
        end
    end
end

-- the target filesystem: an address (or its start) or a label
local function findTarget(name, boot)
    if not name then return boot end
    for address in component.list("filesystem") do
        if address:sub(1, #name) == name then return address end
    end
    for address in component.list("filesystem") do
        if component.invoke(address, "getLabel") == name then return address end
    end
end

function stage0.main(args)
    local function fail(message)
        io.stderr:write("nexus-install: " .. tostring(message) .. "\n")
        return 1
    end
    local opts, perr = parse(args)
    if not opts then return fail(perr .. "\n" .. USAGE) end

    component = component or api("component")
    computer = computer or api("computer")
    if not component or not computer or not component.proxy or not computer.getBootAddress then
        return fail("this OS gives programs no component access; boot an install medium "
            .. "instead (lua tools/nximg.lua media)")
    end
    local boot = computer.getBootAddress()
    if opts.help then
        print(USAGE)
        print("disks:")
        for _, d in ipairs(disk.list()) do
            print((d.boot and "* " or "  ") .. disk.describe(d))
        end
        return 0
    end

    -- this file, to become the target's /init.lua
    local code = ownSource(opts.self)
    if not code then return fail("cannot find the installer's own file; pass --self <path>") end

    local target = findTarget(opts.target, boot)
    if not target then return fail("no filesystem matches " .. tostring(opts.target)) end
    if target == (computer.tmpAddress and computer.tmpAddress()) then return fail("the target is the tmpfs") end
    local fs = component.proxy(target)
    if fs.isReadOnly() then return fail("the target is read-only") end

    -- answers for stage1
    local a = {}
    if opts.answers then
        local text, err = readHostFile(opts.answers)
        if not text then return fail(err) end
        local loaded, lerr = util.loadData(text, opts.answers)
        if type(loaded) ~= "table" then return fail(lerr or (opts.answers .. " does not return a table")) end
        a = loaded
    end
    if opts.hostname then a.hostname = opts.hostname end
    if opts.user or opts["password-hash"] then
        a.user = type(a.user) == "table" and a.user or {}
        a.user.name = opts.user or a.user.name
        a.user.hash = opts["password-hash"] or a.user.hash
    end
    if opts.groups then
        if opts.groups == "all" or opts.groups == "none" then
            a.groups = opts.groups
        else
            a.groups = {}
            for id in opts.groups:gmatch("[^,]+") do a.groups[#a.groups + 1] = id end
        end
    end
    if opts.kernel then a.kernel = opts.kernel end
    if opts.unattended then a.unattended = true end
    if a.unattended and (type(a.user) ~= "table" or not a.user.name or not a.user.hash) then
        return fail("--unattended needs --user and --password-hash")
    end
    a.staged, a.restore_boot = true, boot
    if a.target and a.target ~= target then a.target = nil end

    -- the release to copy, for an offline install
    local bundle
    if opts.from then
        if opts.from:match("^%a[%w+.-]*://") then
            a.base, a.source = opts.from, "online"
        else
            local dir = opts.from:gsub("/+$", "")
            local text, err = readHostFile(dir .. "/manifest.lua")
            if not text then return fail(err) end
            local m, merr = source.parseManifest(text)
            if not m then return fail(merr) end
            bundle = { dir = dir, manifest = m, text = text }
            a.source = "offline"
        end
    end

    local need = #code + 4096
    if bundle then
        need = need + #bundle.text
        for _, f in ipairs(bundle.manifest.files) do need = need + (f.size or 0) end
    end
    local free = (fs.spaceTotal() or 0) - (fs.spaceUsed() or 0) + disk.treeSize(fs, STAGE)
    if free < need then
        return fail(string.format("not enough space on %s: %s free, %s needed", target:sub(1, 8),
            util.size(free), util.size(need)))
    end

    -- a previous run's stage goes, except the /init.lua it kept
    if fs.isDirectory(STAGE) then
        for _, name in ipairs(fs.list(STAGE) or {}) do
            if name ~= "init.lua.orig" then disk.removeTree(fs, STAGE .. "/" .. name:gsub("/$", "")) end
        end
    else
        disk.mkdir(fs, STAGE)
    end
    if fs.exists("/init.lua") and not fs.exists(STAGE .. "/init.lua.orig") then
        local current, err = disk.readAll(fs, "/init.lua")
        if not current then return fail(err) end
        if not current:find("local INSTALLER_REV = ", 1, true) then
            disk.writeAll(fs, STAGE .. "/init.lua.orig", current)
        end
    end
    if bundle then
        io.write("Copying the release from " .. bundle.dir)
        for _, f in ipairs(bundle.manifest.files) do
            local file = io.open(bundle.dir .. "/" .. f.name, "rb")
            if not file then return fail("cannot open " .. bundle.dir .. "/" .. f.name) end
            local write, close = disk.writer(fs, STAGE .. "/" .. f.name)
            while true do
                local chunk = file:read(8192)
                if not chunk then break end
                write(chunk)
            end
            close()
            file:close()
            io.write(".")
        end
        disk.writeAll(fs, STAGE .. "/manifest.lua", bundle.text)
        print("")
    end
    disk.writeAll(fs, STAGE .. "/answers.lua", "return " .. util.serialize(a) .. "\n")
    disk.replace(fs, "/init.lua", code)
    if target ~= boot then
        if not computer.setBootAddress then return fail("cannot set the boot disk on this OS") end
        computer.setBootAddress(target)
    end

    print("The installer is on " .. target:sub(1, 8) .. " as /init.lua; the old one is kept in "
        .. STAGE .. ".")
    print("Nothing is erased before you confirm in the installer, and Cancel there restores the old system.")
    if opts.noReboot then
        print("Restart the computer to start the installer.")
        return 0
    end
    if not opts.yes then
        io.write("Restart into the installer now? [Y/n] ")
        local answer = io.read()
        if answer and answer:lower():match("^n") then
            print("Restart the computer to start the installer.")
            return 0
        end
    end
    computer.shutdown(true)
    return 0
end
