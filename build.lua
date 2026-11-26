local props = require("properties")

local function expand_template(str, tbl)
    return (str:gsub("%${(.-)}", function(key)
        return tostring(tbl[key] or "")
    end))
end

local function expand_properties(tbl)
    for k, v in pairs(tbl) do
        if type(v) == "string" then
            tbl[k] = expand_template(v, tbl)
        elseif type(v) == "table" then
            expand_properties(v)
        end
    end
end

local function copyFile(srcPath, dstPath)
    local srcFile, err = io.open(srcPath, "rb")
    if not srcFile then
        return nil, "Failed to open source file: " .. err
    end

    local dstFile, err = io.open(dstPath, "w+b")
    if not dstFile then
        srcFile:close()
        return nil, "Failed to open destination file: " .. err
    end

    while true do
        local chunk = srcFile:read(4096)
        if not chunk then break end
        dstFile:write(chunk)
    end

    srcFile:close()
    dstFile:close()
    return true
end

expand_properties(props)

local deployToOC = false
local deployImages = true
for i = 1, #arg do
    if arg[i] == "oc" then
        deployToOC = true
    elseif arg[i] == "noimage" then
        deployImages = false
    end
end

-- kernel: src/ joined into build/kernel.lua (tools/kbuild.lua, any OS)
local outputFile = assert(loadfile("tools/kbuild.lua"))().build(props)
print("Kernel: " .. outputFile)

if props.minify then
    os.execute("luamin -f "..outputFile.." > .tmp && move /Y .tmp "..outputFile)
end

local kernelImage = outputFile
if props.compress then
    print("Compressing kernel image with LibDeflate (gzip)...")
    local packed = os.execute("lua tools/pack_kernel.lua \"" .. outputFile .. "\" \"" .. outputFile .. ".gz\"")
    if packed ~= 0 and packed ~= true then
        error("Failed to compress kernel image")
    end
    kernelImage = outputFile .. ".gz"
end

if props.overwrite then
    local bootDeploy = "..\\ocelot\\boot"

    print("Overwrite mode: Clearing " .. bootDeploy .. "\\* ...")
    local r1 = os.execute("rd /s /q \"" .. bootDeploy .. "\" > nul 2>&1 && mkdir \"" .. bootDeploy .. "\"")
    if r1 ~= 0 and r1 ~= true then
        print("Warning: Failed to clear " .. bootDeploy)
    end

    if deployToOC then
        local ocDeploy = "D:\\Projects\\OpenComputers\\run\\saves\\dev1.20.1\\opencomputers\\63f96e0b-5ef3-4762-9105-5381c1b3f313"
        print("Overwrite mode: Clearing " .. ocDeploy .. "\\* ...")
        local r2 = os.execute("rd /s /q \"" .. ocDeploy .. "\" > nul 2>&1 && mkdir \"" .. ocDeploy .. "\"")
        if r2 ~= 0 and r2 ~= true then
            print("Warning: Failed to clear " .. ocDeploy)
        end
    end
end

-- modules.idx lists the modules and drivers; devmgr binds the drivers in it
do
    local depmod = assert(loadfile("tools/depmod.lua"))()
    if not depmod.run("root/usr/lib/modules") then
        error("depmod failed")
    end
end

print("Deploying ./root to ../ocelot/boot...")
local exitCode = os.execute("xcopy \".\\root\\*\" \"..\\ocelot\\boot\\\" /E /I /Y > nul")

if exitCode ~= 0 and exitCode ~= true then
    print("Warning: Failed to copy ./root directory.")
else
    print("Directory sync complete.")
end

-- Modes and owners of /usr (sudo is set-user-ID) as .meta files, from the
-- rules images and the installer use (tools/nximg.lua); the kernel does not
-- set them at boot.
local nximg = assert(loadfile("tools/nximg.lua"))()
print("Metadata: " .. nximg.deployMeta("root/usr", "../ocelot/boot/usr", "/usr") .. " .meta files in ../ocelot/boot/usr")

-- after the sync: overwrite mode starts from an empty ../ocelot/boot, so
-- boot/ only exists once ./root has been copied
os.execute("if not exist \"..\\ocelot\\boot\\boot\" mkdir \"..\\ocelot\\boot\\boot\"")
local kernelTarget = props.compress and "kernel.lua.gz" or "kernel.lua"
print("Move: " .. kernelImage .. " to ../ocelot/boot/boot/" .. kernelTarget)
local copied, copyErr = copyFile(kernelImage, "../ocelot/boot/boot/" .. kernelTarget)
if not copied then
    print("Warning: Failed to copy " .. kernelTarget .. ": " .. (copyErr or ""))
end

if deployToOC then
    local ocDeploy = "D:\\Projects\\OpenComputers\\run\\saves\\dev1.20.1\\opencomputers\\63f96e0b-5ef3-4762-9105-5381c1b3f313"
    
    os.execute("if not exist \"" .. ocDeploy .. "\\boot\" mkdir \"" .. ocDeploy .. "\\boot\"")
    
    print("Move: " .. kernelImage .. " to " .. ocDeploy .. "/boot/" .. kernelTarget)
    local ok, err = copyFile(kernelImage, ocDeploy .. "\\boot\\" .. kernelTarget)
    if not ok then
        print("Warning: Failed to copy " .. kernelTarget .. " to OC: " .. (err or ""))
    end

    print("Deploying ./root to " .. ocDeploy .. "...")
    local r3 = os.execute("xcopy \".\\root\\*\" \"" .. ocDeploy .. "\\\" /E /I /Y > nul")
    if r3 ~= 0 and r3 ~= true then
        print("Warning: Failed to sync root to OC save directory.")
    else
        print("OC save directory sync complete.")
        nximg.deployMeta("root/usr", ocDeploy .. "\\usr", "/usr")
    end
end

-- Boot images for the Ocelot test disks: a zlib image (inflated by a data
-- card, or in Lua without one) and a store image. Only /boot/nexusos and /init.lua are replaced; the
-- rest of each disk (/etc, /home, ...) and an existing /boot/config.lua
-- are left alone. Skip with `lua build.lua noimage`.
local IMAGE_TARGETS = {
    { dir = "../ocelot/nexusos-zlib", options = {} },
    { dir = "../ocelot/nexusos-store", options = { "--store" } },
}

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

if deployImages then
    for _, target in ipairs(IMAGE_TARGETS) do
        local winDir = target.dir:gsub("/", "\\")
        os.execute("if not exist \"" .. winDir .. "\\boot\" mkdir \"" .. winDir .. "\\boot\"")
        local out = target.dir .. "/boot/nexusos"
        local args = { "build", out, "--kernel", outputFile }
        for _, o in ipairs(target.options) do args[#args + 1] = o end
        print("Image: " .. out)
        local ok, err = pcall(nximg.run, args)
        if not ok then
            error("Failed to build " .. out .. ": " .. tostring(err))
        end
        local copied, copyErr = copyFile("bootstrap/init.lua", target.dir .. "/init.lua")
        if not copied then
            print("Warning: Failed to copy init.lua to " .. target.dir .. ": " .. (copyErr or ""))
        end
        if not exists(target.dir .. "/boot/config.lua") then
            copyFile("root/boot/config.lua", target.dir .. "/boot/config.lua")
        end
    end
end

print("Build complete!")
