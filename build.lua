-- Copyright (C) 2026 nexus
-- Released under the MIT license
-- https://opensource.org/licenses/mit-license.php

-- ============================================================
--  build.lua
--  Reads properties.lua for source roots and build settings.
--  Each source root must contain a main.lua with ---@output <path>.
--  Output is written to <build_dir>/<output path>.
-- ============================================================

-- ------------------------------------------------------------
--  Load properties
-- ------------------------------------------------------------

local props_chunk, err = loadfile("properties.lua")
if not props_chunk then
    io.stderr:write("failed to load properties.lua: " .. tostring(err) .. "\n")
    os.exit(1)
end
props_chunk()

-- validate
assert(type(sources)     == "table",  "properties.lua: 'sources' must be a table")
assert(type(build_dir)   == "string", "properties.lua: 'build_dir' must be a string")
assert(type(deploy_root) == "string", "properties.lua: 'deploy_root' must be a string")

-- ------------------------------------------------------------
--  Helpers
-- ------------------------------------------------------------

---@param path string
---@return string
local function read_file(path)
    local f, e = io.open(path, "r")
    if not f then
        error("failed to open '" .. path .. "': " .. tostring(e))
    end
    local content = f:read("*a")
    f:close()
    return content
end

---@param path string
---@param content string
local function write_file(path, content)
    local dir = path:match("^(.+)[/\\][^/\\]+$")
    if dir then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    end
    local f, e = io.open(path, "w")
    if not f then
        error("failed to write '" .. path .. "': " .. tostring(e))
    end
    f:write(content)
    f:close()
end

---@param s string
---@return string
local function trim_blank_lines(s)
    s = s:gsub("^\n+", "")
    s = s:gsub("\n+$", "")
    return s
end

---@param line string
---@return string
local function strip_comment(line)
    if line:match("^%s*%-%-") then return "" end
    return line:gsub("%s*%-%-.*$", "")
end

---@param src_root string
---@param rel_path string
---@return string
local function process_bundle(src_root, rel_path)
    local content = read_file(src_root .. "/" .. rel_path)
    local lines   = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*%-%-%-%s*@bundle") then
            lines[#lines + 1] = strip_comment(line)
        end
    end
    return trim_blank_lines(table.concat(lines, "\n"))
end

-- ------------------------------------------------------------
--  Build a single source root
-- ------------------------------------------------------------

---@param src_root string
local function build_source(src_root)
    local main_path = src_root .. "/main.lua"
    local main_src  = read_file(main_path)

    -- extract ---@output
    local output = main_src:match("^%-%-%-%s*@output%s+(.-)%s*$")
    if not output then
        -- check all lines
        for line in (main_src .. "\n"):gmatch("([^\n]*)\n") do
            output = line:match("^%-%-%-%s*@output%s+(.-)%s*$")
            if output then break end
        end
    end
    if not output or output == "" then
        error("no ---@output directive found in " .. main_path)
    end

    local out_path = build_dir .. "/" .. output

    -- process main.lua line by line
    local result_lines = {}
    for line in (main_src .. "\n"):gmatch("([^\n]*)\n") do
        local bundle = line:match("^%s*%-%-%-%s*@bundle%s+(.-)%s*$")
        if line:match("^%s*%-%-%-%s*@output") then
            -- drop @output directive from output
        elseif bundle then
            local ok, res = pcall(process_bundle, src_root, bundle)
            if not ok then
                io.stderr:write("warning: skipping bundle '" .. bundle .. "': " .. res .. "\n")
            else
                result_lines[#result_lines + 1] = "-- [bundle: " .. bundle .. "]"
                result_lines[#result_lines + 1] = res
                result_lines[#result_lines + 1] = ""
            end
        else
            result_lines[#result_lines + 1] = line
        end
    end

    write_file(out_path, table.concat(result_lines, "\n"))
    print("built:  " .. main_path .. " to " .. out_path)

    -- deploy
    local sub = output:match("^(.+)[/\\][^/\\]+$")
    local dst_dir = deploy_root .. (sub and sub:gsub("/", "\\") .. "\\" or "")
    local cmd = 'xcopy /Y "' .. out_path:gsub("/", "\\") .. '" "' .. dst_dir .. '"'
    os.execute(cmd)
    print("deploy: " .. out_path .. " to " .. dst_dir)
end

-- ------------------------------------------------------------
--  Main
-- ------------------------------------------------------------

local failed = false
for _, src_root in ipairs(sources) do
    local ok, e = pcall(build_source, src_root)
    if not ok then
        io.stderr:write("error building '" .. src_root .. "': " .. tostring(e) .. "\n")
        failed = true
    end
end

if failed then
    io.stderr:write("build finished with errors.\n")
    os.exit(1)
else
    print("all builds complete.")
end