-- Shell language: control flow, expansions, functions, here-documents,
-- subshells, command substitution and pipelines. The shell runs against a
-- small in-memory kernel whose child processes really execute (a child
-- "sh -c" loads sh.lua again), one after another.
-- Run from the Nexus directory: lua tests/userland/sh_script.lua
local source = assert(io.open("root/usr/bin/sh.lua", "rb")):read("a")
local SH = "/usr/bin/sh.lua"

local K = { procs = {}, next_pid = 2, programs = {} }
local BASE_FILES = { [SH] = "" }
local BASE_DIRS = { ["/"] = true, ["/tmp"] = true, ["/usr"] = true, ["/usr/bin"] = true,
    ["/usr/ubin"] = true, ["/home"] = true }

local function normalize(path, cwd)
    if path:sub(1, 1) ~= "/" then path = (cwd == "/" and "" or cwd) .. "/" .. path end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then parts[#parts] = nil
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return "/" .. table.concat(parts, "/")
end

local function desc_read(d, fmt)
    if not d then return nil end
    local data
    if d.kind == "pipe" then data = d.pipe.buffer
    elseif d.kind == "file" then data = (K.files[d.path] or ""):sub(d.pos)
    elseif d.kind == "input" then data = d.data:sub(d.pos)
    else return nil end
    local function consume(n)
        if d.kind == "pipe" then d.pipe.buffer = d.pipe.buffer:sub(n + 1) else d.pos = d.pos + n end
    end
    fmt = fmt or "*l"
    if fmt == "*a" or fmt == "a" then
        consume(#data)
        return data
    end
    if data == "" then return nil end
    if type(fmt) == "number" then
        local s = data:sub(1, fmt)
        consume(#s)
        return s
    end
    local nl = data:find("\n", 1, true)
    local line = nl and data:sub(1, nl) or data
    consume(#line)
    if fmt == "*L" or fmt == "L" then return line end
    return (line:gsub("\n$", ""))
end

local function desc_write(d, s)
    if not d then return nil, "Bad file descriptor" end
    if d.kind == "pipe" then d.pipe.buffer = d.pipe.buffer .. s
    elseif d.kind == "file" then K.files[d.path] = (K.files[d.path] or "") .. s
    elseif d.kind == "sink" then d.out[#d.out + 1] = s
    else return nil, "Bad file descriptor" end
    return true
end

local function make_env(proc)
    local function alloc(d, min)
        local n = min or 0
        while proc.fds[n] do n = n + 1 end
        proc.fds[n] = d
        return n
    end
    local fs = {}
    fs.concat = function(...) return (table.concat({ ... }, "/"):gsub("//+", "/")) end
    fs.resolve = function(p) return normalize(p, proc.cwd) end
    fs.realPath = fs.resolve
    fs.exists = function(p)
        local a = normalize(p, proc.cwd)
        return K.files[a] ~= nil or K.dirs[a] == true
    end
    fs.isDirectory = function(p) return K.dirs[normalize(p, proc.cwd)] == true end
    fs.can = function() return true end
    fs.attributes = function(p)
        local a = normalize(p, proc.cwd)
        if K.dirs[a] then return { type = "VDIR", size = 0, mtime = 0 } end
        if K.files[a] then return { type = "VREG", size = #K.files[a], mtime = 0 } end
    end
    fs.list = function(p)
        local a = normalize(p, proc.cwd)
        if not K.dirs[a] then return nil, "Not a directory" end
        local prefix = a == "/" and "/" or (a .. "/")
        local names = {}
        local function consider(path)
            if path ~= a and path:sub(1, #prefix) == prefix and not path:sub(#prefix + 1):find("/") then
                names[#names + 1] = path:sub(#prefix + 1)
            end
        end
        for path in pairs(K.files) do consider(path) end
        for path in pairs(K.dirs) do consider(path) end
        table.sort(names)
        local i = 0
        return function() i = i + 1; return names[i] end
    end
    fs.open = function(p, mode)
        local a = normalize(p, proc.cwd)
        mode = (mode or "r"):sub(1, 1)
        if mode == "r" and not K.files[a] then return nil, "No such file or directory" end
        if mode == "w" then K.files[a] = "" elseif mode == "a" then K.files[a] = K.files[a] or "" end
        local n = alloc({ kind = "file", path = a, pos = 1, flag = mode }, 0)
        local f = {}
        function f.fd() return n end
        function f.read(_, fmt) return desc_read(proc.fds[n], fmt) end
        function f.write(_, s) return desc_write(proc.fds[n], s) end
        function f.close() proc.fds[n] = nil end
        return f
    end
    fs.read = function(fd, fmt) return desc_read(proc.fds[fd], fmt) end
    fs.write = function(fd, s) return desc_write(proc.fds[fd], s) end
    fs.close = function(fd) proc.fds[fd] = nil; return true end
    fs.dup = function(fd, min)
        local d = proc.fds[fd]
        if not d then return nil, "Bad file descriptor" end
        return alloc(d, min or 0)
    end
    fs.dup2 = function(src, dst)
        local d = proc.fds[src]
        if not d then return nil, "Bad file descriptor" end
        proc.fds[dst] = d
        return dst
    end
    fs.pipe = function()
        local pipe = { buffer = "" }
        return alloc({ kind = "pipe", pipe = pipe, flag = "r" }, 3), alloc({ kind = "pipe", pipe = pipe, flag = "w" }, 3)
    end
    fs.remove = function(p) K.files[normalize(p, proc.cwd)] = nil; return true end

    local P = {}
    P.cwd = function(path)
        if path then
            local a = normalize(path, proc.cwd)
            if not K.dirs[a] then return nil, "No such directory" end
            proc.cwd = a
            return a
        end
        return proc.cwd
    end
    P.getCurrentPID = function() return proc.pid end
    P.getEnviron = function()
        local c = {}
        for k, v in pairs(proc.env) do c[k] = v end
        return c
    end
    P.exec = function(path, args) return K.start(proc, path, args, nil) end
    P.spawn = function(path, args, stdio)
        local pid, err = K.start(proc, path, args, stdio or {})
        if pid == -1 then return -1, err end
        return pid, nil, K.procs[pid].instance
    end
    P.wait = function(pid)
        local c = K.procs[pid]
        if not c then return "No such process" end
        return nil, c.status
    end
    P.get = function(pid) return K.procs[pid] end
    P.kill = function() return true end

    local env = setmetatable({}, { __index = _G })
    env.require = function(name)
        if name == "colors" then return setmetatable({}, { __index = function() return "" end }) end
        if name == "filesystem" then return fs end
        if name == "process" then return P end
        error("unexpected require " .. name)
    end
    env.os = {
        getenv = function(k) return proc.env[k] end,
        setenv = function(k, v) proc.env[k] = v ~= nil and tostring(v) or nil end,
        exit = function(code) error({ exit = code or 0 }, 0) end,
    }
    env.io = {
        write = function(...)
            for _, s in ipairs({ ... }) do desc_write(proc.fds[1], tostring(s)) end
        end,
        read = function(fmt) return desc_read(proc.fds[0], fmt or "*l") end,
        isatty = function() return false end,
        stderr = { write = function(_, s) desc_write(proc.fds[2], tostring(s)) end },
    }
    env.print = function(...)
        local t = {}
        for i, v in ipairs({ ... }) do t[i] = tostring(v) end
        desc_write(proc.fds[1], table.concat(t, "\t") .. "\n")
    end
    return env
end

function K.run(proc, path, args)
    local body
    local env = make_env(proc)
    if path == SH then
        local fn = assert(load(source, "=sh", "t", env))
        body = function() return fn(table.unpack(args)) end
    else
        local program = assert(K.programs[path], "no program " .. path)
        body = function() return program(args, env) end
    end
    local co = coroutine.create(body)
    local ok, err = coroutine.resume(co)
    while ok and coroutine.status(co) == "suspended" do ok, err = coroutine.resume(co) end
    if not ok then
        if type(err) == "table" and err.exit then return err.exit end
        error(err, 0)
    end
    return 0
end

function K.start(parent, path, args, stdio)
    local a = normalize(path, parent.cwd)
    if not K.files[a] then return -1, "No such file" end
    local pid = K.next_pid
    K.next_pid = pid + 1
    local fds = {}
    if stdio then
        for i = 0, 2 do fds[i] = parent.fds[i] end
        for dst, src in pairs(stdio) do fds[dst] = parent.fds[src] end
    else
        for k, d in pairs(parent.fds) do fds[k] = d end
    end
    local env = {}
    for k, v in pairs(parent.env) do env[k] = v end
    local proc = { pid = pid, instance = pid + 1000, fds = fds, env = env, cwd = parent.cwd }
    K.procs[pid] = proc
    proc.status = K.run(proc, a, args or {})
    return pid
end

local function program(name, fn)
    local path = "/usr/ubin/" .. name .. ".lua"
    BASE_FILES[path] = ""
    K.programs[path] = fn
end

program("cat", function(args, env)
    if #args == 0 then
        env.io.write(env.io.read("*a") or "")
        return
    end
    local status = 0
    for _, name in ipairs(args) do
        local data = K.files[normalize(name, "/")]
        if data then env.io.write(data)
        else
            env.io.stderr:write("cat: " .. name .. ": No such file or directory\n")
            status = 1
        end
    end
    if status ~= 0 then env.os.exit(status) end
end)
program("upper", function(_, env) env.io.write((env.io.read("*a") or ""):upper()) end)
program("args", function(args, env) env.io.write(table.concat(args, "|") .. "\n") end)
program("fail", function(args, env) env.os.exit(tonumber(args[1]) or 1) end)

local function sh(script, options)
    options = options or {}
    K.files, K.dirs = {}, {}
    for k, v in pairs(BASE_FILES) do K.files[k] = v end
    for k, v in pairs(options.files or {}) do K.files[k] = v end
    for k, v in pairs(BASE_DIRS) do K.dirs[k] = v end
    local out, err = {}, {}
    local root = {
        pid = 1,
        fds = {
            [0] = { kind = "input", data = options.stdin or "", pos = 1, flag = "r" },
            [1] = { kind = "sink", out = out, flag = "w" },
            [2] = { kind = "sink", out = err, flag = "w" },
        },
        env = { PATH = "/usr/ubin:/usr/bin", HOME = "/home" },
        cwd = "/",
    }
    local args = options.args
    if not args then
        args = { "-c", script }
        for _, a in ipairs(options.tail or {}) do args[#args + 1] = a end
    end
    local pid = K.start(root, SH, args)
    return K.procs[pid].status, table.concat(out), table.concat(err)
end

local failures = 0
local function check(name, script, expected, expected_status, options)
    local ok, status, out, err = pcall(sh, script, options)
    if not ok then
        io.stderr:write("FAIL " .. name .. ": " .. tostring(status) .. "\n")
        failures = failures + 1
        return
    end
    if out ~= expected or (expected_status ~= nil and status ~= expected_status) then
        io.stderr:write(("FAIL %s\n  expected %q (status %s)\n  got      %q (status %s)\n  stderr   %q\n")
            :format(name, expected, tostring(expected_status), out, tostring(status), err))
        failures = failures + 1
        return
    end
    print("ok - " .. name)
end

check("if / elif / else", [[
x=2
if [ $x -eq 1 ]; then echo one; elif [ $x -eq 2 ]; then echo two; else echo other; fi]], "two\n", 0)

check("while loop with arithmetic", [[
i=0
while [ $i -lt 3 ]; do echo $i; i=$((i + 1)); done]], "0\n1\n2\n", 0)

check("until loop", [[n=3; until [ $n -eq 0 ]; do printf '%s ' $n; n=$((n - 1)); done; echo]], "3 2 1 \n", 0)

check("for over words keeps quoted words whole", [[for f in a "b c" d; do echo "[$f]"; done]],
    "[a]\n[b c]\n[d]\n", 0)

check("for without in walks the positional parameters", nil, "x\ny z\n", 0,
    { args = { "-c", "for a; do echo $a; done", "name", "x", "y z" } })

check("case with patterns and alternatives", [[
for w in apple Banana cherry 42 zzz; do
    case $w in
        a*) echo A ;;
        [Bb]*|c*) echo BC ;;
        [0-9]*) echo num ;;
        *) echo other
    esac
done]], "A\nBC\nBC\nnum\nother\n", 0)

check("break and continue with levels", [[
for i in 1 2 3; do
    for j in 1 2 3; do
        [ $j -eq 2 ] && continue
        [ $i -eq 2 ] && break 2
        echo $i$j
    done
done
echo after]], "11\n13\nafter\n", 0)

check("&&, || and !", [[true && echo a; false && echo b; false || echo c; ! false && echo d; true || echo e]],
    "a\nc\nd\n", 0)

check("functions take arguments, return a status and restore locals", [[
greet() {
    local who=$1
    echo "hi $who ($#)"
    return 3
}
who=outer
greet bob x
echo $? $who $1]], "hi bob (2)\n3 outer top\n", 0, { tail = { "n", "top" } })

check("recursion through command substitution", [[
fact() { if [ $1 -le 1 ]; then echo 1; else echo $(( $1 * $(fact $(( $1 - 1 ))) )); fi; }
fact 5]], "120\n", 0)

check("parameter expansion operators", [[
unset u; e=; v=hello.tar.gz
echo ${u:-def} ${e:-empty} ${e-unset} ${v:+set} ${#v}
echo ${v%.*} ${v%%.*} ${v#*.} ${v##*.}
echo ${u:=assigned} $u]], "def empty set 12\nhello.tar hello tar.gz gz\nassigned assigned\n", 0)

check("field splitting follows IFS", [[
x='a  b   c'
for w in $x; do echo "<$w>"; done
echo "$x"
IFS=:
y=1:2::3
for w in $y; do echo "[$w]"; done]], "<a>\n<b>\n<c>\na  b   c\n[1]\n[2]\n[]\n[3]\n", 0)

check("\"$@\" keeps parameters, \"$*\" joins them", nil, "[a b]\n[c]\n{a b c}\n0\n", 0, {
    args = { "-c", [[for a in "$@"; do echo "[$a]"; done; for a in "$*"; do echo "{$a}"; done; set --; for a in "$@"; do echo x; done; echo $#]], "n", "a b", "c" } })

check("command substitution", [[
x=$(echo hello); y=`echo world`
echo "$x $y"
echo $(echo $(echo nested))
z=$(printf 'a\n\n')
echo "[$z]"
echo "$(echo "inner quoted")"]], "hello world\nnested\n[a]\ninner quoted\n", 0)

check("command substitution of programs and pipelines", [[
echo "$(echo abc | upper)"
n=$(args a b)
echo "$n" $?
s=$(fail 4)
echo $?]], "ABC\na|b 0\n4\n", 0)

check("arithmetic expansion", [[
echo $((1 + 2 * 3)) $(( (1+2)*3 )) $((7/2)) $((-7/2)) $((-7%3)) $((2**10)) $((1<2 && 3>2))
echo $((x=5, x*2)) $((0 ? 1 : 2)) $((0x10 + 010)) $((~0)) $((5>>1))
i=0; : $((i+=5)); : $((i++)); echo $i $((i--)) $i]],
    "7 9 3 -3 -1 1024 1\n10 2 24 -1 2\n6 6 5\n", 0)

check("here-documents", "name=world\ncat <<EOF\nhello $name\n  literal \\$name\nEOF\n"
    .. "cat <<'EOF'\nno $name expansion\nEOF\ncat <<-EOF\n\t\ttabs stripped\n\tEOF\necho end",
    "hello world\n  literal $name\nno $name expansion\ntabs stripped\nend\n", 0)

check("while read from a here-document", "while read a b; do echo \"$b-$a\"; done <<EOF\n1 one\n2 two\nEOF",
    "one-1\ntwo-2\n", 0)

check("file redirections", [[
echo first > /tmp/f
echo second >> /tmp/f
cat < /tmp/f
cat /tmp/missing 2>/tmp/err || echo failed
cat /tmp/err]], "first\nsecond\nfailed\ncat: /tmp/missing: No such file or directory\n", 0)

check("2>&1 and >&2 inside a pipeline stage", [[{ echo a; echo b >&2; } 2>&1 | upper]], "A\nB\n", 0)

check("subshells are isolated", [[x=1; (x=2; echo in $x); echo out $x; (exit 3); echo $?]],
    "in 2\nout 1\n3\n", 0)

check("pipeline into a while loop", [[printf 'a\nb\n' | while read l; do echo "<$l>"; done]],
    "<a>\n<b>\n", 0)

check("set -e stops at the first failure outside conditions", [[
set -e
false || true
if false; then :; fi
echo still
false
echo never]], "still\n", 1)

check("set -u rejects unset parameters", [[set -u; echo ${undefined_var}; echo never]], "", 1)

check("source and eval run in the current shell", [[
printf 'libvar=42\nlibfn() { echo lib $1; }\n' > /tmp/lib.sh
. /tmp/lib.sh
libfn $libvar
cmd='echo evaluated'
eval "$cmd"
eval 'for i in 1 2; do [ $i = 2 ] && break; echo e$i; done']], "lib 42\nevaluated\ne1\n", 0)

check("unterminated compound command is a syntax error", "if true; then echo x", "", 2)
check("syntax errors stop the line before it runs", "echo ok; fi", "", 2)
check("unexpected tokens", "echo a ;; echo b", "", 2)

check("test and [ operators", [[
[ -z "" ] && [ -n x ] && [ a = a ] && [ a != b ] && [ 3 -gt 2 ] && [ ! 1 -eq 2 ] &&
test -d / && test -f /usr/bin/sh.lua && [ \( 1 -eq 1 \) -a 2 -lt 1 -o x ] && echo all
[ 1 -eq x ]; echo $?]], "all\n2\n", 0)

check("printf formats", [[printf '%s=%d|%5s|%-3s|%x|%%|%b\n' a 42 r l 255 'x\ty'; printf '%s,' 1 2 3; echo]],
    "a=42|    r|l  |ff|%|x\ty\n1,2,3,\n", 0)

check("read splits on IFS and keeps the rest in the last name", "IFS=: read a b c <<EOF\nx:y:z:w\nEOF\n"
    .. "echo \"$a|$b|$c\"\nread -r line <<'EOF'\n  back\\slash  \nEOF\necho \"[$line]\"",
    "x|y|z:w\n[back\\slash]\n", 0)

check("type and command -v", [[f() { :; }; type f; type cd; command -v echo; command -v cat]],
    "f is a function\ncd is a shell builtin\necho\n/usr/ubin/cat.lua\n", 0)

check("background jobs and wait", [[args bg & wait; echo done $?]], "bg\ndone 0\n", 0)

check("shift and set --", [[set -- a b c; shift; echo $# $1; shift 2; echo $#]], "2 b\n0\n", 0)

check("exec redirects the shell itself", [[exec 3>/tmp/x; echo hi >&3; cat /tmp/x]], "hi\n", 0)

check("prefix assignments last for one command", [[f() { echo "$V"; }; V=tmp f; echo "[$V]"]],
    "tmp\n[]\n", 0)

check("line continuation and comments", "echo a \\\n b # comment\n# full line\necho c",
    "a b\nc\n", 0)

check("functions are visible in pipelines and subshells", [[
up() { echo "$1" | upper; }
up hi | cat
( up there )]], "HI\nTHERE\n", 0)

check("exit status of the last command", [[fail 5]], "", 5)

do
    local status, out = sh(nil, { args = {}, stdin = "if true\nthen\necho yes\nfi\nfor i in 1 2\ndo echo $i\ndone\n" })
    if status == 0 and out:find("yes\n", 1, true) and out:find("1\n2\n", 1, true) and out:find("> ", 1, true) then
        print("ok - interactive input continues unfinished commands")
    else
        io.stderr:write(("FAIL interactive continuation: %q (status %s)\n"):format(out, tostring(status)))
        failures = failures + 1
    end
end

if failures > 0 then
    io.stderr:write(failures .. " shell script test(s) failed\n")
    os.exit(1)
end
print("all shell script tests passed")
