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
--
-- http:// URLs go over a TCP socket of the card when it allows TCP (opts.tcp
-- = false: never): the card's own HTTP hands over one piece of the body
-- per two reads, a tick each, so a streamed reply (a token in a piece or
-- two) falls behind the server; a socket returns all that has arrived.
-- https:// always uses the card's HTTP.

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

-- Waits for f() to return true: nil and why when it returns nil or the
-- deadline passes.
local function await(f, deadline, what)
    while true do
        local ok, err = f()
        if ok then return true end
        if ok == nil then return nil, err end
        if computer.uptime() > deadline then return nil, what end
        event.pull(0.05, "internet_ready")
    end
end

-- Through the card's HTTP: status, message, headers, body or nil, why.
-- body.read() returns a piece, "" while none is there yet, nil at the end,
-- or nil and why.
local function openRequest(eth, url, opts, deadline)
    local req, err = eth.request(url, opts.body, opts.headers, opts.method)
    if not req then return nil, tostring(err) end
    local ok, cerr = await(function() return req:finishConnect() end, deadline, "timed out")
    if not ok then
        req:close()
        return nil, tostring(cerr or "connection failed")
    end
    local code, message, headers
    ok = await(function()
        code, message, headers = req:response()
        return code ~= nil
    end, deadline, "no response")
    if not ok then
        req:close()
        return nil, "no response"
    end
    return code, message, lowerHeaders(headers), {
        read = function() return req:read(8192) end,
        close = function() req:close() end,
    }
end

-- Decodes a body sent with Transfer-Encoding: chunked; feed(data) returns
-- the decoded part, and true once the last chunk has been seen, or nil and
-- why.
local function dechunker()
    local buf, need, ended = "", nil, false
    return function(data)
        buf = buf .. data
        local out = {}
        while not ended do
            if need == nil then
                local line, rest = buf:match("^([^\r\n]*)\r?\n(.*)$")
                if not line then break end
                local size = tonumber(line:match("^%x+"), 16)
                if not size then return nil, "bad chunk size" end
                buf = rest
                if size == 0 then
                    ended = true
                else
                    need = size
                end
            else
                local after = buf:sub(need + 1, need + 2)
                local skip = after == "\r\n" and 2 or after:sub(1, 1) == "\n" and 1
                if not skip then
                    if #after == 2 then return nil, "bad chunk end" end
                    break
                end
                out[#out + 1] = buf:sub(1, need)
                buf = buf:sub(need + 1 + skip)
                need = nil
            end
        end
        return table.concat(out), ended
    end
end

-- HTTP/1.1 over a TCP socket of the card (http:// only): like openRequest.
local function openTcp(eth, url, opts, deadline)
    local host, port, path = url:match("^http://([^/:?#]+):?(%d*)([^#]*)")
    if not host then return nil, "bad URL" end
    port = tonumber(port) or 80
    if path == "" then path = "/" elseif path:sub(1, 1) == "?" then path = "/" .. path end
    local sock, err = eth.connect(host, port)
    if not sock then return nil, tostring(err) end
    local ok, cerr = await(function() return sock:finishConnect() end, deadline, "timed out")
    if not ok then
        sock:close()
        return nil, tostring(cerr or "connection failed")
    end

    local body = opts.body or ""
    local method = opts.method or (opts.body and "POST" or "GET")
    local lines = { method .. " " .. path .. " HTTP/1.1",
        "Host: " .. host .. (port ~= 80 and (":" .. port) or ""), "Connection: close" }
    local has = {}
    for k, v in pairs(opts.headers or {}) do
        has[k:lower()] = true
        lines[#lines + 1] = k .. ": " .. tostring(v)
    end
    if not has["user-agent"] then lines[#lines + 1] = "User-Agent: Nexus" end
    if opts.body or method == "POST" or method == "PUT" then
        lines[#lines + 1] = "Content-Length: " .. #body
    end
    local out = table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
    while #out > 0 do
        local n, werr = sock:write(out)
        if not n then
            sock:close()
            return nil, tostring(werr or "write failed")
        end
        out = out:sub(n + 1)
        if #out > 0 then event.pull(0) end
    end

    -- the status line and the headers
    local buf, closed = "", false
    local function fill()
        local data, rerr = sock:read(8192)
        if data == nil then
            if rerr then return nil, tostring(rerr) end
            closed = true
            return true
        end
        buf = buf .. data
        return #data > 0
    end
    local headEnd
    while true do
        headEnd = buf:find("\r\n\r\n", 1, true)
        if headEnd or closed then break end
        local got, rerr = fill()
        if got == nil then
            sock:close()
            return nil, rerr
        end
        if not got then
            if computer.uptime() > deadline then
                sock:close()
                return nil, "no response"
            end
            event.pull(0.05, "internet_ready")
        end
    end
    if not headEnd then
        sock:close()
        return nil, "connection closed before the response"
    end
    local head = buf:sub(1, headEnd - 1)
    buf = buf:sub(headEnd + 4)
    local code, message = head:match("^HTTP/%d[%.%d]*%s+(%d%d%d)%s*([^\r\n]*)")
    if not code then
        sock:close()
        return nil, "not an HTTP response"
    end
    code = tonumber(code)
    local headers = {}
    for line in head:gmatch("\r\n([^\r\n]+)") do
        local k, v = line:match("^([^:]+):%s*(.-)%s*$")
        if k then
            k = k:lower()
            headers[k] = headers[k] and (headers[k] .. ", " .. v) or v
        end
    end

    local noBody = method == "HEAD" or code == 204 or code == 304 or (code >= 100 and code < 200)
    local chunked = (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) ~= nil
    local left = tonumber(headers["content-length"] or "")
    local decode = chunked and dechunker() or nil
    local done = noBody or left == 0
    local pending = buf
    local function take(data)
        if done then return "" end
        if decode then
            local text, ended = decode(data)
            if text == nil then return nil, ended end
            if ended then done = true end
            return text
        end
        if left then
            data = data:sub(1, left)
            left = left - #data
            if left <= 0 then done = true end
        end
        return data
    end
    return code, message, headers, {
        read = function()
            if pending then
                local first = pending
                pending = nil
                if first ~= "" then return take(first) end
            end
            if done then return nil end
            if closed then
                if decode or (left and left > 0) then return nil, "connection closed early" end
                return nil
            end
            local data, rerr = sock:read(8192)
            if data == nil then
                if rerr then return nil, tostring(rerr) end
                closed = true
                if decode or (left and left > 0) then return nil, "connection closed early" end
                return nil
            end
            if data == "" then return "" end
            return take(data)
        end,
        close = function() sock:close() end,
    }
end

-- one request, no redirects: status, message, headers, body or nil, why
local function open(eth, url, opts, deadline)
    local code, message, headers, body
    if url:match("^[Hh][Tt][Tt][Pp]://") and opts.tcp ~= false and eth.isTcpEnabled and eth.isTcpEnabled() then
        code, message, headers, body = openTcp(eth, url, opts, deadline)
    else
        code, message, headers, body = openRequest(eth, url, opts, deadline)
    end
    if not code then return nil, url .. ": " .. tostring(message) end
    return code, message, headers, body
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
        req.close()
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
        req.close()
        device.close(eth)
        return nil, url .. ": too many redirects"
    end
    local parts, onChunk = {}, opts.onChunk
    -- Each read takes a tick; with the card's HTTP a piece only comes after
    -- an empty read: ask again at once for a while instead of sleeping, or
    -- a stream falls behind the server.
    local empty = 0
    while true do
        local chunk, rerr = req.read()
        if chunk == nil then
            if rerr then
                req.close()
                device.close(eth)
                return nil, url .. ": " .. tostring(rerr)
            end
            break
        end
        if #chunk > 0 then
            if onChunk then onChunk(chunk) else parts[#parts + 1] = chunk end
            deadline = computer.uptime() + (opts.timeout or 60)
            empty = 0
        else
            empty = empty + 1
            if computer.uptime() > deadline then
                req.close()
                device.close(eth)
                return nil, url .. ": timed out"
            end
            event.pull(empty <= 20 and 0 or 0.05, "internet_ready")
        end
    end
    req.close()
    device.close(eth)
    return { status = status, message = message, headers = headers,
        body = not onChunk and table.concat(parts) or nil }
end

return http
