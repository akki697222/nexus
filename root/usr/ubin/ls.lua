local fs = require("filesystem")
---@type process
local process = require("process")
local permission = require("permission")
local colors = require("colors")
local argparse = require("argparse")
local util = require("util")

local parser = argparse("list", "List")
parser:argument("directory", "directory."):args("?")
parser:flag("-a --all", "Includes hidden files")
parser:flag("-l", "Long list")

local args = parser:parse({...})
local directory = args.directory
local show_all = args.all
local long_list = args.l

--print(util.encodeTable(args))

if not directory then
    directory = process.cwd()
end

directory = fs.resolve(directory)
local iter, err = fs.list(directory)

if not iter then
    print("ls: cannot access '" .. directory .. "': " .. tostring(err))
    return
end

local list = {}
for name in iter do
    table.insert(list, name)
end
table.sort(list)

local function formatTime(epoch)
    local date = os.date("*t", epoch)
    return string.format("%04d-%02d-%02d %02d:%02d",
        date.year, date.month, date.day, date.hour, date.min)
end

local function styledPrint(tbl)
    -- Calculate column widths
    local widths = {}
    for _, row in ipairs(tbl) do
        for i, col in ipairs(row) do
            widths[i] = math.max(widths[i] or 0, #col)
        end
    end

    for _, row in ipairs(tbl) do
        local line = ""
        for i, col in ipairs(row) do
            -- Right align size, left align others
            if i == 4 then -- Size column
                line = line .. string.rep(" ", widths[i] - #col) .. col .. " "
            else
                line = line .. col .. string.rep(" ", widths[i] - #col) .. " "
            end
        end
        print(line)
    end
end


if long_list then
    local tbl = {}
    local items = 0
    local total_blocks = 0 -- Trying to replicate `total` line behavior broadly

    -- Sort logic ideally should be here but basic ipairs is okay for now
    -- Actually fs.list is an iterator in OpenOS but returns table in Onix?
    -- User snippet iterated it with ipairs(list), so fs.list returns a table here.

    for _, name in ipairs(list) do
        if not show_all and name:sub(1, 1) == "." then
            goto continue
        end

        local fullpath = fs.concat(directory, name) -- Use fs.concat instead of fs.combine based on init.lua usage
        local attr = fs.attributes(fullpath) --[[@as vnode]]
        if not attr then
            -- Might be a broken link or permission issue
            -- print("ls: cannot access '" .. name .. "': No such file or directory")
            -- Don't break output for one file, maybe print error to stderr?
            goto continue
        end

        local display_name = name
        if display_name:sub(-1) == "/" then
            display_name = display_name:sub(1, -2)
        end

        -- File Type
        local ftype = "-"
        if attr.type == "VDIR" then
            ftype = "d"
            display_name = colors.blue .. display_name .. colors.reset
        elseif attr.type == "VLNK" then
            ftype = "l"
            display_name = colors.cyan .. display_name .. colors.reset .. " -> " .. fs.readlink(fullpath)
        elseif attr.type == "VCHR" then
            ftype = "c"
            display_name = colors.bright_yellow .. display_name .. colors.reset
        elseif attr.type == "VBLK" then
            ftype = "b"
            display_name = colors.bright_yellow .. display_name .. colors.reset
        else
            display_name = colors.green .. display_name .. colors.reset
        end

        -- Permissions
        local mode = attr.mode or 0
        local perms = permission.toText(mode)

        -- Owner/Group (Mocked)
        local owner = tostring(attr.uid or "root")
        -- local uowner = user.getUserByUID(attr.uid) ... if implemented

        local group = tostring(attr.gid or "root")

        -- Size
        local size = tostring(attr.size or "?")

        -- Time
        local mtime = formatTime(attr.mtime and attr.mtime / 1000 or 0)

        table.insert(tbl, { ftype .. perms, owner, group, size, mtime, display_name })
        items = items + 1

        ::continue::
    end

    if items > 0 then
        print("total " .. items)
        styledPrint(tbl)
    end
else
    -- Short list
    local result = ""
    for _, name in ipairs(list) do
        if not show_all and name:sub(1, 1) == "." then
            goto continue
        end

        local display_name = name
        if display_name:sub(-1) == "/" then
            display_name = display_name:sub(1, -2)
        end

        local fullpath = fs.concat(directory, name)
        if fs.isDirectory(fullpath) then
            display_name = colors.blue .. display_name .. colors.reset
        elseif fs.isLink(fullpath) then
            display_name = colors.cyan .. display_name .. colors.reset
        elseif fs.can(fullpath, "x") then
            display_name = colors.green .. display_name .. colors.reset
        end

        result = result .. display_name .. "  "
        ::continue::
    end
    print(result)
end
