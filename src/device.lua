---@class device
local device = {}
---@type table<string, device_manifest>
local system_devices = {}

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

local function format_clock(clock_str)
    if not clock_str then return "?MHz" end
    local raw_clock = clock_str:match("([^%+]+)")
    local val = tonumber(raw_clock)
    if not val then return "?MHz" end
    return string.format("%.1fMHz", val / 10)
end

---@return device_manifest
local function wrap(addr, obj)
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
    local counts = {
        volume = 1,
        floppy = 1
    }
    for addr, obj in pairs(computer.getDeviceInfo()) do
        local dev = wrap(addr, obj)
        local proxy = component.proxy(addr)
        system_devices[addr] = dev
        if dev.type == "volume" and proxy then
            devfs.create("sd" .. devfs.char(counts.volume), proxy)
            counts.volume = counts.volume + 1
        elseif dev.type == "floppy" then

        end
    end
    event.listenBackground(true)
    event.listen("component_added", function (name, addr, type)
        local obj = computer.getDeviceInfo()[addr]
        if obj then
            print("device '" .. addr .. "' added (" .. type .. ")")
            system_devices[addr] = wrap(addr, obj)
        end
    end)
    event.listen("component_removed", function (name, addr, type)
        print("device '" .. addr .. "' removed (" .. type .. ")")
        system_devices[addr] = nil
    end)
end

---@return table<string, device_manifest> # address = manifest
function device.list()
    return system_devices
end

---@param type device_type
---@return device_manifest?
function device.getFromType(type)
    for _, dev in pairs(system_devices) do
        if dev.type == type then
            return dev
        end
    end
end

function device.get(addr)
    return system_devices[addr]
end