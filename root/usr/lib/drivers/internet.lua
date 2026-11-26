-- internet.lua - OpenComputers Internet card driver
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local driver = {}

driver.info = {
    match = { "internet" },
    class = "generic",
    desc = "Internet Card",
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

-- Calls a method of a socket or request handle of the card: those raise on
-- network errors, which come back as nil and the message.
local function call(f, ...)
    local res = table.pack(pcall(f, ...))
    if not res[1] then return nil, tostring(res[2]) end
    return table.unpack(res, 2, res.n)
end

---@param inst driver_internet_instance self
---@param addr string TCP Address
---@param port number Port
---@return driver_internet_socket|nil # socket
---@return string|nil # error
-- The socket is not connected yet: socket:finishConnect() returns true once
-- it is (false while connecting, nil and the reason when it failed). Wait
-- with event.pull(timeout, "internet_ready") between tries.
function driver.ops.connect(inst, addr, port)
    checkArg(1, addr, "string")
    checkArg(2, port, "number", "nil")
    local sock, err = call(inst.proxy.connect, addr, port)
    if not sock then return nil, err or "connection failed" end

    ---@class driver_internet_socket
    local handle = {}
    local function close()
        if not sock then return end
        call(sock.close)
        sock = nil
    end

    function handle:finishConnect()
        if not sock then return nil, "socket is closed" end
        return call(sock.finishConnect)
    end

    function handle:id()
        if not sock then return nil, "socket is closed" end
        return call(sock.id)
    end

    ---@param data string
    ---@return number|nil
    function handle:write(data)
        checkArg(1, data, "string")
        if not sock then return nil, "socket is closed" end
        return call(sock.write, data)
    end

    ---@param n number?
    ---@return string|nil
    function handle:read(n)
        checkArg(1, n, "number", "nil")
        if not sock then return nil, "socket is closed" end
        return call(sock.read, n)
    end

    function handle:close() close() end

    return setmetatable(handle, {
        __metatable = "socket",
        __gc = close,
        __close = close,
    }), nil
end

---@param url string
---@param body string?
---@param headers table?
---@param method string?
---@return driver_internet_request|nil # request
---@return string|nil # error
function driver.ops.request(inst, url, body, headers, method)
    checkArg(1, url, "string")
    checkArg(2, body, "string", "nil")
    checkArg(3, headers, "table", "nil")
    checkArg(4, method, "string", "nil")
    if not inst.proxy.isHttpEnabled() then return nil, "HTTP is disabled on this server" end
    local req, err
    if method then
        req, err = call(inst.proxy.request, url, body, headers, method)
    else
        req, err = call(inst.proxy.request, url, body, headers)
    end
    if not req then return nil, err or "request failed" end

    ---@class driver_internet_request
    local handle = {}
    local function close()
        if not req then return end
        call(req.close)
        req = nil
    end

    function handle:finishConnect()
        if not req then return nil, "request is closed" end
        return call(req.finishConnect)
    end

    function handle:response()
        if not req then return nil, "request is closed" end
        local code, message, hdrs = call(req.response)
        if not code then return nil, message end
        -- a copy: the card's table is not the caller's to keep
        local copy = {}
        for k, v in pairs(hdrs or {}) do
            if type(v) == "table" then
                local list = {}
                for i, x in ipairs(v) do list[i] = x end
                copy[k] = list
            else
                copy[k] = v
            end
        end
        return code, message, copy
    end

    ---@param n number?
    function handle:read(n)
        checkArg(1, n, "number", "nil")
        if not req then return nil, "request is closed" end
        return call(req.read, n)
    end

    function handle:close() close() end

    return setmetatable(handle, {
        __metatable = "request",
        __gc = close,
        __close = close,
    }), nil
end

return driver
