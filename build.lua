-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- ============================================================
--  build.lua
--  Reads src/main.lua, resolves ---@bundle directives,
--  and writes a single concatenated output file.
-- ============================================================

local SRC   = "kernel/main.lua"
local OUT   = "build/init.lua"

-- ------------------------------------------------------------
--  Helpers
-- ------------------------------------------------------------

---Read all text from a file. Errors on failure.
---@param path string
---@return string
local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then
        error("failed to open '" .. path .. "': " .. tostring(err))
    end
    local content = f:read("*a")
    f:close()
    return content
end

---Write text to a file, creating parent dirs implicitly via the OS.
---@param path string
---@param content string
local function write_file(path, content)
    local f, err = io.open(path, "w")
    if not f then
        error("failed to write '" .. path .. "': " .. tostring(err))
    end
    f:write(content)
    f:close()
end

---Strip leading/trailing blank lines from a string.
---@param s string
---@return string
local function trim_blank_lines(s)
    s = s:gsub("^\n+", "")
    s = s:gsub("\n+$", "")
    return s
end

---Remove single-line comments (-- ...) from a line.
---Does not strip inside strings — good enough for source bundling.
---@param line string
---@return string
local function strip_comment(line)
    -- Remove standalone comment lines entirely (return empty string)
    if line:match("^%s*%-%-") then
        return ""
    end
    -- Remove trailing inline comments
    -- Simple heuristic: find first -- not inside a string
    local result = line:gsub("%s*%-%-.*$", "")
    return result
end

---Process a bundle target file:
---  - Remove ---@bundle lines (top-level directive, ignored in deps)
---  - Strip all comments
---  - Trim surrounding blank lines
---@param path string
---@return string
local function process_bundle(path)
    path = "kernel/" .. path
    local content = read_file(path)
    local lines   = {}

    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        -- Drop ---@bundle directives inside bundle files (not expanded)
        if line:match("^%s*%-%-%-%s*@bundle") then
            -- skip
        else
            local stripped = strip_comment(line)
            lines[#lines + 1] = stripped
        end
    end

    -- Join and trim surrounding blank lines
    local result = table.concat(lines, "\n")
    result = trim_blank_lines(result)
    return result
end

-- ------------------------------------------------------------
--  Main
-- ------------------------------------------------------------

local main_src = read_file(SRC)

local output_parts = {}
local consumed     = {}  -- track positions already replaced

-- Split main_src into lines, process each
local result_lines = {}

for line in (main_src .. "\n"):gmatch("([^\n]*)\n") do
    local bundle_path = line:match("^%s*%-%-%-%s*@bundle%s+(.-)%s*$")

    if bundle_path then
        -- Replace the ---@bundle line with the processed file contents
        local ok, res = pcall(process_bundle, bundle_path)
        if not ok then
            io.stderr:write("warning: skipping bundle '" .. bundle_path .. "': " .. res .. "\n")
        else
            result_lines[#result_lines + 1] = "-- included from: " .. bundle_path
            result_lines[#result_lines + 1] = res
            result_lines[#result_lines + 1] = ""
        end
    else
        result_lines[#result_lines + 1] = line
    end
end

local final = table.concat(result_lines, "\n")

write_file(OUT, final)
print("build success: " .. OUT)

-- ------------------------------------------------------------
--  Deployment layout
--
--    Boot://    core system: what the kernel needs to bring the OS up
--               (init.lua, Services/{storage,filesystem,module,driver,terminal})
--    System://  user / semi-user space (/System on the boot disk):
--               Exec/, Library/, Config/, Services/{init,compositor,selftest,...}
-- ------------------------------------------------------------

local DEPLOY_DIR = "../ocelot/boot"

-- { source, destination }; destinations are relative to the volume root
local BOOT_FILES = {
    { "service/storage/storage.lua",       "Services/storage.lua" },
    { "service/filesystem/filesystem.lua", "Services/filesystem.lua" },
    { "service/module/module.lua",         "Services/module.lua" },
    { "service/driver/driver.lua",         "Services/driver.lua" },
    { "service/terminal/terminal.lua",     "Services/terminal.lua" },
}

local SYSTEM_FILES = {
    { "service/init/init.lua",                     "Services/init.lua" },
    { "service/compositor/compositor.lua",         "Services/compositor.lua" },
    { "service/selftest/selftest.lua",             "Services/selftest.lua" },
    { "service/selftest/selftest_child.lua",       "Services/selftest_child.lua" },
    { "service/selftest/selftest_leak.lua",        "Services/selftest_leak.lua" },
    { "service/selftest/selftest_exit.lua",        "Services/selftest_exit.lua" },
    { "service/selftest/selftest_crashy.lua",      "Services/selftest_crashy.lua" },
    { "Library/gui.lua",                           "Library/gui.lua" },
    { "Library/lineedit.lua",                      "Library/lineedit.lua" },
    { "Config/gui.lua",                            "Config/gui.lua" },
}

local BIN = {
    "sh", "echo", "cat", "ls", "mkdir", "rm", "touch", "cp", "mv", "grep", "wc",
    "ps", "kill", "free", "mounts", "devices", "clear", "uptime", "reboot",
    "shutdown", "selftest", "lua", "edit", "gui", "guictl", "gui-panel", "gui-hello", "gui-term",
}
for _, name in ipairs(BIN) do
    SYSTEM_FILES[#SYSTEM_FILES + 1] = { "Exec/" .. name .. ".lua", "Exec/" .. name .. ".lua" }
end

local function mkdir_for(path)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    end
end

local function stage_and_deploy(list, stage_root, deploy_root)
    for _, f in ipairs(list) do
        local content = read_file(f[1])
        local staged = stage_root .. "/" .. f[2]
        mkdir_for(staged)
        write_file(staged, content)
        local dest = deploy_root .. "/" .. f[2]
        mkdir_for(dest)
        write_file(dest, content)
        print("deployed: " .. dest)
    end
end

mkdir_for("build/x")
mkdir_for(DEPLOY_DIR .. "/x")
write_file(DEPLOY_DIR .. "/init.lua", read_file(OUT))
print("deployed: " .. DEPLOY_DIR .. "/init.lua")

stage_and_deploy(BOOT_FILES,   "build/Boot",   DEPLOY_DIR)
stage_and_deploy(SYSTEM_FILES, "build/System", DEPLOY_DIR .. "/System")
