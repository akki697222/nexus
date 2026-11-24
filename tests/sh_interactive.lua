-- Interactive shell: persistent history and tab completion.
-- Run from the Nexus directory: lua tests/sh_interactive.lua
local source = assert(io.open("root/usr/bin/sh.lua")):read("a")

local files = {
    ["/home/u/.sh_history"] = "ls\ncd /tmp\n",
    ["/home/u/notes.txt"] = "x",
}
local dirs = { ["/"] = true, ["/home"] = true, ["/home/u"] = true, ["/home/u/docs"] = true,
    ["/usr/bin"] = true, ["/usr/ubin"] = true }
local listing = {
    ["/home/u"] = { "docs", "notes.txt", ".hidden" },
    ["/usr/bin"] = { "sh.lua", "edit.lua", "sudo.lua" },
    ["/usr/ubin"] = { "echo.lua", "env.lua", "ls.lua" },
}
local fs = {}
function fs.concat(...) return ((table.concat({ ... }, "/")):gsub("//+", "/")) end
function fs.exists(p) return files[p] ~= nil or dirs[p] == true end
function fs.isDirectory(p) return dirs[p] == true end
function fs.list(p)
    local names, i = listing[p], 0
    if not names then return nil, "no such directory" end
    return function() i = i + 1; return names[i] end
end
function fs.open(p, mode)
    if mode == "r" then
        local data = files[p]
        if not data then return nil end
        return { read = function() local d = data; data = nil; return d end, close = function() end }
    end
    if mode == "w" then files[p] = "" end
    return { write = function(_, s) files[p] = (files[p] or "") .. s end, close = function() end }
end

local inputs = { "echo one", "  ", "history" }
local seenOptions = {}
local output = {}
local env = setmetatable({}, { __index = _G })
env.require = function(name)
    if name == "colors" then return { green = "", bright_blue = "", reset = "", bold = "", red = "" } end
    if name == "filesystem" then return fs end
    if name == "process" then return { cwd = function() return "/home/u" end } end
    error(name)
end
env.os = {
    getenv = function(k) return ({ HOME = "/home/u", PATH = "/usr/ubin:/usr/bin" })[k] end,
    setenv = function() end,
    exit = function(code) error({ exit = code }, 0) end,
}
env.io = {
    write = function(...) output[#output + 1] = table.concat({ ... }) end,
    isatty = function() return true end,
    stderr = { write = function(_, s) output[#output + 1] = s end },
    read = function(fmt, options)
        seenOptions[#seenOptions + 1] = options
        return table.remove(inputs, 1)
    end,
}
env.print = function(...) output[#output + 1] = table.concat({ ... }, "\t") .. "\n" end
local chunk = assert(load(source, "=sh", "t", env))
local co = coroutine.create(chunk)
local ok, err = coroutine.resume(co, "-l")
while ok and coroutine.status(co) == "suspended" do ok, err = coroutine.resume(co) end
assert(not ok and type(err) == "table" and err.exit ~= nil, tostring(err))

-- 1. The line editor gets the loaded history and a completer.
local options = seenOptions[1]
assert(type(options) == "table" and options.history and options.complete, "interactive reads pass options")
assert(options.history[1] == "ls" and options.history[2] == "cd /tmp", "history loaded from ~/.sh_history")

-- 2. Entered commands are appended; blank lines are not.
assert(files["/home/u/.sh_history"] == "ls\ncd /tmp\necho one\nhistory\n", files["/home/u/.sh_history"])
local printed = table.concat(output)
assert(printed:find("    1  ls") and printed:find("    3  echo one"), printed)

-- 3. Completion: commands for the first word, paths after it.
local complete = options.complete
local function same(a, b) table.sort(a); table.sort(b); return table.concat(a, ",") == table.concat(b, ",") end
assert(same(complete("ed"), { "edit " }), table.concat(complete("ed"), ","))
assert(same(complete("e"), { "echo", "edit", "env", "eval", "exec", "exit", "export" }), table.concat(complete("e"), ","))
assert(same(complete("cat no"), { "cat notes.txt " }))
assert(same(complete("cd d"), { "cd docs/" }))
assert(same(complete("cat "), { "cat docs/", "cat notes.txt" }), "hidden files only on request")
assert(same(complete("cat ~/n"), { "cat ~/notes.txt " }))

-- 4. history -c empties the file.
inputs = { "history -c" }
co = coroutine.create(chunk)
ok, err = coroutine.resume(co)
while ok and coroutine.status(co) == "suspended" do ok, err = coroutine.resume(co) end
assert(files["/home/u/.sh_history"] == "", files["/home/u/.sh_history"])

io.write("sh interactive tests passed\n")
