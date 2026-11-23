---@class chatbox
local box = {}

function box.print()
    
end

---@type kernel_module
return {
    load = function() end,
    unload = function() end,
    module = box,
    manifest = {
        name = "chatbox",
        desc = "chatbox (advanced peripherals) peripheral driver",
        version = "0.1.0-dev-oc",
        version_n = 1,
    }
}
