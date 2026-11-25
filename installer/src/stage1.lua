-- installer/src/stage1.lua - the installer, booted as /init.lua
--
-- The disk it boots from may have /.nexus-install with:
--   answers.lua     from stage0 (or written by hand): any of
--                   target, hostname, user = { name, hash }, groups,
--                   kernel, source, base, unattended; stage0 adds staged
--                   and restore_boot. confirmed = true is written just
--                   before the disk is erased, so a restart resumes.
--   init.lua.orig   the /init.lua stage0 replaced (Cancel restores it)
--   manifest.lua    a bundled release with its files (offline install)
-- With answers.unattended or answers.confirmed nothing is asked.

stage1 = {}

local function context(updated)
    local bootAddress = computer.getBootAddress()
    local boot = component.proxy(bootAddress)
    local ctx = { bootAddress = bootAddress, boot = boot, answers = {}, updated = updated }
    if boot.isDirectory(STAGE) then
        if boot.exists(STAGE .. "/answers.lua") then
            local text, err = disk.readAll(boot, STAGE .. "/answers.lua")
            local a
            if text then a, err = util.loadData(text, "answers.lua") end
            if type(a) == "table" then
                ctx.answers = a
            else
                ctx.answersError = err or "answers.lua does not return a table"
            end
        end
        if boot.exists(STAGE .. "/manifest.lua") then
            ctx.bundle, ctx.bundleError = source.offline(boot, STAGE)
        end
    end
    return ctx
end

-- Puts back what stage0 changed and restarts; without stage0, shuts down.
function stage1.cancel(ctx)
    local boot, a = ctx.boot, ctx.answers
    if a.staged then
        if boot.exists(STAGE .. "/init.lua.orig") then
            local orig, err = disk.readAll(boot, STAGE .. "/init.lua.orig")
            if not orig then error(err, 0) end
            disk.replace(boot, "/init.lua", orig)
        else
            boot.remove("/init.lua")
        end
        local previous = a.restore_boot
        if type(previous) == "string" and computer.setBootAddress and component.type(previous) == "filesystem" then
            computer.setBootAddress(previous)
        end
        disk.removeTree(boot, STAGE)
        computer.shutdown(true)
    end
    computer.shutdown(false)
end

-- A checked source of the given kind, or nil and why. When the release
-- has a newer installer, ask(m) decides (nil: always) and the new one runs
-- in place of this one, from the start.
local function openSource(ctx, kind, ask)
    local src, err
    if kind == "offline" then
        src, err = ctx.bundle, ctx.bundleError
        if not src then return nil, err or ("no release in " .. STAGE) end
    elseif kind == "online" then
        if not net.card() then return nil, "there is no internet card" end
        local base = ctx.answers.base
        if not base then
            base, err = source.channelBase(CHANNEL)
            if not base then return nil, err end
        end
        src, err = source.online(base)
        if not src then return nil, err end
    else
        return nil, "unknown source " .. tostring(kind)
    end
    local m = src.manifest
    if m.installer > INSTALLER_REV and not ctx.updated and (ask == nil or ask(m)) then
        local code, uerr = source.installer(src)
        if not code then return nil, uerr end
        local chunk, lerr = load(code, "=nexus-install.lua", "t", _ENV)
        if not chunk then return nil, lerr end
        -- restarts come back to the new one
        if ctx.answers.staged then disk.replace(ctx.boot, "/init.lua", code) end
        chunk("--updated")
        error("the updated installer returned", 0)
    end
    local ok, cerr = source.check(m)
    if not ok then return nil, cerr end
    return src
end

local function groupSet(m, wanted)
    local set = {}
    local list = type(wanted) == "table" and {} or nil
    if list then for _, id in ipairs(wanted) do list[id] = true end end
    for _, g in ipairs(m.groups) do
        local on
        if wanted == "all" then on = true
        elseif wanted == "none" then on = false
        elseif list then on = list[g.id] == true
        else on = g.default == true end
        if on then set[g.id] = true end
    end
    return set
end

-- nil when the plan fits on its target, else why not
local function spaceProblem(ctx, src, plan)
    local fs = component.proxy(plan.target)
    local need = install.spaceNeeded(src.manifest, plan)
    if src.kind == "online" then
        for _, f in ipairs(src.manifest.files) do
            if f.role ~= "installer" then need = need + f.size end
        end
    end
    local kept = disk.treeSize(fs, STAGE)
    if plan.target == ctx.bootAddress then kept = kept + (fs.size("/init.lua") or 0) end
    local room = (fs.spaceTotal() or 0) - kept
    if room < need then
        return string.format("The disk has room for %s, and Nexus needs about %s.", util.size(math.max(room, 0)),
            util.size(need))
    end
end

-- Downloads or checks the files, keeps the plan for a restart and installs.
local function run(ctx, src, plan, progress)
    local fs = component.proxy(plan.target)
    if src.kind == "online" then disk.removeTree(fs, STAGE .. "/dl") end
    if not fs.isDirectory(STAGE) then disk.mkdir(fs, STAGE) end
    local files = source.prepare(src, fs, STAGE .. "/dl", function(f, text) progress(0.3 * f, text) end)
    if plan.target == ctx.bootAddress then
        local a = {}
        for k, v in pairs(ctx.answers) do a[k] = v end
        a.confirmed, a.source, a.base = true, src.kind, src.base
        a.target, a.hostname, a.user, a.kernel = plan.target, plan.hostname, plan.user, plan.kernel
        a.groups = {}
        for id in pairs(plan.groups) do a.groups[#a.groups + 1] = id end
        table.sort(a.groups)
        disk.replace(ctx.boot, STAGE .. "/answers.lua", "return " .. util.serialize(a) .. "\n")
    end
    local keep = { [STAGE] = true }
    if plan.target == ctx.bootAddress then keep["/init.lua"] = true end
    install.run({ target = fs, plan = plan, manifest = src.manifest, files = files, keep = keep,
        progress = function(f, text) progress(0.3 + 0.7 * f, text) end,
        onErase = function() ctx.erased = true end })
end

-- the message of an error, without the traceback and source position
local function errorText(err)
    local line = tostring(err):match("^[^\n]*")
    return (line:gsub("^[^:]*nexus%-install%.lua:%d+: ", ""))
end

-- After a failure: try again, go back, put the old system back, or stop.
-- Returns "retry" or "back" (the others do not return).
local function failed(ctx, err, canGoBack)
    local items, actions = {}, {}
    local function add(label, action)
        items[#items + 1] = { label = label }
        actions[#actions + 1] = action
    end
    add("Retry", "retry")
    if canGoBack then add("Go back", "back") end
    if ctx.answers.staged and not ctx.erased then add("Cancel and restart the previous system", "cancel") end
    add("Shut down", "off")
    while true do
        local i = tui.menu("Installation failed", errorText(err), items, 1)
        local action = i and actions[i] or (canGoBack and "back" or nil)
        if action == "cancel" then stage1.cancel(ctx) end
        if action == "off" then computer.shutdown(false) end
        if action then return action end
    end
end

-- answers -> plan, or nil and why
local function planFromAnswers(ctx, src)
    local a = ctx.answers
    local plan = { target = a.target or ctx.bootAddress, hostname = a.hostname or "nexus",
        kernel = a.kernel or "zlib", groups = groupSet(src.manifest, a.groups) }
    if component.type(plan.target) ~= "filesystem" then return nil, "no filesystem " .. tostring(plan.target) end
    if component.invoke(plan.target, "isReadOnly") then return nil, "the target disk is read-only" end
    if not util.validHostname(plan.hostname) then return nil, "invalid hostname " .. plan.hostname end
    local u = a.user
    if type(u) ~= "table" or type(u.name) ~= "string" or not util.validUsername(u.name) then
        return nil, "answers.lua needs user = { name = ..., hash = ... }"
    end
    if type(u.hash) ~= "string" or not u.hash:match("^%x+$") or #u.hash ~= 128 then
        return nil, "user.hash must be the /etc/shadow hash (128 hex digits)"
    end
    plan.user = { name = u.name, hash = u.hash:lower() }
    if plan.kernel ~= "zlib" and plan.kernel ~= "store" then return nil, "kernel must be zlib or store" end
    return plan
end

-- Without questions: resuming a confirmed install, or answers.unattended.
function stage1.auto(ctx)
    local a = ctx.answers
    while true do
        local progress = ctx.ui and tui.progress("Installing Nexus") or function() end
        progress(0, a.confirmed and "Resuming the installation" or "Reading the release information")
        local ok, err = xpcall(function()
            local src, serr = openSource(ctx, a.source or (ctx.bundle and "offline" or "online"))
            if not src then error(serr, 0) end
            local plan, perr = planFromAnswers(ctx, src)
            if not plan then error(perr, 0) end
            local problem = spaceProblem(ctx, src, plan)
            if problem then error(problem, 0) end
            run(ctx, src, plan, progress)
        end, debug.traceback)
        if ok then computer.shutdown(true) end
        if type(err) ~= "string" then error(err, 0) end
        if not ctx.ui then error("nexus-install: " .. err, 0) end
        failed(ctx, err, false)
    end
end

function stage1.interactive(ctx)
    local a = ctx.answers
    local plan = { target = a.target, hostname = a.hostname or "nexus", user = {}, kernel = a.kernel or "zlib" }
    local src
    local function summary()
        local info
        for _, d in ipairs(disk.list()) do
            if d.address == plan.target then info = d end
        end
        local parts = {}
        for _, g in ipairs(src.manifest.groups) do
            if plan.groups[g.id] then parts[#parts + 1] = g.name end
        end
        return table.concat({
            "Write the changes to the disk? It is ERASED and Nexus "
                .. tostring(src.manifest.version or "") .. " is installed on it:",
            "",
            info and disk.describe(info) or plan.target,
            "",
            "Hostname: " .. plan.hostname,
            "User: " .. plan.user.name .. " (may use sudo; root stays locked)",
            "Kernel image: " .. (plan.kernel == "store" and "uncompressed" or "compressed"),
            "Optional parts: " .. (#parts > 0 and table.concat(parts, ", ") or "none"),
            "Source: " .. (src.kind == "online" and src.base or "bundled release"),
        }, "\n")
    end

    local steps = {
        -- welcome
        function()
            local items = { { label = "Install Nexus" },
                { label = a.staged and "Cancel and restart the previous system" or "Shut down" } }
            local i = tui.menu("Nexus installer", "Welcome. This installs Nexus, a Unix-like system for "
                .. "OpenComputers, on a disk of this computer.", items)
            if i == 2 then
                if tui.yesno("Cancel", a.staged and "Stop the installer and restart the system it replaced? "
                    .. "Nothing has been erased." or "Shut down the computer?", false) then
                    stage1.cancel(ctx)
                end
                return nil
            end
            return i == 1 or nil
        end,
        -- source
        function(dir)
            local choices = {}
            if net.card() then
                choices[#choices + 1] = { label = "Download the current release (internet card)", kind = "online" }
            end
            if ctx.bundle then
                choices[#choices + 1] = { label = "Use the bundled release "
                    .. tostring(ctx.bundle.manifest.version or ""), kind = "offline" }
            end
            if #choices == 0 then
                tui.message("Installation source", "There is no internet card and no bundled release in "
                    .. STAGE .. ". Add an internet card, or start the installer from an install medium.")
                return false
            end
            if #choices == 1 and dir < 0 then return false end
            local i = 1
            if #choices > 1 then
                i = tui.menu("Installation source", "Where should Nexus be installed from?", choices,
                    (a.source == "offline" and #choices == 2) and 2 or 1)
                if not i then return false end
            end
            local progress = tui.progress("Installation source")
            progress(0, "Reading the release information")
            local s, err = openSource(ctx, choices[i].kind, function(m)
                return tui.yesno("Installer update", "The release has a newer installer (revision "
                    .. m.installer .. ", this is " .. INSTALLER_REV .. "). Update the installer and "
                    .. "start again?", true)
            end)
            if not s then
                tui.message("Installation source", "This source cannot be used:\n\n" .. errorText(err))
                return #choices == 1 and false or nil
            end
            src = s
            plan.groups = groupSet(src.manifest, a.groups)
            return true
        end,
        -- target disk
        function()
            -- preselected: the disk stage0 prepared, else another disk than
            -- the install medium
            local list, items, selected = {}, {}, 1
            local want = plan.target or (a.staged and ctx.bootAddress)
            for _, d in ipairs(disk.list()) do
                if not d.readOnly then
                    list[#list + 1] = d
                    items[#items + 1] = { label = disk.describe(d) .. (d.boot and "  (this disk)" or "") }
                    if d.address == want then selected = #list end
                end
            end
            if #list == 0 then
                tui.message("Disks", "There is no writable disk.")
                return false
            end
            local i = tui.menu("Select disk", "Nexus is installed on a whole disk; everything on it "
                .. "is erased. Select the disk:", items, selected)
            if not i then return false end
            plan.target = list[i].address
            local problem = spaceProblem(ctx, src, plan)
            if problem then
                tui.message("Not enough space", problem)
                return nil
            end
            return true
        end,
        -- hostname
        function()
            while true do
                local v = tui.input("Hostname", "Enter the hostname of this system: one word that names "
                    .. "the computer.", { default = plan.hostname })
                if not v then return false end
                if util.validHostname(v) then
                    plan.hostname = v
                    return true
                end
                tui.message("Hostname", "Use letters, digits and '-' (not first), at most 63 characters.")
            end
        end,
        -- user
        function()
            local name = tui.input("Set up users", "Create the account you use instead of root. Root "
                .. "stays locked; this account may use sudo.\n\nUsername:", { default = plan.user.name })
            if not name then return false end
            if not util.validUsername(name) then
                tui.message("Set up users", "Use lowercase letters, digits, '_' and '-', starting with a "
                    .. "letter or '_', at most 32 characters (not root).")
                return nil
            end
            while true do
                local first = tui.input("Set up users", "Choose a password for " .. name .. ":", { mask = true })
                if not first then return nil end
                if first == "" then
                    tui.message("Set up users", "The password must not be empty.")
                else
                    local second = tui.input("Set up users", "Enter the same password again:", { mask = true })
                    if second == first then
                        plan.user = { name = name, hash = util.passwordHash(first) }
                        return true
                    elseif second then
                        tui.message("Set up users", "The passwords do not match.")
                    end
                end
            end
        end,
        -- optional parts
        function(dir)
            local groups = src.manifest.groups
            if #groups == 0 then return dir > 0 end
            local items = {}
            for i, g in ipairs(groups) do
                items[i] = { label = g.name .. (g.desc and (" - " .. g.desc) or ""), checked = plan.groups[g.id] == true }
            end
            local r = tui.checklist("Software selection", "The base system is always installed. "
                .. "Choose the optional parts:", items)
            if not r then return false end
            for i, g in ipairs(groups) do plan.groups[g.id] = items[i].checked or nil end
            return true
        end,
        -- kernel image
        function()
            local i = tui.menu("Kernel image", "How should the kernel image /boot/nexusos be stored?", {
                { label = "Compressed (zlib): smaller" },
                { label = "Uncompressed: 4x larger, loads faster without a data card" },
            }, plan.kernel == "store" and 2 or 1)
            if not i then return false end
            plan.kernel = i == 2 and "store" or "zlib"
            local problem = spaceProblem(ctx, src, plan)
            if problem then
                tui.message("Not enough space", problem)
                return nil
            end
            return true
        end,
        -- confirm
        function()
            return tui.yesno("Confirm", summary(), false) == true
        end,
        -- install
        function()
            local progress = tui.progress("Installing Nexus")
            local ok, err = xpcall(run, debug.traceback, ctx, src, plan, progress)
            if not ok and type(err) ~= "string" then error(err, 0) end
            if ok then
                tui.message("Installation complete", "Nexus is installed. "
                    .. (plan.target ~= ctx.bootAddress and "You can remove the install medium. " or "")
                    .. "The computer restarts into Nexus; log in as " .. plan.user.name .. ".")
                computer.shutdown(true)
            end
            return failed(ctx, err, not ctx.erased) == "back" and false or nil
        end,
    }

    local step, dir = 1, 1
    while true do
        local result = steps[step](dir)
        if result == true then
            step, dir = step + 1, 1
        elseif result == false then
            step, dir = math.max(1, step - 1), -1
        else
            dir = 1
        end
    end
end

function stage1.main(...)
    local ctx = context((...) == "--updated")
    ctx.ui = tui.init()
    local a = ctx.answers
    if ctx.answersError then
        if not ctx.ui then error("nexus-install: " .. ctx.answersError, 0) end
        tui.message("Answers", "Ignoring " .. STAGE .. "/answers.lua: " .. ctx.answersError)
    end
    if a.confirmed or a.unattended then return stage1.auto(ctx) end
    if not ctx.ui then
        error("nexus-install: no screen; put answers.lua with unattended = true in " .. STAGE, 0)
    end
    return stage1.interactive(ctx)
end
