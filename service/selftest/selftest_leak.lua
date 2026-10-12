-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Opens a stream and exits without closing it (capability lifetime test).
local args = process_manager.current_proc().args
selftest_leaked = fs.open(args[1], "r")
