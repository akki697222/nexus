-- internet.lua - OpenComputers Internet card driver
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
---@type event
--local event = require("event")

local driver = {}

driver.info = {
    match = { "internet" },
    class = "generic",
    desc = "Internet Card (OpenComputers)",
    node = "eth",
    mode = 660,
    group = "ethernet",
    access = {
        isTcpEnabled = "r",
        isHttpEnabled = "r",
        connect = "rw",
        request = "rw"
    },
}

function driver.attach(dev)
    ---@class driver_internet_instance
    local inst = {
        ---@type string
        dev = dev,
        ---@type oc_component_internet
        proxy = dev.proxy
    }
    return inst
end

function driver.detach(inst)
    inst.proxy = nil
end

driver.ops = {}

function driver.ops.isTcpEnabled(inst)
    return inst.proxy.isTcpEnabled()
end

function driver.ops.isHttpEnabled(inst)
    return inst.proxy.isHttpEnabled()
end

--[=[
connect(address:string[, port:number]):userdata
Opens a new TCP connection. Returns the handle of the connection.

TCP Socket Object

    read([n:number]):string
    Tries to read data from the socket stream. Returns the read byte array.
    close()
    Closes an open socket stream.
    write(data:string):number
    Tries to write data to the socket stream. Returns the number of bytes written.
    finishConnect():boolean
    Ensures a socket is connected. Errors if the connection failed.
    id():string Returns the id for this socket.

After calling finishConnect or read, this socket generates a signal named internet_ready whenever new data is available to be read. It has one parameter which is the socket id.
]=]

---@param inst driver_internet_instance self
---@param addr string TCP Address
---@param port number Port
---@return driver_internet_socket|nil # socket
---@return string|nil # error
function driver.ops.connect(inst, addr, port)
    local p = inst.proxy
    local e

    local success, sock = pcall(p.connect, addr, port)
    if not success then
        return nil, tostring(sock or "Unknown Error")
    end

    event.listenBackground(true)

    success, e = pcall(sock.finishConnect)
    if not success then
        pcall(sock.close)
        return nil, "Connection failed: " .. tostring(e or "Unknown error")
    end

    event.pull("internet_ready")

    event.listenBackground(false)

    ---@class driver_internet_socket
    local handle = {
        socket = sock
    }

    local function close()
        if not sock then return end
        sock:close()
        sock = nil
    end

    function handle:id()
        return self.socket.id()
    end

    ---@param data string
    ---@return number
    function handle:write(data)
        checkArg(1, data, "string")
        return self.socket.write(data)
    end

    ---@param n number?
    ---@return string?
    function handle:read(n)
        checkArg(1, n, "number", "nil")
        return self.socket.read(n)
    end

    return setmetatable(handle, {
        __metatable = "socket",
        __gc = close,
        __close = close,
    }), nil
end

---@param url string
---@param postData string?
---@param headers table?
---@return driver_internet_request|nil # request
---@return string|nil # error
function driver.ops.request(url, postData, headers)
    return nil, "Unimplemented"
end

return driver
