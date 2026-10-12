-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@class system
system = {}

---Open a device capability: system.open("display"), system.open("display", {"set"}),
---system.open("display", "graphics").
function system.open(resource, ops)
    arg(1, resource, "string")
    if type(ops) == "string" then ops = { ops } end
    arg(2, ops, "table", true)
    return capability.open_device(resource, ops)
end
