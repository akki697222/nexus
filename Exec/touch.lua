-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

local code = 0
for _, path in ipairs(process_manager.current_proc().args) do
    if not fs.exists(path) then
        local ok, err = fs.write_file(path, "")
        if not ok then stderr:write("touch: " .. tostring(err) .. "\n"); code = 1 end
    end
end
process_manager.exit(code)
