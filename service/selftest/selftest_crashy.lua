-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- System service that crashes on its first run only (restart test).
selftest_crash_runs = (selftest_crash_runs or 0) + 1
if selftest_crash_runs == 1 then
    error("intentional crash (selftest)")
end
service_manager.ready("selftest_crashy")
while true do
    event.pull()
end
