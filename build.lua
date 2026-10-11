-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- ============================================================
--  build.lua
--  Reads src/main.lua, resolves ---@bundle directives,
--  and writes a single concatenated output file.
-- ============================================================

local SRC   = "src/main.lua"
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
    path = "src/" .. path
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

local DEPLOY = "..\\ocelot\\boot\\init.lua"
local xcopy_cmd = 'xcopy /Y "' .. OUT:gsub("/", "\\") .. '" "' .. DEPLOY:gsub("init.lua", "") .. '"'
os.execute(xcopy_cmd)