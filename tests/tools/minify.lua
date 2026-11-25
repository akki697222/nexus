-- tools/minify.lua: smaller source that runs the same. Tricky tokens
-- (long strings and comments, escapes, numbers next to dots, operators that
-- would merge), then the kernel and the installer as a whole.
-- Run from the Nexus directory: lua tests/tools/minify.lua
local minify = assert(loadfile("tools/minify.lua"))()

local function run(src)
    local out = {}
    local env = setmetatable({ emit = function(v) out[#out + 1] = tostring(v) end }, { __index = _G })
    assert(load(src, "=t", "t", env))()
    return table.concat(out, "|")
end

local sample = [==[
-- first remark
local s = [[long -- not a comment
  keeps   its spaces]] --[[ second
remark ]] local t = [=[with ]] inside]=]
emit(s) emit(t)
emit("quote \" and -- and [[ ]]") emit('single \' \n \z
      skipped')
local a, b = 1, 2
emit(a .. b) emit(1 .. 2) emit(a - -b) emit(a- -b) emit(2^-1)
emit(0x10 .. 0xA.8p1 .. 1e2 .. .5 .. 3.)
local x = { [ [[k]] ] = 1 }
emit(x.k) emit(#x)
emit(7 // 2) emit(1 << 3) emit(a == b) emit(a ~= b) emit(a <= b) emit(~a)
local f = function(...) return select("#", ...) end
emit(f(1, nil, 3))
goto done
emit("skipped")
::done::
emit(a
)
]==]
local small = minify(sample)
assert(#small < #sample, "smaller")
assert(run(small) == run(sample), run(small) .. "\n~=\n" .. run(sample))
assert(not small:find("remark", 1, true), "comments go")
assert(small:find("[[long -- not a comment\n  keeps   its spaces]]", 1, true), "long strings stay")
-- line breaks: kept by default with keepLines, else one line
assert(select(2, minify(sample, true):gsub("\n", "")) > 10)
assert(run(minify(sample, true)) == run(sample))

-- whole programs still compile; the installer is minified this way
local function read(path)
    local f = assert(io.open(path, "rb"))
    local v = f:read("a")
    f:close()
    return v
end
local kernel = read("build/kernel.lua")
assert(load(minify(kernel), "=kernel", "t", {}), "the minified kernel compiles")
local mk = assert(loadfile("tools/mkinstaller.lua"))()
local plain, built = mk.build({ plain = true }), mk.build()
assert(built:sub(1, #mk.HEADER) == mk.HEADER, "the header with the copyright notices")
assert(built == mk.HEADER .. minify(plain, true))
assert(#built < #plain * 0.7, "the installer gets much smaller")

print("minify tests passed")
