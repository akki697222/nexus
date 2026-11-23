local fs = require("filesystem")
local device = require("device")
local argparse = require("argparse")

local parser = argparse("umount", "Unmount filesystems")
parser:argument("targets", "mount paths or mounted sources"):args("+")
local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("umount: " .. tostring(args) .. "\n")
    os.exit(1)
end

local function deviceAddress(target)
    local node = target:match("^/dev/(hd%d+)$") or target:match("^/dev/(fd%d+)$")
    if not node then return target end
    for address, manifest in pairs(device.list()) do
        if manifest.node == node then return address end
    end
    return target
end

local failed = false
for _, target in ipairs(args.targets) do
    if target == "" then
        io.stderr:write("umount: empty target\n")
        failed = true
    else
        local source = deviceAddress(target)
        local unmounted, err = fs.umount(source)
        if not unmounted then
            io.stderr:write("umount: " .. target .. ": " .. tostring(err or "unmount failed") .. "\n")
            failed = true
        end
    end
end
if failed then os.exit(2) end
