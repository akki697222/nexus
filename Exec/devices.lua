-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local list = capability.list_devices()
local addrs = {}
for addr in pairs(list) do addrs[#addrs + 1] = addr end
table.sort(addrs)
for _, addr in ipairs(addrs) do
    print(string.format("%-8s %s", list[addr].nexus_type, addr))
end
