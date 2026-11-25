-- installer/src/net.lua - HTTP(S) downloads through an internet card
--
-- The card's request handle raises on connection errors, so its calls are
-- the one place here that needs pcall; failures come back as nil, err.

net = {}

function net.card()
    return component.list("internet")()
end

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- The Location header of a response (header names are case-insensitive;
-- OC gives each header as a list of values).
local function location(headers, url)
    if type(headers) ~= "table" then return nil end
    for name, value in pairs(headers) do
        if type(name) == "string" and name:lower() == "location" then
            if type(value) == "table" then value = value[1] end
            if type(value) ~= "string" then return nil end
            if value:sub(1, 1) == "/" then
                return url:match("^(%a[%w+.-]*://[^/]+)") .. value
            end
            return value
        end
    end
end

-- Opens url and waits for its status. Returns the handle, or nil, why, and
-- the URL a redirect points to. Some internet cards follow redirects
-- themselves (Ocelot), others hand them back (GitHub's release downloads
-- always redirect).
local function open(card, url)
    local ok, handle, reqErr = pcall(component.invoke, card, "request", url)
    if not ok or not handle then return nil, url .. ": " .. tostring(ok and reqErr or handle) end
    local function fail(err)
        pcall(handle.close)
        return nil, url .. ": " .. tostring(err)
    end
    local deadline = computer.uptime() + 30
    while true do
        local okc, connected, err = pcall(handle.finishConnect)
        if not okc then return fail(connected) end
        if connected then break end
        if connected == nil then return fail(err or "connection failed") end
        if computer.uptime() > deadline then return fail("timed out") end
        computer.pullSignal(0.1)
    end
    while true do
        local okr, code, message, headers = pcall(handle.response)
        if not okr then return fail(code) end
        if code then
            if code == 200 then return handle end
            if REDIRECT[code] then
                local target = location(headers, url)
                pcall(handle.close)
                if not target then return nil, url .. ": HTTP " .. code .. " without a Location" end
                return nil, "redirect", target
            end
            return fail("HTTP " .. tostring(code) .. " " .. tostring(message or ""))
        end
        if computer.uptime() > deadline then return fail("no response") end
        computer.pullSignal(0.05)
    end
end

-- Streams url into sink(chunk). Returns the byte count, or nil and why.
function net.get(url, sink)
    local card = net.card()
    if not card then return nil, "no internet card" end
    local handle, err, target
    for _ = 1, 6 do
        handle, err, target = open(card, url)
        if handle or err ~= "redirect" then break end
        url = target
    end
    if not handle then
        return nil, err == "redirect" and (url .. ": too many redirects") or err
    end
    local total = 0
    while true do
        local okd, chunk, rerr = pcall(handle.read, 16384)
        if not okd or (chunk == nil and rerr) then
            pcall(handle.close)
            return nil, url .. ": " .. tostring(okd and rerr or chunk)
        end
        if chunk == nil then break end
        if #chunk > 0 then
            total = total + #chunk
            sink(chunk)
        else
            computer.pullSignal(0.05)
        end
    end
    pcall(handle.close)
    return total
end

-- The whole body as a string, or nil and why.
function net.fetch(url)
    local parts = {}
    local n, err = net.get(url, function(chunk) parts[#parts + 1] = chunk end)
    if not n then return nil, err end
    return table.concat(parts)
end
