local colors = require("colors")
local fs = require("filesystem") --[[@as vfs]]
local function list(path)
    print("--- List: " .. path .. " ---")
    for entry in fs.list(path) do
        print(entry)
    end
end
list("/")
list("/dev")
list("/proc")

while true do
    io.write("# ")
    local input = io.read()
    print(input)
    coroutine.yield()
end