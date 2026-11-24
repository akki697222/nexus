---@class device
local device = {}
---@type table<string, device_manifest>
local system_devices = {}
local deviceNodes = {}
local nextIndex = { volume = 0, floppy = 0 }
local nodePrefixes = { volume = "hd", floppy = "fd" }

local function publish(id, entry)
    local prefix = nodePrefixes[entry.type]
    if not prefix or deviceNodes[id] then return end
    local name = prefix .. nextIndex[entry.type]
    -- Managed volumes are mounted through the VFS, so these nodes carry an
    -- identity but have no raw read or write methods.
    local ok = devfs.create(name, { address = id }, true, 0600)
    if ok then
        deviceNodes[id] = name
        nextIndex[entry.type] = nextIndex[entry.type] + 1
    end
end

---@alias device_type
---| '"volume"'
---| '"processor"'
---| '"data"'
---| '"display"'
---| '"input"'
---| '"system"'
---| '"communication"'
---| '"memory"'
---| '"eeprom"'
---| '"floppy"'

---@class device_manifest
---@field addr string
---@field type device_type
---@field desc string
---@field vendor string
---@field product string
---@field node? string registered name under /dev

---@class device_manifest_cpu : device_manifest
---@field clock string

---@class device_manifest_volume : device_manifest
---@field capacity string
---@field size string
---@field clock string

---@class device_manifest_display : device_manifest
---@field capacity string
---@field width string
---@field clock? string

---@class device_manifest_memory : device_manifest
---@field clock string

---@class device_manifest_eeprom : device_manifest
---@field size string
---@field capacity string

---@class device_manifest_system : device_manifest
---@field capacity string

-- OC's device inventory is normalized before it is exposed to userland.
local function format_clock(clock_str)
    if not clock_str then return "?MHz" end
    local raw_clock = clock_str:match("([^%+]+)")
    local val = tonumber(raw_clock)
    if not val then return "?MHz" end
    return string.format("%.1fMHz", val / 10)
end

---@return device_manifest
local function describeOcDevice(addr, obj)
    ---@type device_manifest
    local base = {
        addr = addr,
        type = obj.class,
        desc = obj.description,
        vendor = obj.vendor,
        product = obj.product
    }
    -- EEPROM/Memory
    if obj.class == "memory" then
        if obj.capacity and obj.size then
            base = base --[[@as device_manifest_eeprom]]
            base.type = "eeprom"
            base.capacity = obj.capacity
            base.size = obj.size
        else
            base = base --[[@as device_manifest_memory]]
            base.clock = format_clock(obj.clock)
        end
    end
    -- FDD/HDD
    if obj.class == "volume" then
        base = base --[[@as device_manifest_volume]]
        base.capacity = obj.capacity
        base.size = obj.size
        base.clock = obj.clock
        -- FDD Check
        if base.clock == "20/20/20" then
            base.type = "floppy"
        end
    end
    -- GPU/Text Buf
    if obj.class == "display" then
        base = base --[[@as device_manifest_display]]
        base.capacity = obj.capacity
        base.width = obj.width
        base.clock = obj.clock
    end
    -- Case
    if obj.class == "system" then
        base = base --[[@as device_manifest_system]]
        base.capacity = obj.capacity
    end
    -- CPU/Data Card
    if obj.class == "processor" then
        -- CPU
        if obj.clock then
            base.clock = format_clock(obj.clock)
        else
        -- Data Card
            base.type = "data"
        end
    end
    return base
end

function device.init()
    for id, info in pairs(computer.getDeviceInfo()) do
        system_devices[id] = describeOcDevice(id, info)
    end
end

function device.handleEvent(name, id)
    if name == "component_added" then
        local info = computer.getDeviceInfo()[id]
        if not info then return end
        local entry = describeOcDevice(id, info)
        system_devices[id] = entry
        publish(id, entry)
    elseif name == "component_removed" then
        system_devices[id] = nil
        if deviceNodes[id] then
            devfs.unregister(deviceNodes[id])
            deviceNodes[id] = nil
        end
    end
end

function device.register()
    local ids = {}
    for id in pairs(system_devices) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do publish(id, system_devices[id]) end
end

---@return table<string, device_manifest> # address = manifest
function device.list()
    local result = {}
    for id, entry in pairs(system_devices) do
        result[id] = util.copyTable(entry)
        -- Device names are identifiers only. The snapshot never exposes the
        -- internal map or the devfs ops table.
        result[id].node = deviceNodes[id]
    end
    return result
end

---@param type device_type
---@return device_manifest?
function device.getFromType(type)
    for id, dev in pairs(system_devices) do
        if dev.type == type then
            local result = util.copyTable(dev)
            result.node = deviceNodes[id]
            return result
        end
    end
end

function device.get(addr)
    local entry = system_devices[addr]
    if entry then
        local result = util.copyTable(entry)
        result.node = deviceNodes[addr]
        return result
    end
end
