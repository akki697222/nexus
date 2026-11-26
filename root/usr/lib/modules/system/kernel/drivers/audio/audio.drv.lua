-- audio.lua - OpenComputers: Rebooted/Community Edition audio driver
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local driver = {
    match = { "audio" },
    class = "audio",
    node = "pcm",
    mode = 666,
    group = "audio",
    access = {

    },
    priority = 0,
}


function driver.attach(dev)
    local inst = { dev = dev, proxy = dev.proxy}
    return inst
end

function driver.detach(inst)
    inst.proxy = nil
end

return {
    manifest = {
        name = "audio",
        desc = "Audio Card",
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
