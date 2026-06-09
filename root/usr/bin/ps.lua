-- ps.lua  –  coreutils ps 互換プロセス一覧
local process  = require("process")
local user     = require("user")
local argparse = require("argparse")

-- ────────────────────────────────────────────────────────────
-- BSD スタイル（ダッシュなし "aux" など）→ POSIX スタイルへ正規化
-- ────────────────────────────────────────────────────────────
local BSD_FLAGS = { a=true, u=true, x=true, e=true, f=true,
                    l=true, j=true, d=true, A=true }

local function normalize_args(raw)
    local out = {}
    for _, arg in ipairs(raw) do
        if not arg:match("^%-") and #arg > 0 then
            local all_flags = true
            for c in arg:gmatch(".") do
                if not BSD_FLAGS[c] then all_flags = false; break end
            end
            table.insert(out, all_flags and ("-" .. arg) or arg)
        else
            table.insert(out, arg)
        end
    end
    return out
end

-- ────────────────────────────────────────────────────────────
-- オプション定義
-- ────────────────────────────────────────────────────────────
local parser = argparse("ps", "Report a snapshot of the current processes")

-- 選択
parser:flag("-e -A",  "Select all processes")
parser:flag("-a",     "Select all processes with a terminal, except session leaders")
parser:flag("-d",     "Select all processes except session leaders")
parser:flag("-x",     "Include processes without a controlling terminal")

-- フォーマット
parser:flag("-f",     "Full-format listing  (UID PID PPID C STIME TTY TIME CMD)")
parser:flag("-l",     "Long format          (F S UID PID PPID C PRI NI ADDR SZ TTY TIME CMD)")
parser:flag("-u",     "User-oriented format (USER PID %%CPU %%MEM VSZ RSS TTY STAT START TIME COMMAND)")
parser:flag("-j",     "Jobs format          (PID PGID SID TTY TIME CMD)")

-- フィルタ
parser:option("-p", "Select by PID (comma-separated or repeated)")
    :argname("<pid>"):count("*")
parser:option("-U", "Select by real user name or ID")
    :argname("<user>"):count("*")

local ok, args = parser:pparse(normalize_args({...}))
if not ok then
    io.stderr:write("ps: " .. tostring(args) .. "\n")
    os.exit(1)
end

-- ────────────────────────────────────────────────────────────
-- ヘルパー
-- ────────────────────────────────────────────────────────────
local function username(uid)
    local u = user.getUserByUID(uid)
    return u and u.username or tostring(uid)
end

local function stat_str(proc)
    local s
    if     proc.status == "running"   then s = "R"
    elseif proc.status == "waiting"   then s = "S"
    elseif proc.status == "suspended" then s = "T"
    elseif proc.status == "dead"      then s = "Z"
    else                                   s = "?"
    end
    local n = proc.nice or 3
    if     n < 3 then s = s .. "<"   -- 高優先度
    elseif n > 3 then s = s .. "N"   -- 低優先度
    end
    return s
end

local function tty_name(tty)
    if not tty or tty == -1 then return "?" end
    return "tty" .. tostring(tty)
end

local function cmd_full(proc)
    local parts = { proc.path or "?" }
    for _, a in ipairs(proc.arguments or {}) do
        table.insert(parts, tostring(a))
    end
    return table.concat(parts, " ")
end

local function cmd_short(proc)
    local p = proc.path or "?"
    return p:match("([^/]+)$") or p
end

-- process.get() で取得できる追加フィールド
local function get_ppid(pid)
    local p = process.get(pid)
    return p and (p.parent or 0) or 0
end

local function get_pgid(pid)
    local p = process.get(pid)
    return p and (p.pgid  or pid) or pid
end

-- ────────────────────────────────────────────────────────────
-- プロセス選択
-- ────────────────────────────────────────────────────────────
local cur      = process.getCurrent()
local cur_tty  = cur and (cur.tty or -1) or -1

-- -p フィルタ（"1,2,3" や -p 1 -p 2 両対応）
local pid_set, has_pid = {}, false
if args.p then
    has_pid = true
    local list = type(args.p) == "table" and args.p or { args.p }
    for _, entry in ipairs(list) do
        for tok in tostring(entry):gmatch("[^,]+") do
            local n = tonumber(tok)
            if n then pid_set[n] = true end
        end
    end
end

-- -U フィルタ
local uid_set, has_uid = {}, false
if args.U then
    has_uid = true
    local list = type(args.U) == "table" and args.U or { args.U }
    for _, name in ipairs(list) do
        local u = user.getUser(tostring(name))
        if u then uid_set[u.uid] = true end
    end
end

local filtered = {}
for _, proc in ipairs(process.list()) do
    local tty = proc.tty or -1
    local sel

    if has_pid then
        sel = pid_set[proc.pid] == true
    elseif has_uid then
        sel = uid_set[proc.uid] == true
    elseif args.e then           -- -e / -A : 全プロセス
        sel = true
    elseif args.x then           -- -x [+a] : TTY なしも含む
        sel = (not args.a) or (args.a and true)
        sel = true
    elseif args.a or args.d then -- -a / -d : TTY 有りのみ
        sel = (tty ~= -1)
    else                         -- デフォルト : 現在の TTY のみ
        sel = (tty == cur_tty)
    end

    if sel then table.insert(filtered, proc) end
end

table.sort(filtered, function(a, b) return a.pid < b.pid end)

-- ────────────────────────────────────────────────────────────
-- 出力
-- ────────────────────────────────────────────────────────────

if args.u then
    -- USER PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
    print(string.format("%-8s %5s %4s %4s %6s %5s %-8s %-5s %-5s %-5s %s",
        "USER","PID","%CPU","%MEM","VSZ","RSS","TTY","STAT","START","TIME","COMMAND"))
    for _, p in ipairs(filtered) do
        print(string.format("%-8s %5d %4.1f %4.1f %6d %5d %-8s %-5s %-5s %-5s %s",
            username(p.uid):sub(1,8), p.pid,
            0.0, 0.0, 0, 0,
            tty_name(p.tty):sub(1,8),
            stat_str(p), "-", "0:00",
            cmd_full(p)))
    end

elseif args.f then
    -- UID        PID  PPID  C STIME TTY          TIME CMD
    print(string.format("%-8s %5s %5s %2s %-5s %-8s %-5s %s",
        "UID","PID","PPID","C","STIME","TTY","TIME","CMD"))
    for _, p in ipairs(filtered) do
        print(string.format("%-8s %5d %5d %2d %-5s %-8s %-5s %s",
            username(p.uid):sub(1,8), p.pid, get_ppid(p.pid),
            0, "-", tty_name(p.tty):sub(1,8), "0:00",
            cmd_full(p)))
    end

elseif args.l then
    -- F S UID        PID  PPID  C PRI  NI ADDR    SZ TTY      TIME CMD
    print(string.format("%1s %1s %-8s %5s %5s %2s %3s %3s %-5s %4s %-8s %-5s %s",
        "F","S","UID","PID","PPID","C","PRI","NI","ADDR","SZ","TTY","TIME","CMD"))
    for _, p in ipairs(filtered) do
        local n = p.nice or 3
        print(string.format("%1d %1s %-8s %5d %5d %2d %3d %3d %-5s %4d %-8s %-5s %s",
            4,
            stat_str(p):sub(1,1),
            username(p.uid):sub(1,8),
            p.pid, get_ppid(p.pid),
            0,
            20 + n,   -- PRI (Linux 方式: 80 + nice が RT 以外の標準値だが簡略化)
            n,        -- NI
            "-", 0,
            tty_name(p.tty):sub(1,8),
            "0:00",
            cmd_short(p)))
    end

elseif args.j then
    --   PID  PGID   SID TTY      TIME CMD
    print(string.format("%5s %5s %5s %-8s %-5s %s",
        "PID","PGID","SID","TTY","TIME","CMD"))
    for _, p in ipairs(filtered) do
        print(string.format("%5d %5d %5d %-8s %-5s %s",
            p.pid, get_pgid(p.pid),
            1,    -- SID: セッション ID（Nexus は未実装のため 1 固定）
            tty_name(p.tty):sub(1,8),
            "0:00", cmd_short(p)))
    end

else
    --   PID TTY          TIME CMD
    print(string.format("%5s %-8s %-5s %s",
        "PID","TTY","TIME","CMD"))
    for _, p in ipairs(filtered) do
        print(string.format("%5d %-8s %-5s %s",
            p.pid,
            tty_name(p.tty):sub(1,8),
            "0:00",
            cmd_short(p)))
    end
end