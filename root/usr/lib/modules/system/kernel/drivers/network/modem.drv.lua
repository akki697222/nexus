-- modem.lua - OpenComputers modem driver
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local event = require("event")
local system = require("system")

local driver = {
    match = { "modem", "tunnel" },
    class = "network",
    node = "modem",
    mode = 664,
    group = "modem",
    access = {
        open = "r",
        close = "r",
        isWired = "r",
        isWireless = "r",
        isTunnel = "r"
    },
    priority = 0,
}

---@alias driver_modem_data number|string|boolean|nil

---@class driver_modem_queue
---@field sender string sender address
---@field port integer received port
---@field distance integer distance from sender (blocks)
---@field data table<driver_modem_data>


function driver.attach(dev)
    ---@class driver_modem_instance
    local inst = {
        ---@type string
        dev = dev,
        ---@type oc_component_modem
        proxy = dev.proxy,
        isTunnel = dev.proxy.type == "tunnel",
        ---@type driver_modem_queue[]
        queue = {},
        maxQueue = 64,
        ---@type table<integer, boolean>
        openedPorts = {},
        listenerId = nil,
        wired = dev.proxy.isWired and dev.proxy.isWired() or false
    }

    if inst.isTunnel then

    else
        --onErrorが未設定なためリスナーのcallback内(↓)でエラーが出ても握りつぶされる
        inst.listenerId = event.listen("modem_message", function(...)
            local ev = {...}
            table.remove(ev, 1)
            table.remove(ev, 1)
            local sender = table.remove(ev, 1)
            local port = table.remove(ev, 1)
            local distance = table.remove(ev, 1)
            system.printk("modem: message from " .. sender .. " (port " .. port .. ") data: [" .. table.concat(ev, ", ") .. "]")
            if #inst.queue > inst.maxQueue then
                table.remove(inst.queue, 1)
            end
            table.insert(inst.queue, {
                sender = sender,
                port = port,
                distance = distance,
                data = ev
            })
        end)
    end

    if not inst.listenerId then
        error("Unable to register event listener.")
    end

    return inst
end

function driver.detach(inst)
    inst.proxy = nil
end

driver.ops = {}

---@param inst driver_modem_instance
---@param port integer
function driver.ops.open(inst, port)
    if not inst.isTunnel and inst.proxy.open(port) then
        inst.openedPorts[tostring(port)] = true
        return true
    else
        return false
    end
end

---@param inst driver_modem_instance
---@param port integer
function driver.ops.close(inst, port)
    if not inst.isTunnel and inst.proxy.close(port) then
        inst.openedPorts[tostring(port)] = nil
        return true
    else
        return false
    end
end

---@param inst driver_modem_instance
function driver.ops.isWired(inst)
    return inst.wired
end

---@param inst driver_modem_instance
function driver.ops.isWireless(inst)
    return not inst.wired
end

---@param inst driver_modem_instance
function driver.ops.isTunnel(inst)
    return inst.isTunnel and not inst.wired
end

return {
    manifest = {
        name = "modem",
        desc = "Modem",
        version = "0.1.0",
        version_n = 1,
        abi = 1,
        depends = {},
    },
    load = function() end,
    unload = function() end,
    module = {},
    driver = driver,
}
