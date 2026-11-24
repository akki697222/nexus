-- audio.lua - OpenComputers: Rebooted/Community Edition audio driver
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local driver = {}

driver.info = {
    match = { "audio" },
    class = "generic",
    desc = "Audio Card",
    node = "pcm",
    mode = 666,
    group = "audio",
    access = {

    },
}

function driver.attach(dev)
    local inst = { dev = dev, proxy = dev.proxy}
    return inst
end

function driver.detach(inst)
    inst.proxy = nil
end

return driver
