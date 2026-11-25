-- installer/src/net.lua - HTTP(S) downloads through an internet card
--
-- The card's request handle raises on connection errors, so its calls are
-- the one place here that needs pcall; failures come back as nil, err.

net = {}

function net.card()
    return component.list("internet")()
end

-- Streams url into sink(chunk). Returns the byte count, or nil and why.
function net.get(url, sink)
    local card = net.card()
    if not card then return nil, "no internet card" end
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
    local okr, code, message = pcall(handle.response)
    if okr and code and code ~= 200 then return fail("HTTP " .. tostring(code) .. " " .. tostring(message or "")) end
    local total = 0
    while true do
        local okd, chunk, err = pcall(handle.read, 16384)
        if not okd then return fail(chunk) end
        if chunk == nil then
            if err then return fail(err) end
            break
        end
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
