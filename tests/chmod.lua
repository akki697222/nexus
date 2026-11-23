-- chmod: octal and symbolic modes, -R, -v/-c/-f, --reference, links.
-- Run from the Nexus directory: lua tests/chmod.lua
local source = assert(io.open("root/usr/ubin/chmod.lua")):read("a")

-- nodes: path -> { type, mode (Nexus digits), link }
local nodes, children, denied
local function reset()
    nodes = {
        ["/"] = { type = "VDIR", mode = 755 },
        ["/f"] = { type = "VREG", mode = 644 },
        ["/d"] = { type = "VDIR", mode = 755 },
        ["/d/a"] = { type = "VREG", mode = 600 },
        ["/d/sub"] = { type = "VDIR", mode = 700 },
        ["/d/sub/b"] = { type = "VREG", mode = 644 },
        ["/d/ln"] = { type = "VLNK", mode = 777, link = "/f" },
        ["/lnk"] = { type = "VLNK", mode = 777, link = "f" },
        ["/ro"] = { type = "VREG", mode = 644 },
    }
    children = { ["/"] = { "f", "d", "lnk", "ro" }, ["/d"] = { "a", "sub", "ln" }, ["/d/sub"] = { "b" } }
    denied = { ["/ro"] = "Read-only file system" }
end
local fs = {}
function fs.attributes(p) local n = nodes[p]; if n then return { type = n.type, mode = n.mode, link = n.link } end end
function fs.isDirectory(p) return nodes[p] and nodes[p].type == "VDIR" end
function fs.concat(a, b) return ((a .. "/" .. b):gsub("//+", "/")) end
function fs.path(p) local d = p:match("^(.*)/[^/]*$"); return (d == nil or d == "") and "/" or d end
function fs.list(p)
    local names, i = children[p], 0
    if not names then return nil end
    return function() i = i + 1; return names[i] end
end
function fs.chmod(p, mode)
    if denied[p] then return nil, denied[p] end
    nodes[p].mode = mode
    return true
end

local function chmod(...)
    local out, err = {}, {}
    local env = setmetatable({
        require = function(n) assert(n == "filesystem"); return fs end,
        io = { write = function(...) out[#out + 1] = table.concat({ ... }) end,
               stderr = { write = function(_, s) err[#err + 1] = s end } },
        os = { exit = function(code) error({ exit = code }, 0) end },
    }, { __index = _G })
    local ok, e = pcall(assert(load(source, "=chmod", "t", env)), ...)
    local code = (not ok and type(e) == "table") and e.exit or (ok and 0) or error(e)
    return code, table.concat(out), table.concat(err)
end

local function mode(spec, start, kind)
    reset()
    nodes["/f"].mode = start
    nodes["/f"].type = kind or "VREG"
    local code, _, err = chmod(spec, "/f")
    assert(code == 0, spec .. ": " .. err)
    return nodes["/f"].mode
end

-- octal
assert(mode("755", 644) == 755)
assert(mode("0640", 755) == 640)
assert(mode("4755", 755) == 4755)
assert(mode("0", 755) == 0)
-- symbolic
assert(mode("u+x", 644) == 744)
assert(mode("go-w", 666) == 644)
assert(mode("a=r", 755) == 444)
assert(mode("g=u", 754) == 774)
assert(mode("u+s", 755) == 4755)
assert(mode("+t", 777, "VDIR") == 1777)
assert(mode("a-x,u+x", 777) == 766)
assert(mode("u=rwx,g=rx,o=", 0) == 750)
assert(mode("ug+rw-x", 711) == 661)
-- no class: umask 022 applies
assert(mode("+x", 644) == 755)
assert(mode("+w", 444) == 644)
assert(mode("=rw", 777) == 644)
assert(mode("-w", 666) == 466)
-- X: only directories or files already executable by someone
assert(mode("a+X", 644) == 644)
assert(mode("a+X", 744) == 755)
assert(mode("a+X", 600, "VDIR") == 711)
-- '=' on a directory keeps setgid unless named
assert(mode("u=rwx,go=rx", 2700, "VDIR") == 2755)
assert(mode("g-s", 2755, "VDIR") == 755)

-- invalid modes
reset()
local code, _, err = chmod("u+q", "/f")
assert(code == 1 and err:find("invalid mode"), err)
code, _, err = chmod("8888", "/f")
assert(code == 1 and err:find("invalid mode"))
code, _, err = chmod("17777", "/f")
assert(code == 1 and err:find("invalid mode"))
code, _, err = chmod("755")
assert(code == 1 and err:find("missing operand"))

-- -R: recursion does not follow links met on the way
reset()
code = chmod("-R", "go-rwx", "/d")
assert(code == 0)
assert(nodes["/d"].mode == 700 and nodes["/d/a"].mode == 600 and nodes["/d/sub/b"].mode == 600)
assert(nodes["/f"].mode == 644, "link inside the tree must not be followed")
assert(nodes["/d/ln"].mode == 777)

-- an operand that is a link changes its target
reset()
assert(chmod("600", "/lnk") == 0)
assert(nodes["/f"].mode == 600 and nodes["/lnk"].mode == 777)

-- -v / -c / -f
reset()
local out
code, out = chmod("-v", "u+x", "/f")
assert(out == "mode of '/f' changed from 0644 (rw-r--r--) to 0744 (rwxr--r--)\n", out)
code, out = chmod("-c", "u+x", "/f")
assert(out == "", "-c is silent when nothing changes")
code, out = chmod("-v", "u+x", "/f")
assert(out == "mode of '/f' retained as 0744 (rwxr--r--)\n", out)
code, out = chmod("-v", "4755", "/f")
assert(out:find("to 4755 %(rwsr%-xr%-x%)"), out)
code, out = chmod("-v", "1644", "/d")
assert(out:find("%(rw%-r%-%-r%-T%)"), out)
code, _, err = chmod("-f", "755", "/missing")
assert(code == 1 and err == "")
code, _, err = chmod("755", "/missing")
assert(code == 1 and err:find("cannot access '/missing'"))

-- --reference
reset()
nodes["/d/a"].mode = 640
assert(chmod("--reference=/d/a", "/f") == 0 and nodes["/f"].mode == 640)

-- errors from the kernel are reported, other operands still processed
reset()
code, _, err = chmod("700", "/ro", "/f")
assert(code == 1 and err:find("changing permissions of '/ro': Read%-only file system"))
assert(nodes["/f"].mode == 700)

io.write("chmod tests passed\n")
