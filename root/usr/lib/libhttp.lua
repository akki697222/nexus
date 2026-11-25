-- libhttp.lua - HTTP(S) through the internet card: require("http")
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
--   local res, err = http.request(url, { method = "POST", headers = {...},
--       body = "...", onChunk = function(s) end, timeout = 60 })
--   res.status, res.message, res.headers (names lower case), res.body
--
-- Goes through /dev/eth0 (the internet driver), so the user needs to be in
-- the device's group (ethernet). Redirects are followed here for cards
-- that hand them back. With onChunk the body is passed on as it arrives
-- (res.body is then nil); a failure after the body has started is returned
-- as nil and why, like any other.

local device = require("device")
local event = require("event")
local computer = require("computer")

local http = {}

http.DEVICE = "/dev/eth0"
http.MAX_REDIRECTS = 5

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

local function lowerHeaders(h)
    local out = {}
    for k, v in pairs(h or {}) do
        if type(k) == "string" then
            if type(v) == "table" then v = table.concat(v, ", ") end
            out[k:lower()] = v
        end
    end
    return out
end

-- one request, no redirects: returns status, message, headers, req or nil, why
local function open(eth, url, opts, deadline)
    local req, err = eth.request(url, opts.body, opts.headers, opts.method)
    if not req then return nil, url .. ": " .. tostring(err) end
    while true do
        local ok, cerr = req:finishConnect()
        if ok then break end
        if ok == nil then
            req:close()
            return nil, url .. ": " .. tostring(cerr or "connection failed")
        end
        if computer.uptime() > deadline then
            req:close()
            return nil, url .. ": timed out"
        end
        event.pull(0.05, "internet_ready")
    end
    while true do
        local code, message, headers = req:response()
        if code then return code, message, lowerHeaders(headers), req end
        if computer.uptime() > deadline then
            req:close()
            return nil, url .. ": no response"
        end
        event.pull(0.05, "internet_ready")
    end
end

function http.request(url, opts)
    opts = opts or {}
    local eth, derr = device.open(opts.device or http.DEVICE, "rw")
    if not eth then
        return nil, (opts.device or http.DEVICE) .. ": " .. tostring(derr)
            .. (derr == "Permission denied" and " (is the user in the ethernet group?)" or "")
    end
    local deadline = computer.uptime() + (opts.timeout or 60)
    local status, message, headers, req
    for _ = 0, http.MAX_REDIRECTS do
        status, message, headers, req = open(eth, url, opts, deadline)
        if not status then
            device.close(eth)
            return nil, message
        end
        if not (REDIRECT[status] and headers.location) then break end
        req:close()
        local target = headers.location
        if target:sub(1, 1) == "/" then target = url:match("^(%a[%w+.-]*://[^/]+)") .. target end
        url = target
        if status == 303 then
            local get = {}
            for k, v in pairs(opts) do get[k] = v end
            get.method, get.body = "GET", nil
            opts = get
        end
    end
    if REDIRECT[status] then
        req:close()
        device.close(eth)
        return nil, url .. ": too many redirects"
    end
    local parts, onChunk = {}, opts.onChunk
    while true do
        local chunk, rerr = req:read(8192)
        if chunk == nil then
            if rerr then
                req:close()
                device.close(eth)
                return nil, url .. ": " .. tostring(rerr)
            end
            break
        end
        if #chunk > 0 then
            if onChunk then onChunk(chunk) else parts[#parts + 1] = chunk end
            deadline = computer.uptime() + (opts.timeout or 60)
        else
            if computer.uptime() > deadline then
                req:close()
                device.close(eth)
                return nil, url .. ": timed out"
            end
            event.pull(0.05, "internet_ready")
        end
    end
    req:close()
    device.close(eth)
    return { status = status, message = message, headers = headers,
        body = not onChunk and table.concat(parts) or nil }
end

return http
