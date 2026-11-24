-- debug-account.lua - development builds only: a "debug" user (password
-- "debug") that may use sudo, created once when config.debug is set.
-- Release branches drop this program and /etc/init.d/debug-account.
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
local system = require("system")
local user = require("user")
local fs = require("filesystem")

if not system.config.debug or user.getUser("debug") then return end
user.create("debug", "debug", 100, 100)
local f = fs.open("/etc/sudoers", "a")
f:write("\ndebug ALL=(root) ALL\n")
f:close()
