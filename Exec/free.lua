-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local free, total = computer.freeMemory(), computer.totalMemory()
print(string.format("total %d  used %d  free %d", total, total - free, free))
