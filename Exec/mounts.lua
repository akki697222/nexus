-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local vols = storage.list_volumes()
local names = {}
for alias in pairs(vols) do names[#names + 1] = alias end
table.sort(names)
for _, alias in ipairs(names) do
    print(string.format("%-8s %s", alias .. "://", vols[alias].addr))
end
