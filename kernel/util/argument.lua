-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

---@param n integer
---@param val any
---@param expect type
---@param opt boolean?
_G.arg = function(n, val, expect, opt)
    local t = type(val)
    if not (t == expect or (t == "nil" and opt)) then
        error("bad argument #" .. tostring(n) .. " (" .. expect .. " expected, got " .. t .. ")", 2)
    end
end