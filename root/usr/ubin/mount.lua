local fs = require("filesystem")
local device = require("device")
local argparse = require("argparse")

local parser = argparse("mount", "Mount a filesystem or list mount points")
parser:argument("operands", "SOURCE and TARGET"):args("*")
local ok, args = parser:pparse({...})
if not ok then
    io.stderr:write("mount: " .. tostring(args) .. "\n")
    os.exit(1)
end

local function resolveDevice(source)
    local node = source:match("^/dev/(hd%d+)$") or source:match("^/dev/(fd%d+)$")
    if node then
        for address, manifest in pairs(device.list()) do
            if manifest.node == node then return address end
        end
    end
    return source
end

local function listMounts()
    local rows = {}
    for info, path in fs.mounts() do
        rows[#rows + 1] = {
            path = path,
            source = info.address or info.label or "?",
            label = info.label,
            mode = info.readOnly == true and "ro" or info.readOnly == false and "rw" or "?",
        }
    end
    table.sort(rows, function(a, b)
        if a.path == b.path then return a.source < b.source end
        return a.path < b.path
    end)
    for _, row in ipairs(rows) do
        local label = row.label and (" (" .. row.label .. ")") or ""
        io.write(string.format("%s%s on %s (%s)\n", row.source, label, row.path, row.mode))
    end
end

if #args.operands == 0 then
    listMounts()
elseif #args.operands == 2 then
    if args.operands[1] == "" or args.operands[2] == "" then
        io.stderr:write("mount: source and target must not be empty\n")
        os.exit(1)
    end
    local source = resolveDevice(args.operands[1])
    local mounted, err = fs.mount(source, args.operands[2])
    if not mounted then
        io.stderr:write("mount: " .. tostring(err or "mount failed") .. "\n")
        os.exit(2)
    end
else
    io.stderr:write("mount: expected no operands or SOURCE TARGET\n")
    os.exit(1)
end
