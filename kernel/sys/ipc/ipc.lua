-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@type ipc
local ipc = {}

function ipc.send(pid, data)
    arg(1, pid,  "number")
    arg(2, data, "table")
    router.push_to(pid, {
        type = "ipc",
        from = scheduler.current(),
        data = data,
    })
end

function ipc.is_alive(pid)
    arg(1, pid, "number")
    return process_manager.get(pid) ~= nil
end