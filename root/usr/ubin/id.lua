-- id.lua - print real and effective user and group IDs
-- Copyright (c) 2026 akki697222
-- SPDX-License-Identifier: MIT
--
-- Supplementary groups are listed only when the group database is visible
-- to the process; the primary group is always shown.

local process = require("process")
local user = require("user")
local group = require("group")
local argparse = require("argparse")
local textio = require("textio")

local parser = argparse("id", "Print user and group information for USER, or for the current process.")
parser:flag("-u --user", "print only the effective user ID"):target("showUser")
parser:flag("-g --group", "print only the effective group ID"):target("showGroup")
parser:flag("-G --groups", "print all group IDs"):target("showGroups")
parser:flag("-n --name", "print a name instead of a number, for -ugG")
parser:flag("-r --real", "print the real ID instead of the effective ID, for -ugG")
parser:flag("-a", "ignored, for compatibility with other versions")
parser:flag("-z --zero", "delimit entries with NUL characters, not whitespace")
parser:argument("username", "user name"):args("?")

local opts = textio.parse("id", parser, { ... })
local only = (opts.showUser and 1 or 0) + (opts.showGroup and 1 or 0) + (opts.showGroups and 1 or 0)
if only > 1 then textio.fail("id", "cannot print \"only\" of more than one choice") end
if only == 0 and (opts.name or opts.real) then
    textio.fail("id", "cannot print only names or real IDs in default format")
end

local uid, gid, euid, egid, entry
if opts.username then
    entry = user.getUser(opts.username)
    if not entry then
        io.stderr:write("id: '" .. opts.username .. "': no such user\n")
        return 1
    end
    uid, gid, euid, egid = entry.uid, entry.gid, entry.uid, entry.gid
else
    local proc = process.getCurrent()
    uid, gid = proc.uid, proc.gid
    euid, egid = proc.euid or proc.uid, proc.egid or proc.gid
    entry = user.getUserByUID(euid)
end

local function userName(id)
    local u = user.getUserByUID(id)
    return u and u.username or nil
end
local function groupName(id)
    local g = group.getGroupByGID(id)
    return g and g.name or nil
end

local function groupsOf(name, primary)
    local list, seen = { primary }, { [primary] = true }
    for _, g in ipairs(group._groups or {}) do
        for _, m in ipairs(g.members or {}) do
            if m == name and not seen[g.gid] then
                seen[g.gid] = true
                list[#list + 1] = g.gid
            end
        end
    end
    return list
end

local function show(id, nameOf)
    if opts.name then return nameOf(id) or tostring(id) end
    return tostring(id)
end

local username = entry and entry.username
local term = opts.zero and "\0" or "\n"
if opts.showUser then
    io.write(show(opts.real and uid or euid, userName), term)
elseif opts.showGroup then
    io.write(show(opts.real and gid or egid, groupName), term)
elseif opts.showGroups then
    local out = {}
    for _, g in ipairs(groupsOf(username, egid)) do out[#out + 1] = show(g, groupName) end
    io.write(table.concat(out, opts.zero and "\0" or " "), term)
else
    local function pair(id, nameOf)
        local n = nameOf(id)
        return n and (id .. "(" .. n .. ")") or tostring(id)
    end
    local groups = {}
    for _, g in ipairs(groupsOf(username, egid)) do groups[#groups + 1] = pair(g, groupName) end
    local line = "uid=" .. pair(uid, userName) .. " gid=" .. pair(gid, groupName)
    if euid ~= uid then line = line .. " euid=" .. pair(euid, userName) end
    if egid ~= gid then line = line .. " egid=" .. pair(egid, groupName) end
    io.write(line, " groups=", table.concat(groups, ","), term)
end
return 0
