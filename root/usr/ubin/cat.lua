local fs = require("filesystem")

local args = { ... }
if #args == 0 then args[1] = "-" end

local function copy(input, format)
    while true do
        local chunk, err = input:read(format)
        if chunk == nil then
            if err then return nil, err end
            return true
        end

        local written, writeErr = io.write(chunk)
        if written == false or (written == nil and writeErr ~= nil) or (type(written) == "number" and written < #chunk) then
            return nil, writeErr or "write failed"
        end
    end
end

local status = 0
for _, path in ipairs(args) do
    local input, err
    local isStdin = path == "-"
    if isStdin then
        input = io.stdin
    elseif fs.isDirectory(path) then
        err = "Is a directory"
    else
        input, err = fs.open(path, "rb")
    end

    if input then
        local format = isStdin and io.isatty(0) and "*L" or 4096
        local ok
        ok, err = copy(input, format)
        if not isStdin then input:close() end
        if not ok then err = err or "read failed" end
    end
    if err then
        io.stderr:write("cat: " .. path .. ": " .. tostring(err) .. "\n")
        status = 1
    end
end

return status
