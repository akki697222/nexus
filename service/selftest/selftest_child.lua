-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- Echo child for selftest: replies to every IPC request.
log.info("[selftest_child] started")
while true do
    local ev = event.pull("ipc")
    log.info("[selftest_child] got ipc from %d: %s", ev.from, tostring(ev.data.type))
    ipc.send(ev.from, { type = "reply", payload = ev.data.payload })
end
