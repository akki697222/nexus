-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Re-run the OS self test; its summary is printed to this terminal.
local pid = process_manager.spawn({ path = "System://Services/selftest.lua" })
process_manager.wait(pid)
