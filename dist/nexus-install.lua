-- nexus-install.lua - Nexus installer, minified (tools/mkinstaller.lua)
-- built from installer/src of https://github.com/akki697222/nexus
-- Copyright (c) 2026 akki697222 - SPDX-License-Identifier: MIT
-- SHA-2: Copyright (c) 2018 Phil Leblanc, after Roberto Ierusalimschy - MIT
local INSTALLER_REV=1
local CHANNEL_URL="https://raw.githubusercontent.com/akki697222/nexus/dev-oc/dist/channel.lua"
local CHANNEL="stable"
local STAGE="/.nexus-install"
local component,computer=component,computer
local crc32,softInflate,sha256,sha512
local meta,util,disk,img,net,source,install,tui,stage1,stage0
do
do
local crcTable={}
for i=0,255 do
local crc=i
for _=1,8 do
if crc&1==1 then crc=(crc>>1)~0xEDB88320 else crc=crc>>1 end
end
crcTable[i]=crc
end
crc32=function(data,crc)
crc=(crc or 0)~0xFFFFFFFF
for i=1,#data do
crc=crcTable[(crc~data:byte(i))&0xFF]~(crc>>8)
end
return(crc~0xFFFFFFFF)&0xFFFFFFFF
end
end
end
do
do
local byte,char,unpack=string.byte,string.char,table.unpack
local LBASE={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,
35,43,51,59,67,83,99,115,131,163,195,227,258}
local LEXT={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,
3,3,3,3,4,4,4,4,5,5,5,5,0}
local DBASE={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,
257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local DEXT={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,
7,7,8,8,9,9,10,10,11,11,12,12,13,13}
local ORDER={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
local function huffman(lengths,n)
local count,offs,symbol={},{},{}
for len=0,15 do count[len]=0 end
for sym=0,n-1 do count[lengths[sym]]=count[lengths[sym]]+1 end
local left=1
for len=1,15 do
left=left*2-count[len]
if left<0 then error("over-subscribed code",0)end
end
offs[1]=0
for len=1,14 do offs[len+1]=offs[len]+count[len]end
for sym=0,n-1 do
local len=lengths[sym]
if len~=0 then
symbol[offs[len]]=sym
offs[len]=offs[len]+1
end
end
return{count=count,symbol=symbol}
end
local fixedL,fixedD
local function fixed()
if not fixedL then
local l={}
for i=0,143 do l[i]=8 end
for i=144,255 do l[i]=9 end
for i=256,279 do l[i]=7 end
for i=280,287 do l[i]=8 end
fixedL=huffman(l,288)
local d={}
for i=0,29 do d[i]=5 end
fixedD=huffman(d,30)
end
return fixedL,fixedD
end
softInflate=function(data)
local pos,bitbuf,bitcnt=3,0,0
local cmf,flg=byte(data,1,2)
if not flg or cmf&15~=8 or(cmf*256+flg)%31~=0 or flg&32~=0 then
error("not a zlib stream",0)
end
local function bits(need)
while bitcnt<need do
local b=byte(data,pos)
if not b then error("truncated stream",0)end
pos=pos+1
bitbuf=bitbuf|(b<<bitcnt)
bitcnt=bitcnt+8
end
local v=bitbuf&((1<<need)-1)
bitbuf=bitbuf>>need
bitcnt=bitcnt-need
return v
end
local function decode(h)
local count,code,first,index=h.count,0,0,0
for len=1,15 do
if bitcnt==0 then
local b=byte(data,pos)
if not b then error("truncated stream",0)end
pos=pos+1
bitbuf,bitcnt=b,8
end
code=code|(bitbuf&1)
bitbuf=bitbuf>>1
bitcnt=bitcnt-1
local c=count[len]
if code-c<first then return h.symbol[index+code-first]end
index=index+c
first=(first+c)<<1
code=code<<1
end
error("invalid code",0)
end
local CH=1024
local done,buf,bn,base,n={},{},0,0,0
local s1,s2=1,0
local function flush(count)
for i=1,count do
s1=(s1+buf[i])%65521
s2=(s2+s1)%65521
end
done[#done+1]=char(unpack(buf,1,count))
base=base+count
bn=0
end
local function put(v)
bn=bn+1
buf[bn]=v
n=n+1
if bn==CH then flush(CH)end
end
local function get(k)
if k>base then return buf[k-base]end
return byte(done[(k-1)//CH+1],(k-1)%CH+1)
end
repeat
local last=bits(1)
local btype=bits(2)
if btype==0 then
bitbuf,bitcnt=0,0
local len,nlen=string.unpack("<I2I2",data,pos)
if len~0xFFFF~=nlen then error("bad stored block",0)end
pos=pos+4
if pos+len-1>#data then error("truncated stream",0)end
for i=pos,pos+len-1 do put(byte(data,i))end
pos=pos+len
elseif btype==3 then
error("invalid block type",0)
else
local lcode,dcode
if btype==1 then
lcode,dcode=fixed()
else
local nlen,ndist,ncode=bits(5)+257,bits(5)+1,bits(4)+4
local lengths={}
for i=0,18 do lengths[i]=0 end
for i=1,ncode do lengths[ORDER[i]]=bits(3)end
local lencode=huffman(lengths,19)
local i=0
while i<nlen+ndist do
local sym=decode(lencode)
if sym<16 then
lengths[i]=sym
i=i+1
else
local value,rep=0,0
if sym==16 then
if i==0 then error("repeat with no first length",0)end
value,rep=lengths[i-1],3+bits(2)
elseif sym==17 then
rep=3+bits(3)
else
rep=11+bits(7)
end
if i+rep>nlen+ndist then error("too many lengths",0)end
for _=1,rep do
lengths[i]=value
i=i+1
end
end
end
local dl={}
for k=0,ndist-1 do dl[k]=lengths[nlen+k]end
lcode,dcode=huffman(lengths,nlen),huffman(dl,ndist)
end
while true do
local sym=decode(lcode)
if sym<256 then
put(sym)
elseif sym==256 then
break
else
sym=sym-256
if sym>29 then error("bad length symbol",0)end
local len=LBASE[sym]+bits(LEXT[sym])
local dsym=decode(dcode)+1
if dsym>30 then error("bad distance symbol",0)end
local dist=DBASE[dsym]+bits(DEXT[dsym])
if dist>n then error("distance too far back",0)end
for _=1,len do put(get(n+1-dist))end
end
end
end
until last==1
if bn>0 then flush(bn)end
if#data<pos+3 or string.unpack(">I4",data,pos)~=s2*65536+s1 then
error("adler32 mismatch",0)
end
return table.concat(done)
end
end
end
do
local string,assert=string,assert
local spack,sunpack=string.pack,string.unpack
local k256={
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,
0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,
0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,
0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,
0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}
local function pad64(msg,len)
local extra=(64-((len+1+8)%64))%64
len=spack(">I8",len*8)
msg=msg.."\128"..string.rep("\0",extra)..len
assert(#msg%64==0)
return msg
end
local ww256={}
function sha256(msg)
msg=pad64(msg,#msg)
local h1,h2,h3,h4,h5,h6,h7,h8=
0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
local k=k256
local w=ww256
local mlen=#msg
for i=1,mlen,64 do
w[1],w[2],w[3],w[4],w[5],w[6],w[7],w[8],
w[9],w[10],w[11],w[12],w[13],w[14],w[15],w[16]
=sunpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4",msg,i)
for j=17,64 do
local x=w[j-15];x=(x<<32)|x
local y=w[j-2];y=(y<<32)|y
w[j]=(((x>>7)~(x>>18)~(x>>35))
+((y>>17)~(y>>19)~(y>>42))
+w[j-7]+w[j-16])&0xffffffff
end
local a,b,c,d,e,f,g,h=h1,h2,h3,h4,h5,h6,h7,h8
for j=1,64 do
e=(e<<32)|(e&0xffffffff)
local t1=((e>>6)~(e>>11)~(e>>25))
+(g~e&(f~g))+h+k[j]+w[j]
h=g
g=f
f=e
e=(d+t1)
d=c
c=b
b=a
a=(a<<32)|(a&0xffffffff)
a=t1+((a~c)&d~a&c)
+((a>>2)~(a>>13)~(a>>22))
end
h1=h1+a
h2=h2+b
h3=h3+c
h4=h4+d
h5=h5+e
h6=h6+f
h7=h7+g
h8=h8+h
end
h1=h1&0xffffffff
h2=h2&0xffffffff
h3=h3&0xffffffff
h4=h4&0xffffffff
h5=h5&0xffffffff
h6=h6&0xffffffff
h7=h7&0xffffffff
h8=h8&0xffffffff
return spack(">I4I4I4I4I4I4I4I4",h1,h2,h3,h4,h5,h6,h7,h8)
end
local k512={
0x428a2f98d728ae22,0x7137449123ef65cd,0xb5c0fbcfec4d3b2f,0xe9b5dba58189dbbc,
0x3956c25bf348b538,0x59f111f1b605d019,0x923f82a4af194f9b,0xab1c5ed5da6d8118,
0xd807aa98a3030242,0x12835b0145706fbe,0x243185be4ee4b28c,0x550c7dc3d5ffb4e2,
0x72be5d74f27b896f,0x80deb1fe3b1696b1,0x9bdc06a725c71235,0xc19bf174cf692694,
0xe49b69c19ef14ad2,0xefbe4786384f25e3,0x0fc19dc68b8cd5b5,0x240ca1cc77ac9c65,
0x2de92c6f592b0275,0x4a7484aa6ea6e483,0x5cb0a9dcbd41fbd4,0x76f988da831153b5,
0x983e5152ee66dfab,0xa831c66d2db43210,0xb00327c898fb213f,0xbf597fc7beef0ee4,
0xc6e00bf33da88fc2,0xd5a79147930aa725,0x06ca6351e003826f,0x142929670a0e6e70,
0x27b70a8546d22ffc,0x2e1b21385c26c926,0x4d2c6dfc5ac42aed,0x53380d139d95b3df,
0x650a73548baf63de,0x766a0abb3c77b2a8,0x81c2c92e47edaee6,0x92722c851482353b,
0xa2bfe8a14cf10364,0xa81a664bbc423001,0xc24b8b70d0f89791,0xc76c51a30654be30,
0xd192e819d6ef5218,0xd69906245565a910,0xf40e35855771202a,0x106aa07032bbd1b8,
0x19a4c116b8d2d0c8,0x1e376c085141ab53,0x2748774cdf8eeb99,0x34b0bcb5e19b48a8,
0x391c0cb3c5c95a63,0x4ed8aa4ae3418acb,0x5b9cca4f7763e373,0x682e6ff3d6b2b8a3,
0x748f82ee5defb2fc,0x78a5636f43172f60,0x84c87814a1f0ab72,0x8cc702081a6439ec,
0x90befffa23631e28,0xa4506cebde82bde9,0xbef9a3f7b2c67915,0xc67178f2e372532b,
0xca273eceea26619c,0xd186b8c721c0c207,0xeada7dd6cde0eb1e,0xf57d4f7fee6ed178,
0x06f067aa72176fba,0x0a637dc5a2c898a6,0x113f9804bef90dae,0x1b710b35131c471b,
0x28db77f523047d84,0x32caab7b40c72493,0x3c9ebe0a15c9bebc,0x431d67c49c100d4c,
0x4cc5d4becb3e42b6,0x597f299cfc657e2a,0x5fcb6fab3ad6faec,0x6c44198c4a475817
}
local function pad128(msg,len)
local extra=(128-((len+1+16)%128))%128
len=spack(">I16",len*8)
msg=msg.."\128"..string.rep("\0",extra)..len
return msg
end
local ww512={}
function sha512(msg)
msg=pad128(msg,#msg)
local h1,h2,h3,h4,h5,h6,h7,h8=
0x6a09e667f3bcc908,0xbb67ae8584caa73b,
0x3c6ef372fe94f82b,0xa54ff53a5f1d36f1,
0x510e527fade682d1,0x9b05688c2b3e6c1f,
0x1f83d9abfb41bd6b,0x5be0cd19137e2179
local k=k512
local w=ww512
local mlen=#msg
for i=1,mlen,128 do
w[1],w[2],w[3],w[4],w[5],w[6],w[7],w[8],
w[9],w[10],w[11],w[12],w[13],w[14],w[15],w[16]
=sunpack(">i8i8i8i8i8i8i8i8i8i8i8i8i8i8i8i8",msg,i)
for j=17,80 do
local a=w[j-15]
local b=w[j-2]
w[j]=(a>>1~a>>7~a>>8~a<<56~a<<63)
+(b>>6~b>>19~b>>61~b<<3~b<<45)
+w[j-7]+w[j-16]
end
local a,b,c,d,e,f,g,h=h1,h2,h3,h4,h5,h6,h7,h8
for j=1,80 do
local z=(e>>14~e>>18~e>>41~e<<23
~e<<46~e<<50)
+(g~e&(f~g))+h+k[j]+w[j]
h=g
g=f
f=e
e=z+d
d=c
c=b
b=a
a=z+((a~c)&d~a&c)
+(a>>28~a>>34~a>>39~a<<25
~a<<30~a<<36)
end
h1=h1+a
h2=h2+b
h3=h3+c
h4=h4+d
h5=h5+e
h6=h6+f
h7=h7+g
h8=h8+h
end
return spack(">i8i8i8i8i8i8i8i8",h1,h2,h3,h4,h5,h6,h7,h8)
end
end
do
meta={}
function meta.fnv1a(str)
local hash=2166136261
for i=1,#str do
hash=(hash~str:byte(i))&0xFFFFFFFF
hash=(hash*16777619)%4294967296
hash=math.tointeger(hash)&0xFFFFFFFF
end
return hash
end
function meta.line(name,isDir,mode,uid,gid,time)
return string.format("%s:%s:%d:%d:%d:%o:1:%d:%d:\n",name,isDir and"VDIR"or"VREG",
meta.fnv1a(name),time,time,mode,uid,gid)
end
function meta.new()
local dirs={}
local set={}
function set.add(path,isDir,mode,uid,gid)
local dir,name=path:match("^(.*)/([^/]+)$")
if dir==""then dir="/"end
local entries=dirs[dir]
if not entries then
entries={order={}}
dirs[dir]=entries
end
if not entries[name]then entries.order[#entries.order+1]=name end
entries[name]={isDir=isDir,mode=mode,uid=uid or 0,gid=gid or 0}
end
function set.each(time,write)
local paths={}
for dir in pairs(dirs)do paths[#paths+1]=dir end
table.sort(paths)
for _,dir in ipairs(paths)do
local entries,lines=dirs[dir],{}
for _,name in ipairs(entries.order)do
local e=entries[name]
lines[#lines+1]=meta.line(name,e.isDir,e.mode,e.uid,e.gid,time)
end
write(dir,table.concat(lines))
end
end
return set
end
end
do
util={}
function util.yield()
computer.pullSignal(0)
end
function util.realTime()
local tmp=computer.tmpAddress and computer.tmpAddress()
if not tmp then return 0 end
local path="/.nexus-install-clock"
local handle=component.invoke(tmp,"open",path,"w")
if not handle then return 0 end
component.invoke(tmp,"close",handle)
local ms=component.invoke(tmp,"lastModified",path)
component.invoke(tmp,"remove",path)
if type(ms)~="number"or ms<=0 then return 0 end
return math.floor(ms/1000)
end
function util.serialize(v,indent)
indent=indent or""
local t=type(v)
if t=="string"then return string.format("%q",v)end
if t=="number"or t=="boolean"then return tostring(v)end
if t~="table"then error("cannot serialize a "..t,0)end
local inner=indent.."    "
local parts,n={},#v
for i=1,n do parts[#parts+1]=inner..util.serialize(v[i],inner)..",\n"end
local keys={}
for k in pairs(v)do
if not(math.type(k)=="integer"and k>=1 and k<=n)then keys[#keys+1]=k end
end
table.sort(keys)
for _,k in ipairs(keys)do
parts[#parts+1]=inner..k.." = "..util.serialize(v[k],inner)..",\n"
end
if#parts==0 then return"{}"end
return"{\n"..table.concat(parts)..indent.."}"
end
function util.loadData(text,name)
local chunk,err=load(text,"="..name,"t",{})
if not chunk then return nil,err end
local ok,value=pcall(chunk)
if not ok then return nil,name..": "..tostring(value)end
return value
end
function util.size(bytes)
if bytes>=1024*1024 then return string.format("%.1f MB",bytes/1048576)end
if bytes>=1024 then return string.format("%d KB",math.floor(bytes/1024+0.5))end
return bytes.." B"
end
function util.validHostname(name)
return#name>=1 and#name<=63 and name:match("^[%w][%w%-]*$")~=nil
end
function util.validUsername(name)
return#name>=1 and#name<=32 and name:match("^[%l_][%l%d_%-]*$")~=nil and name~="root"
end
function util.passwordHash(password)
return(sha512(password.."salt"):gsub(".",function(c)
return string.format("%02x",c:byte())
end))
end
end
do
disk={}
function disk.list()
local out={}
local tmp=computer.tmpAddress and computer.tmpAddress()
local boot=computer.getBootAddress and computer.getBootAddress()
for address in component.list("filesystem")do
if address~=tmp then
local fs=component.proxy(address)
out[#out+1]={
address=address,
label=fs.getLabel()or"",
total=fs.spaceTotal()or 0,
used=fs.spaceUsed()or 0,
readOnly=fs.isReadOnly(),
boot=address==boot,
}
end
end
table.sort(out,function(a,b)
if a.boot~=b.boot then return b.boot end
return a.address<b.address
end)
return out
end
function disk.describe(info)
return string.format("%s  %-12s %s free of %s%s",info.address:sub(1,8),info.label:sub(1,12),
util.size(info.total-info.used),util.size(info.total),info.readOnly and"  read-only"or"")
end
function disk.readAll(fs,path)
local handle,err=fs.open(path,"rb")
if not handle then return nil,path..": "..tostring(err)end
local parts={}
while true do
local data=fs.read(handle,math.huge)
if not data then break end
parts[#parts+1]=data
end
fs.close(handle)
return table.concat(parts)
end
function disk.eachChunk(fs,path,fn)
local handle,err=fs.open(path,"rb")
if not handle then error(path..": "..tostring(err),0)end
while true do
local data=fs.read(handle,16384)
if not data then break end
fn(data)
end
fs.close(handle)
end
function disk.writer(fs,path)
local handle,err=fs.open(path,"wb")
if not handle then error("cannot create "..path..": "..tostring(err),0)end
local function write(chunk)
local ok,werr=fs.write(handle,chunk)
if not ok then
fs.close(handle)
error("cannot write "..path..": "..tostring(werr),0)
end
end
local function close()fs.close(handle)end
return write,close
end
function disk.writeAll(fs,path,data)
local write,close=disk.writer(fs,path)
if#data>0 then write(data)end
close()
end
function disk.replace(fs,path,data)
disk.writeAll(fs,path..".new",data)
if fs.exists(path)and not fs.remove(path)then
local handle=fs.open(path,"wb")
if not handle then
fs.remove(path..".new")
error("cannot replace "..path..": it can be neither removed nor written",0)
end
local ok,err=true,nil
if#data>0 then ok,err=fs.write(handle,data)end
fs.close(handle)
if not ok then error("cannot write "..path..": "..tostring(err),0)end
fs.remove(path..".new")
return
end
if not fs.rename(path..".new",path)then error("cannot rename "..path..".new",0)end
end
function disk.copy(fromFs,fromPath,toFs,toPath)
local write,close=disk.writer(toFs,toPath)
disk.eachChunk(fromFs,fromPath,write)
close()
end
function disk.mkdir(fs,path)
if fs.isDirectory(path)then return end
if not fs.makeDirectory(path)then error("cannot create "..path,0)end
end
function disk.wipe(fs,dir,keep)
local removed=0
local function walk(d)
for _,name in ipairs(fs.list(d)or{})do
local isDir=name:sub(-1)=="/"
local full=d..(isDir and name:sub(1,-2)or name)
if not keep[full]then
if isDir then walk(full.."/")end
if not fs.remove(full)then error("cannot remove "..full,0)end
removed=removed+1
if removed%64==0 then util.yield()end
end
end
end
walk(dir)
end
function disk.removeTree(fs,path)
if not fs.exists(path)then return end
if fs.isDirectory(path)then disk.wipe(fs,path.."/",{})end
fs.remove(path)
end
function disk.treeSize(fs,path)
if not fs.exists(path)then return 0 end
if not fs.isDirectory(path)then return fs.size(path)or 0 end
local total=0
for _,name in ipairs(fs.list(path)or{})do
total=total+disk.treeSize(fs,path.."/"..name:gsub("/$",""))
end
return total
end
end
do
img={}
img.SECTION={kernel=1,usr=2,etc=3}
function img.reader(fs,path)
local handle,err=fs.open(path,"rb")
if not handle then error(path..": "..tostring(err),0)end
local reader={size=fs.size(path)or 0}
function reader.read(offset,length)
fs.seek(handle,"set",offset)
local parts,got={},0
while got<length do
local data=fs.read(handle,length-got)
if not data then error(path..": truncated image",0)end
parts[#parts+1]=data
got=got+#data
end
return table.concat(parts)
end
function reader.close()fs.close(handle)end
return reader
end
function img.open(reader,name)
local head=reader.read(0,32)
if head:sub(1,6)~="NXIMG\0"then error(name.." is not a Nexus image",0)end
local version,compression,blockSize,sectionCount,_,blockCount,dataOffset,metaCrc,headCrc=
string.unpack("<BBI4I2I2I4I4I4I4",head,7)
if version~=1 then error(name..": unsupported image version "..version,0)end
if crc32(head:sub(1,28))~=headCrc then error(name..": header checksum mismatch",0)end
local metaRaw=reader.read(32,dataOffset-32)
if crc32(metaRaw)~=metaCrc then error(name..": index checksum mismatch",0)end
local info={name=name,reader=reader,compression=compression,blockSize=blockSize,
blockCount=blockCount,dataOffset=dataOffset,sections={},index={}}
for i=0,sectionCount-1 do
local typ,_,_,rawSize,firstBlock,n,crc=string.unpack("<BBI2I4I4I4I4",metaRaw,i*24+1)
info.sections[typ]={type=typ,rawSize=rawSize,firstBlock=firstBlock,blockCount=n,crc=crc}
end
local base=sectionCount*24
for i=0,blockCount do
info.index[i]=string.unpack("<I4",metaRaw,base+i*4+1)
end
if dataOffset+info.index[blockCount]~=reader.size then
error(name..": size does not match its index",0)
end
return info
end
function img.inflater()
local card=component.list("data")()
if card then
return function(stored)
local raw,err=component.invoke(card,"inflate",stored)
if not raw then error("inflate failed: "..tostring(err),0)end
return raw
end
end
return softInflate
end
function img.blocks(info,section,inflate)
local i,last=section.firstBlock,section.firstBlock+section.blockCount-1
local crc,total=0,0
return function()
if i>last then
if total~=section.rawSize then error(info.name..": section is incomplete",0)end
if info.compression==0 and crc~=section.crc then
error(info.name..": section checksum mismatch",0)
end
return nil
end
util.yield()
local a,b=info.index[i],info.index[i+1]
local raw=info.reader.read(info.dataOffset+a,b-a)
if info.compression==1 then
raw=inflate(raw)
elseif info.compression~=0 then
error(info.name..": unknown compression "..info.compression,0)
else
crc=crc32(raw,crc)
end
local want=i==last and(section.rawSize-(section.blockCount-1)*info.blockSize)or info.blockSize
if#raw~=want then error(info.name..": block "..i.." has the wrong size",0)end
total=total+#raw
i=i+1
return raw
end
end
function img.unpack(info,section,inflate,visit)
local nextBlock=img.blocks(info,section,inflate)
local buf,pos="",1
local function fill()
local block=nextBlock()
if not block then error(info.name..": truncated file tree",0)end
buf,pos=buf:sub(pos)..block,1
end
local function take(n)
while#buf-pos+1<n do fill()end
local s=buf:sub(pos,pos+n-1)
pos=pos+n
return s
end
local head=take(16)
if head:sub(1,4)~="NXFS"or head:byte(5)~=1 then error(info.name..": not a file tree",0)end
local count,tocSize=string.unpack("<I4I4",head,9)
local toc=take(tocSize-16)
local entries,at={},1
for _=1,count do
local pathlen,kind,_,mode,uid,gid,_,offset,size=string.unpack("<I2BBI2I2I2I2I4I4",toc,at)
at=at+20
entries[#entries+1]={path=toc:sub(at,at+pathlen-1),dir=kind==2,mode=mode,
uid=uid,gid=gid,offset=offset,size=size}
at=at+pathlen
end
toc=nil
local consumed=tocSize
for _,e in ipairs(entries)do
local sink=visit(e)
if not e.dir and e.size>0 then
if e.offset~=consumed then error(info.name..": file data out of order",0)end
local left=e.size
while left>0 do
if pos>#buf then
buf,pos=nextBlock()or error(info.name..": truncated file tree",0),1
end
local n=math.min(left,#buf-pos+1)
if sink then sink(buf:sub(pos,pos+n-1))end
pos=pos+n
left=left-n
end
consumed=consumed+e.size
end
if sink then sink(nil)end
end
while nextBlock()do end
end
end
do
net={}
function net.card()
return component.list("internet")()
end
local REDIRECT={[301]=true,[302]=true,[303]=true,[307]=true,[308]=true}
local function location(headers,url)
if type(headers)~="table"then return nil end
for name,value in pairs(headers)do
if type(name)=="string"and name:lower()=="location"then
if type(value)=="table"then value=value[1]end
if type(value)~="string"then return nil end
if value:sub(1,1)=="/"then
return url:match("^(%a[%w+.-]*://[^/]+)")..value
end
return value
end
end
end
local function open(card,url)
local ok,handle,reqErr=pcall(component.invoke,card,"request",url)
if not ok or not handle then return nil,url..": "..tostring(ok and reqErr or handle)end
local function fail(err)
pcall(handle.close)
return nil,url..": "..tostring(err)
end
local deadline=computer.uptime()+30
while true do
local okc,connected,err=pcall(handle.finishConnect)
if not okc then return fail(connected)end
if connected then break end
if connected==nil then return fail(err or"connection failed")end
if computer.uptime()>deadline then return fail("timed out")end
computer.pullSignal(0.1)
end
while true do
local okr,code,message,headers=pcall(handle.response)
if not okr then return fail(code)end
if code then
if code==200 then return handle end
if REDIRECT[code]then
local target=location(headers,url)
pcall(handle.close)
if not target then return nil,url..": HTTP "..code.." without a Location"end
return nil,"redirect",target
end
return fail("HTTP "..tostring(code).." "..tostring(message or""))
end
if computer.uptime()>deadline then return fail("no response")end
computer.pullSignal(0.05)
end
end
function net.get(url,sink)
local card=net.card()
if not card then return nil,"no internet card"end
local handle,err,target
for _=1,6 do
handle,err,target=open(card,url)
if handle or err~="redirect"then break end
url=target
end
if not handle then
return nil,err=="redirect"and(url..": too many redirects")or err
end
local total=0
while true do
local okd,chunk,rerr=pcall(handle.read,16384)
if not okd or(chunk==nil and rerr)then
pcall(handle.close)
return nil,url..": "..tostring(okd and rerr or chunk)
end
if chunk==nil then break end
if#chunk>0 then
total=total+#chunk
sink(chunk)
else
computer.pullSignal(0.05)
end
end
pcall(handle.close)
return total
end
function net.fetch(url)
local parts={}
local n,err=net.get(url,function(chunk)parts[#parts+1]=chunk end)
if not n then return nil,err end
return table.concat(parts)
end
end
do
source={}
source.ROLES={"kernel","rootfs","boot","config"}
function source.parseManifest(text)
local m,err=util.loadData(text,"manifest.lua")
if not m then return nil,err end
if type(m)~="table"or math.type(m.format)~="integer"or math.type(m.installer)~="integer"
or type(m.files)~="table"then
return nil,"manifest.lua is not a Nexus manifest"
end
return m
end
function source.check(m)
if m.format~=1 then
return nil,"this release needs a newer installer (manifest format "..m.format..")"
end
local roles={}
for _,f in ipairs(m.files)do
if type(f)~="table"or type(f.name)~="string"or not f.name:match("^[%w._-]+$")
or math.type(f.size)~="integer"or math.type(f.crc32)~="integer"then
return nil,"manifest.lua has a bad file entry"
end
roles[f.role]=f
end
for _,role in ipairs(source.ROLES)do
if not roles[role]then return nil,"manifest.lua has no "..role.." file"end
end
if type(m.groups)~="table"then m.groups={}end
m.byRole=roles
return true
end
function source.channelBase(channel)
local text,err=net.fetch(CHANNEL_URL)
if not text then return nil,err end
local c,cerr=util.loadData(text,"channel.lua")
if not c then return nil,cerr end
if type(c)~="table"or c.format~=1 or type(c.base)~="string"or type(c.channels)~="table"then
return nil,"channel.lua: unknown format"
end
local tag=c.channels[channel]
if type(tag)~="string"then return nil,"channel.lua has no channel "..channel end
return c.base:format(tag)
end
function source.offline(fs,dir)
local text,err=disk.readAll(fs,dir.."/manifest.lua")
if not text then return nil,err end
local m,merr=source.parseManifest(text)
if not m then return nil,merr end
return{kind="offline",fs=fs,dir=dir,manifest=m}
end
function source.online(base)
base=base:gsub("/+$","")
local text,err=net.fetch(base.."/manifest.lua")
if not text then return nil,err end
local m,merr=source.parseManifest(text)
if not m then return nil,merr end
return{kind="online",base=base,manifest=m}
end
local function read(src,f,fn,dlFs,dlPath)
local crc,size=0,0
local function take(chunk)
crc=crc32(chunk,crc)
size=size+#chunk
fn(chunk)
util.yield()
end
if src.kind=="online"then
local write,close=disk.writer(dlFs,dlPath)
local n,err=net.get(src.base.."/"..f.name,function(chunk)
write(chunk)
take(chunk)
end)
close()
if not n then error(err,0)end
else
local path=src.dir.."/"..f.name
if not src.fs.exists(path)then error(path.." is missing",0)end
disk.eachChunk(src.fs,path,take)
end
if size~=f.size then error(string.format("%s: %d bytes, expected %d",f.name,size,f.size),0)end
if crc~=f.crc32 then error(f.name..": checksum mismatch",0)end
end
function source.prepare(src,dlFs,dlDir,progress)
local m=src.manifest
local total,done=0,0
for _,f in ipairs(m.files)do
if f.role~="installer"then total=total+f.size end
end
if src.kind=="online"then disk.mkdir(dlFs,dlDir)end
local files={}
for _,f in ipairs(m.files)do
if f.role~="installer"then
local verb=src.kind=="online"and"Downloading "or"Checking "
local got=0
read(src,f,function(chunk)
got=got+#chunk
progress((done+got)/math.max(total,1),verb..f.name)
end,dlFs,dlDir.."/"..f.name)
done=done+f.size
if src.kind=="online"then
files[f.role]={fs=dlFs,path=dlDir.."/"..f.name}
else
files[f.role]={fs=src.fs,path=src.dir.."/"..f.name}
end
end
end
return files
end
function source.installer(src)
local f=src.manifest.byRole and src.manifest.byRole.installer
if not f then
for _,e in ipairs(src.manifest.files)do
if e.role=="installer"then f=e end
end
end
if not f then return nil,"the release has no installer"end
local parts,crc,size={},0,0
local function take(chunk)
parts[#parts+1]=chunk
crc=crc32(chunk,crc)
size=size+#chunk
util.yield()
end
if src.kind=="online"then
local n,err=net.get(src.base.."/"..f.name,take)
if not n then return nil,err end
else
local path=src.dir.."/"..f.name
if not src.fs.exists(path)then return nil,path.." is missing"end
disk.eachChunk(src.fs,path,take)
end
if size~=f.size or crc~=f.crc32 then return nil,f.name..": checksum mismatch"end
return table.concat(parts)
end
end
do
install={}
local function octal(s)return tonumber(s,8)end
local USER_UID=1000
function install.spaceNeeded(m,plan)
local need=m.installed or 0
if plan.kernel=="store"then need=need+(m.kernelRaw or 0)end
return math.floor(need*1.1)+16384
end
local function excluded(m,plan)
local paths,modules,drivers={},{},{}
for _,g in ipairs(m.groups)do
if not plan.groups[g.id]then
for _,p in ipairs(g.paths or{})do paths[p]=true end
for _,p in ipairs(g.modules or{})do modules[#modules+1]=p end
for _,p in ipairs(g.drivers or{})do drivers[#drivers+1]=p end
end
end
return paths,modules,drivers
end
function install.dropLines(text,paths)
if#paths==0 then return text end
local out={}
for line in(text.."\n"):gmatch("(.-)\n")do
local keep=true
for _,p in ipairs(paths)do
if line:find('"'..p..'"',1,true)then
keep=false
break
end
end
if keep then out[#out+1]=line end
end
return table.concat(out,"\n")
end
local function profile(home)
return'local colors = require("colors")\n'
..'local process = require("process")\n'
..'os.setenv("HISTSIZE", "10")\n'
..'os.setenv("HOME", "'..home..'")\n'
..'os.setenv("PWD", "'..home..'")\n'
..'os.setenv("PS1", colors.green .. "$USERNAME@$HOSTNAME" .. colors.reset .. ":" .. colors.bright_blue .. "$PWD" .. colors.reset .. "$ ")\n'
..'process.cwd(os.getenv("HOME"))\n'
end
function install.storeKernel(file,fs,path,inflate)
local reader=img.reader(file.fs,file.path)
local info=img.open(reader,"nexusos")
local k=info.sections[img.SECTION.kernel]
if not k then error("nexusos has no kernel",0)end
local bs,n=info.blockSize,k.blockCount
local index,offset={},0
for i=0,n-1 do
index[#index+1]=string.pack("<I4",offset)
offset=offset+(i==n-1 and(k.rawSize-(n-1)*bs)or bs)
end
index[#index+1]=string.pack("<I4",offset)
local metaRaw=string.pack("<BBI2I4I4I4I4I4",img.SECTION.kernel,0,0,k.rawSize,0,n,k.crc,0)
..table.concat(index)
local head="NXIMG\0"..string.pack("<BBI4I2I2I4I4I4",1,0,bs,1,0,n,32+#metaRaw,crc32(metaRaw))
head=head..string.pack("<I4",crc32(head))
local write,close=disk.writer(fs,path)
write(head..metaRaw)
for raw in img.blocks(info,k,inflate)do write(raw)end
close()
reader.close()
end
function install.run(ctx)
local fs,plan,m,files,progress=ctx.target,ctx.plan,ctx.manifest,ctx.files,ctx.progress
local now=util.realTime()
local attrs=meta.new()
local paths,modules,drivers=excluded(m,plan)
local name=plan.user.name
local inflate=img.inflater()
progress(0,"Erasing the disk")
disk.wipe(fs,"/",ctx.keep)
if ctx.onErase then ctx.onErase()end
local reader=img.reader(files.rootfs.fs,files.rootfs.path)
local info=img.open(reader,"rootfs")
local total,done=0,0
for _,mount in ipairs({"usr","etc"})do
local section=info.sections[img.SECTION[mount]]
if not section then error("rootfs has no "..mount.." section",0)end
total=total+section.rawSize
end
local transforms={
["etc/modules.lua"]=function(text)return install.dropLines(text,modules)end,
["usr/lib/drivers/drivers.idx"]=function(text)return install.dropLines(text,drivers)end,
["etc/sudoers"]=function(text)
if text~=""and text:sub(-1)~="\n"then text=text.."\n"end
return text..name.." ALL=(root) ALL\n"
end,
}
for _,mount in ipairs({"usr","etc"})do
disk.mkdir(fs,"/"..mount)
attrs.add("/"..mount,true,octal("755"),0,0)
img.unpack(info,info.sections[img.SECTION[mount]],inflate,function(e)
local rel=mount.."/"..e.path
if paths[rel]then return nil end
local path="/"..rel
attrs.add(path,e.dir,e.mode,e.uid,e.gid)
if e.dir then
disk.mkdir(fs,path)
return nil
end
local transform=transforms[rel]
if transform then
local parts={}
return function(chunk)
if chunk then
parts[#parts+1]=chunk
else
disk.writeAll(fs,path,transform(table.concat(parts)))
end
end
end
local write,close=disk.writer(fs,path)
return function(chunk)
if not chunk then return close()end
write(chunk)
done=done+#chunk
progress(0.05+0.7*done/total,"Unpacking the system")
end
end)
end
reader.close()
progress(0.75,"Installing the kernel")
disk.mkdir(fs,"/boot")
attrs.add("/boot",true,octal("755"),0,0)
if plan.kernel=="store"then
install.storeKernel(files.kernel,fs,"/boot/nexusos",inflate)
else
disk.copy(files.kernel.fs,files.kernel.path,fs,"/boot/nexusos")
end
attrs.add("/boot/nexusos",false,octal("644"),0,0)
disk.copy(files.config.fs,files.config.path,fs,"/boot/config.lua")
attrs.add("/boot/config.lua",false,octal("644"),0,0)
progress(0.92,"Configuring the system")
local home="/home/"..name
local function put(path,data,mode,uid)
disk.writeAll(fs,path,data)
attrs.add(path,false,octal(mode),uid or 0,uid or 0)
end
put("/etc/hostname",plan.hostname.."\n","644")
put("/etc/passwd","root:x:0:0:root:/root:/bin/sh.lua\n"
..string.format("%s:x:%d:%d::%s:/bin/sh.lua\n",name,USER_UID,USER_UID,home),"644")
put("/etc/shadow","root:*:0:0:99999:7:::\n"
..string.format("%s:%s:%d:0:99999:7:::\n",name,plan.user.hash,now),"400")
put("/etc/group",string.format("root:0:\n%s:%d:%s\n",name,USER_UID,name),"644")
for _,dir in ipairs({{"/root","700",0},{"/home","755",0},{home,"755",USER_UID}})do
disk.mkdir(fs,dir[1])
attrs.add(dir[1],true,octal(dir[2]),dir[3],dir[3])
end
put(home.."/.profile.lua",profile(home),"644",USER_UID)
progress(0.97,"Writing file modes")
attrs.add("/init.lua",false,octal("644"),0,0)
attrs.each(now,function(dir,text)
disk.writeAll(fs,(dir=="/"and""or dir).."/.meta",text)
util.yield()
end)
progress(0.99,"Installing the boot loader")
local loader,err=disk.readAll(files.boot.fs,files.boot.path)
if not loader then error(err,0)end
disk.replace(fs,"/init.lua",loader)
fs.setLabel("Nexus")
if computer.setBootAddress then computer.setBootAddress(fs.address)end
disk.removeTree(fs,STAGE)
progress(1,"Installation complete")
end
end
do
tui={}
local gpu,W,H,mono
local C={}
local KEY={enter=28,esc=1,up=200,down=208,left=203,right=205,tab=15,
back=14,del=211,home=199,["end"]=207,pgup=201,pgdn=209,space=57}
function tui.init()
local g,s=component.list("gpu")(),component.list("screen")()
if not g or not s then return false end
gpu=component.proxy(g)
gpu.bind(s)
local mw,mh=gpu.maxResolution()
W,H=math.min(mw,80),math.min(mh,25)
gpu.setResolution(W,H)
mono=gpu.getDepth()<4
if mono then
C={root=0x000000,rootFg=0xFFFFFF,win=0x000000,winFg=0xFFFFFF,title=0xFFFFFF,
sel=0xFFFFFF,selFg=0x000000,entry=0xFFFFFF,entryFg=0x000000,shadow=0x000000,
bar=0xFFFFFF,barFg=0x000000}
else
C={root=0x0000AA,rootFg=0xFFFFFF,win=0xAAAAAA,winFg=0x000000,title=0xAA0000,
sel=0xAA0000,selFg=0xFFFFFF,entry=0x0000AA,entryFg=0xFFFFFF,shadow=0x000000,
bar=0xAA0000,barFg=0xFFFFFF}
end
tui.title="Nexus installer"
return true
end
local function color(fg,bg)
gpu.setForeground(fg)
gpu.setBackground(bg)
end
local function put(x,y,text,fg,bg,width)
if width then text=(text..string.rep(" ",width)):sub(1,width)end
color(fg,bg)
gpu.set(x,y,text)
end
function tui.wrap(text,width)
local lines={}
for para in(text.."\n"):gmatch("(.-)\n")do
local line=""
for word in para:gmatch("%S+")do
while#word>width do
if line~=""then lines[#lines+1]=line line=""end
lines[#lines+1]=word:sub(1,width)
word=word:sub(width+1)
end
if line==""then
line=word
elseif#line+1+#word<=width then
line=line.." "..word
else
lines[#lines+1]=line
line=word
end
end
lines[#lines+1]=line
end
while#lines>0 and lines[#lines]==""do lines[#lines]=nil end
return lines
end
local function screen(help)
color(C.rootFg,C.root)
gpu.fill(1,1,W,H," ")
put(1,1," "..tui.title,C.rootFg,C.root,W)
if not mono then put(1,2,string.rep("\u{2500}",W),C.rootFg,C.root)end
put(1,H," "..(help or""),C.rootFg,C.root,W)
end
local function box(title,w,h)
w,h=math.min(w,W-4),math.min(h,H-5)
local x=math.floor((W-w-2)/2)+1
local y=math.floor((H-h-2)/2)+1
if y<3 then y=3 end
if not mono then
color(C.shadow,C.shadow)
gpu.fill(x+2,y+h+2,w+2,1," ")
gpu.fill(x+w+2,y+1,2,h+1," ")
end
color(C.winFg,C.win)
gpu.fill(x,y,w+2,h+2," ")
gpu.set(x,y,"\u{250C}"..string.rep("\u{2500}",w).."\u{2510}")
gpu.set(x,y+h+1,"\u{2514}"..string.rep("\u{2500}",w).."\u{2518}")
for row=y+1,y+h do
gpu.set(x,row,"\u{2502}")
gpu.set(x+w+1,row,"\u{2502}")
end
if title and title~=""then
local t="[ "..title:sub(1,w-4).." ]"
put(x+math.floor((w+2-#t)/2),y,t,mono and C.winFg or C.title,C.win)
end
return x+1,y+1,w,h
end
local function key()
while true do
local sig,_,a,b=computer.pullSignal()
if sig=="key_down"then return b,a end
if sig=="clipboard"then return"paste",a end
end
end
local function buttons(x,y,w,labels,focus)
local parts={}
for i,label in ipairs(labels)do parts[i]="<"..label..">"end
local width=#table.concat(parts,"   ")
local bx=x+math.floor((w-width)/2)
for i,part in ipairs(parts)do
local on=focus==i
put(bx,y,part,on and C.selFg or C.winFg,on and C.sel or C.win)
bx=bx+#part+3
end
end
local function dialog(title,text,labels,focus,help)
local inner=math.min(W-8,64)
local lines=tui.wrap(text,inner-2)
local rows=math.min(#lines,H-8)
local h=rows+3
local top=1
focus=focus or 1
while true do
screen(help or(rows<#lines and"<Up>/<Down> scroll  <Tab> move  <Enter> select"
or"<Tab> move  <Enter> select  <Esc> back"))
local x,y,w=box(title,inner,h)
for i=0,rows-1 do
if lines[top+i]then put(x+1,y+i,lines[top+i],C.winFg,C.win)end
end
if top>1 then put(x+w-1,y,"\u{2191}",C.winFg,C.win)end
if top+rows-1<#lines then put(x+w-1,y+rows-1,"\u{2193}",C.winFg,C.win)end
buttons(x,y+h-1,w,labels,focus)
local code,ch=key()
if code==KEY.enter then return focus end
if code==KEY.esc then return nil end
if code==KEY.tab or code==KEY.right then focus=focus%#labels+1 end
if code==KEY.left then focus=(focus-2)%#labels+1 end
if code==KEY.up then top=math.max(1,top-1)end
if code==KEY.down then top=math.max(1,math.min(#lines-rows+1,top+1))end
if type(ch)=="number"and ch>0 then
local c=string.char(ch):lower()
for i,label in ipairs(labels)do
if label:sub(1,1):lower()==c then return i end
end
end
end
end
function tui.message(title,text)
return dialog(title,text,{"Continue"},1,"<Enter> continue")~=nil
end
function tui.yesno(title,text,default)
local pressed=dialog(title,text,{"Yes","No"},default and 1 or 2)
if pressed==nil then return nil end
return pressed==1
end
function tui.menu(title,text,items,selected)
local inner=math.min(W-8,72)
local lines=tui.wrap(text,inner-2)
local maxRows=H-8-#lines
if maxRows<3 then
lines={table.unpack(lines,1,math.max(1,H-11))}
maxRows=H-8-#lines
end
local rows=math.min(#items,maxRows)
local sel,top=selected or 1,1
while true do
if sel<top then top=sel end
if sel>top+rows-1 then top=sel-rows+1 end
screen("<Up>/<Down> move  <Enter> select  <Esc> back")
local x,y,w=box(title,inner,#lines+rows+1)
for i,line in ipairs(lines)do put(x+1,y+i-1,line,C.winFg,C.win)end
local ly=y+#lines+1
for r=0,rows-1 do
local i=top+r
local item=items[i]
if item then
local on=i==sel
put(x+2,ly+r," "..item.label,on and C.selFg or C.winFg,on and C.sel or C.win,w-4)
end
end
if top>1 then put(x+w-1,ly,"\u{2191}",C.winFg,C.win)end
if top+rows-1<#items then put(x+w-1,ly+rows-1,"\u{2193}",C.winFg,C.win)end
local code=key()
if code==KEY.enter then return sel end
if code==KEY.esc then return nil end
if code==KEY.up then sel=math.max(1,sel-1)end
if code==KEY.down then sel=math.min(#items,sel+1)end
if code==KEY.pgup then sel=math.max(1,sel-rows)end
if code==KEY.pgdn then sel=math.min(#items,sel+rows)end
if code==KEY.home then sel=1 end
if code==KEY["end"]then sel=#items end
end
end
function tui.checklist(title,text,items)
local inner=math.min(W-8,72)
local lines=tui.wrap(text,inner-2)
local rows=math.max(1,math.min(#items,H-10-#lines))
local sel,top=1,1
local onContinue=false
while true do
if sel<top then top=sel end
if sel>top+rows-1 then top=sel-rows+1 end
screen("<Space> toggle <Tab> move <Enter> ok <Esc> back")
local x,y,w=box(title,inner,#lines+rows+3)
for i,line in ipairs(lines)do put(x+1,y+i-1,line,C.winFg,C.win)end
local ly=y+#lines+1
for r=0,rows-1 do
local i=top+r
local item=items[i]
if item then
local on=i==sel and not onContinue
put(x+2,ly+r,(item.checked and"[*] "or"[ ] ")..item.label,
on and C.selFg or C.winFg,on and C.sel or C.win,w-4)
end
end
buttons(x,ly+rows+1,w,{"Continue"},onContinue and 1 or 0)
local code=key()
if code==KEY.esc then return nil end
if code==KEY.enter then
if onContinue or#items==0 then return items end
onContinue=true
elseif code==KEY.tab then
onContinue=not onContinue
elseif code==KEY.space and not onContinue and items[sel]then
items[sel].checked=not items[sel].checked
elseif code==KEY.up then
onContinue=false
sel=math.max(1,sel-1)
elseif code==KEY.down then
if sel==#items then onContinue=true else sel=sel+1 end
end
end
end
function tui.input(title,text,opts)
opts=opts or{}
local inner=math.min(W-8,64)
local lines=tui.wrap(text,inner-2)
if#lines>H-10 then lines={table.unpack(lines,1,H-10)}end
local value=opts.default or""
while true do
screen("<Enter> continue  <Esc> back")
local x,y,w=box(title,inner,#lines+4)
for i,line in ipairs(lines)do put(x+1,y+i-1,line,C.winFg,C.win)end
local fw=w-2
local shown=opts.mask and string.rep("*",#value)or value
if#shown>=fw then shown=shown:sub(#shown-fw+2)end
put(x+1,y+#lines+1,shown,C.entryFg,C.entry,fw)
put(x+1+#shown,y+#lines+1," ",C.entry,C.entryFg)
buttons(x,y+#lines+3,w,{"Continue"},1)
local code,ch=key()
if code==KEY.enter then return value end
if code==KEY.esc then return nil end
if code=="paste"then
value=value..tostring(ch):gsub("[%c]","")
elseif code==KEY.back then
value=value:sub(1,-2)
elseif type(ch)=="number"and ch>=32 and ch<127 then
value=value..string.char(ch)
end
end
end
function tui.progress(title)
local inner=math.min(W-8,64)
screen("")
local x,y,w=box(title,inner,4)
local barW=w-8
local last={-1,""}
return function(fraction,text)
fraction=math.max(0,math.min(1,fraction))
local filled=math.floor(fraction*barW+0.5)
if filled==last[1]and text==last[2]then return end
last[1],last[2]=filled,text
put(x+1,y,text or"",C.winFg,C.win,w-2)
put(x+2,y+2,string.rep(" ",filled),C.barFg,C.bar)
put(x+2+filled,y+2,string.rep(mono and"\u{2591}"or" ",barW-filled),C.winFg,mono and C.win or C.root)
put(x+3+barW,y+2,string.format("%3d%%",math.floor(fraction*100+0.5)),C.winFg,C.win)
end
end
end
do
stage1={}
local function context(updated)
local bootAddress=computer.getBootAddress()
local boot=component.proxy(bootAddress)
local ctx={bootAddress=bootAddress,boot=boot,answers={},updated=updated}
if boot.isDirectory(STAGE)then
if boot.exists(STAGE.."/answers.lua")then
local text,err=disk.readAll(boot,STAGE.."/answers.lua")
local a
if text then a,err=util.loadData(text,"answers.lua")end
if type(a)=="table"then
ctx.answers=a
else
ctx.answersError=err or"answers.lua does not return a table"
end
end
if boot.exists(STAGE.."/manifest.lua")then
ctx.bundle,ctx.bundleError=source.offline(boot,STAGE)
end
end
return ctx
end
function stage1.cancel(ctx)
local boot,a=ctx.boot,ctx.answers
if a.staged then
if boot.exists(STAGE.."/init.lua.orig")then
local orig,err=disk.readAll(boot,STAGE.."/init.lua.orig")
if not orig then error(err,0)end
disk.replace(boot,"/init.lua",orig)
else
boot.remove("/init.lua")
end
local previous=a.restore_boot
if type(previous)=="string"and computer.setBootAddress and component.type(previous)=="filesystem"then
computer.setBootAddress(previous)
end
disk.removeTree(boot,STAGE)
computer.shutdown(true)
end
computer.shutdown(false)
end
local function openSource(ctx,kind,ask)
local src,err
if kind=="offline"then
src,err=ctx.bundle,ctx.bundleError
if not src then return nil,err or("no release in "..STAGE)end
elseif kind=="online"then
if not net.card()then return nil,"there is no internet card"end
local base=ctx.answers.base
if not base then
base,err=source.channelBase(CHANNEL)
if not base then return nil,err end
end
src,err=source.online(base)
if not src then return nil,err end
else
return nil,"unknown source "..tostring(kind)
end
local m=src.manifest
if m.installer>INSTALLER_REV and not ctx.updated and(ask==nil or ask(m))then
local code,uerr=source.installer(src)
if not code then return nil,uerr end
local chunk,lerr=load(code,"=nexus-install.lua","t",_ENV)
if not chunk then return nil,lerr end
if ctx.answers.staged then disk.replace(ctx.boot,"/init.lua",code)end
chunk("--updated")
error("the updated installer returned",0)
end
local ok,cerr=source.check(m)
if not ok then return nil,cerr end
return src
end
local function groupSet(m,wanted)
local set={}
local list=type(wanted)=="table"and{}or nil
if list then for _,id in ipairs(wanted)do list[id]=true end end
for _,g in ipairs(m.groups)do
local on
if wanted=="all"then on=true
elseif wanted=="none"then on=false
elseif list then on=list[g.id]==true
else on=g.default==true end
if on then set[g.id]=true end
end
return set
end
local function spaceProblem(ctx,src,plan)
local fs=component.proxy(plan.target)
local need=install.spaceNeeded(src.manifest,plan)
if src.kind=="online"then
for _,f in ipairs(src.manifest.files)do
if f.role~="installer"then need=need+f.size end
end
end
local kept=disk.treeSize(fs,STAGE)
if plan.target==ctx.bootAddress then kept=kept+(fs.size("/init.lua")or 0)end
local room=(fs.spaceTotal()or 0)-kept
if room<need then
return string.format("The disk has room for %s, and Nexus needs about %s.",util.size(math.max(room,0)),
util.size(need))
end
end
local function run(ctx,src,plan,progress)
local fs=component.proxy(plan.target)
if src.kind=="online"then disk.removeTree(fs,STAGE.."/dl")end
if not fs.isDirectory(STAGE)then disk.mkdir(fs,STAGE)end
local files=source.prepare(src,fs,STAGE.."/dl",function(f,text)progress(0.3*f,text)end)
if plan.target==ctx.bootAddress then
local a={}
for k,v in pairs(ctx.answers)do a[k]=v end
a.confirmed,a.source,a.base=true,src.kind,src.base
a.target,a.hostname,a.user,a.kernel=plan.target,plan.hostname,plan.user,plan.kernel
a.groups={}
for id in pairs(plan.groups)do a.groups[#a.groups+1]=id end
table.sort(a.groups)
disk.replace(ctx.boot,STAGE.."/answers.lua","return "..util.serialize(a).."\n")
end
local keep={[STAGE]=true}
if plan.target==ctx.bootAddress then keep["/init.lua"]=true end
install.run({target=fs,plan=plan,manifest=src.manifest,files=files,keep=keep,
progress=function(f,text)progress(0.3+0.7*f,text)end,
onErase=function()ctx.erased=true end})
end
local function errorText(err)
local line=tostring(err):match("^[^\n]*")
return(line:gsub("^[^:]+:%d+: ",""))
end
local function failed(ctx,err,canGoBack)
local items,actions={},{}
local function add(label,action)
items[#items+1]={label=label}
actions[#actions+1]=action
end
add("Retry","retry")
if canGoBack then add("Go back","back")end
if ctx.answers.staged and not ctx.erased then add("Cancel and restart the previous system","cancel")end
add("Shut down","off")
while true do
local i=tui.menu("Installation failed",errorText(err),items,1)
local action=i and actions[i]or(canGoBack and"back"or nil)
if action=="cancel"then stage1.cancel(ctx)end
if action=="off"then computer.shutdown(false)end
if action then return action end
end
end
local function planFromAnswers(ctx,src)
local a=ctx.answers
local plan={target=a.target or ctx.bootAddress,hostname=a.hostname or"nexus",
kernel=a.kernel or"zlib",groups=groupSet(src.manifest,a.groups)}
if component.type(plan.target)~="filesystem"then return nil,"no filesystem "..tostring(plan.target)end
if component.invoke(plan.target,"isReadOnly")then return nil,"the target disk is read-only"end
if not util.validHostname(plan.hostname)then return nil,"invalid hostname "..plan.hostname end
local u=a.user
if type(u)~="table"or type(u.name)~="string"or not util.validUsername(u.name)then
return nil,"answers.lua needs user = { name = ..., hash = ... }"
end
if type(u.hash)~="string"or not u.hash:match("^%x+$")or#u.hash~=128 then
return nil,"user.hash must be the /etc/shadow hash (128 hex digits)"
end
plan.user={name=u.name,hash=u.hash:lower()}
if plan.kernel~="zlib"and plan.kernel~="store"then return nil,"kernel must be zlib or store"end
return plan
end
function stage1.auto(ctx)
local a=ctx.answers
while true do
local progress=ctx.ui and tui.progress("Installing Nexus")or function()end
progress(0,a.confirmed and"Resuming the installation"or"Reading the release information")
local ok,err=xpcall(function()
local src,serr=openSource(ctx,a.source or(ctx.bundle and"offline"or"online"))
if not src then error(serr,0)end
local plan,perr=planFromAnswers(ctx,src)
if not plan then error(perr,0)end
local problem=spaceProblem(ctx,src,plan)
if problem then error(problem,0)end
run(ctx,src,plan,progress)
end,debug.traceback)
if ok then computer.shutdown(true)end
if type(err)~="string"then error(err,0)end
if not ctx.ui then error("nexus-install: "..err,0)end
failed(ctx,err,false)
end
end
function stage1.interactive(ctx)
local a=ctx.answers
local plan={target=a.target,hostname=a.hostname or"nexus",user={},kernel=a.kernel or"zlib"}
local src
local function summary()
local info
for _,d in ipairs(disk.list())do
if d.address==plan.target then info=d end
end
local parts={}
for _,g in ipairs(src.manifest.groups)do
if plan.groups[g.id]then parts[#parts+1]=g.name end
end
return table.concat({
"Write the changes to the disk? It is ERASED and Nexus "
..tostring(src.manifest.version or"").." is installed on it:",
"",
info and disk.describe(info)or plan.target,
"",
"Hostname: "..plan.hostname,
"User: "..plan.user.name.." (may use sudo; root stays locked)",
"Kernel image: "..(plan.kernel=="store"and"uncompressed"or"compressed"),
"Optional parts: "..(#parts>0 and table.concat(parts,", ")or"none"),
"Source: "..(src.kind=="online"and src.base or"bundled release"),
},"\n")
end
local steps={
function()
local items={{label="Install Nexus"},
{label=a.staged and"Cancel and restart the previous system"or"Shut down"}}
local i=tui.menu("Nexus installer","Welcome. This installs Nexus, a Unix-like system for "
.."OpenComputers, on a disk of this computer.",items)
if i==2 then
if tui.yesno("Cancel",a.staged and"Stop the installer and restart the system it replaced? "
.."Nothing has been erased."or"Shut down the computer?",false)then
stage1.cancel(ctx)
end
return nil
end
return i==1 or nil
end,
function(dir)
local choices={}
if net.card()then
choices[#choices+1]={label="Download the current release (internet card)",kind="online"}
end
if ctx.bundle then
choices[#choices+1]={label="Use the bundled release "
..tostring(ctx.bundle.manifest.version or""),kind="offline"}
end
if#choices==0 then
tui.message("Installation source","There is no internet card and no bundled release in "
..STAGE..". Add an internet card, or start the installer from an install medium.")
return false
end
if#choices==1 and dir<0 then return false end
local i=1
if#choices>1 then
i=tui.menu("Installation source","Where should Nexus be installed from?",choices,
(a.source=="offline"and#choices==2)and 2 or 1)
if not i then return false end
end
local progress=tui.progress("Installation source")
progress(0,"Reading the release information")
local s,err=openSource(ctx,choices[i].kind,function(m)
return tui.yesno("Installer update","The release has a newer installer (revision "
..m.installer..", this is "..INSTALLER_REV.."). Update the installer and "
.."start again?",true)
end)
if not s then
tui.message("Installation source","This source cannot be used:\n\n"..errorText(err))
return#choices==1 and false or nil
end
src=s
plan.groups=groupSet(src.manifest,a.groups)
return true
end,
function()
local list,items,selected={},{},1
local want=plan.target or(a.staged and ctx.bootAddress)
for _,d in ipairs(disk.list())do
if not d.readOnly then
list[#list+1]=d
items[#items+1]={label=disk.describe(d)..(d.boot and"  (this disk)"or"")}
if d.address==want then selected=#list end
end
end
if#list==0 then
tui.message("Disks","There is no writable disk.")
return false
end
local i=tui.menu("Select disk","Nexus is installed on a whole disk; everything on it "
.."is erased. Select the disk:",items,selected)
if not i then return false end
plan.target=list[i].address
local problem=spaceProblem(ctx,src,plan)
if problem then
tui.message("Not enough space",problem)
return nil
end
return true
end,
function()
while true do
local v=tui.input("Hostname","Enter the hostname of this system: one word that names "
.."the computer.",{default=plan.hostname})
if not v then return false end
if util.validHostname(v)then
plan.hostname=v
return true
end
tui.message("Hostname","Use letters, digits and '-' (not first), at most 63 characters.")
end
end,
function()
local name=tui.input("Set up users","Create the account you use instead of root. Root "
.."stays locked; this account may use sudo.\n\nUsername:",{default=plan.user.name})
if not name then return false end
if not util.validUsername(name)then
tui.message("Set up users","Use lowercase letters, digits, '_' and '-', starting with a "
.."letter or '_', at most 32 characters (not root).")
return nil
end
while true do
local first=tui.input("Set up users","Choose a password for "..name..":",{mask=true})
if not first then return nil end
if first==""then
tui.message("Set up users","The password must not be empty.")
else
local second=tui.input("Set up users","Enter the same password again:",{mask=true})
if second==first then
plan.user={name=name,hash=util.passwordHash(first)}
return true
elseif second then
tui.message("Set up users","The passwords do not match.")
end
end
end
end,
function(dir)
local groups=src.manifest.groups
if#groups==0 then return dir>0 end
local items={}
for i,g in ipairs(groups)do
items[i]={label=g.name..(g.desc and(" - "..g.desc)or""),checked=plan.groups[g.id]==true}
end
local r=tui.checklist("Software selection","The base system is always installed. "
.."Choose the optional parts:",items)
if not r then return false end
for i,g in ipairs(groups)do plan.groups[g.id]=items[i].checked or nil end
return true
end,
function()
local i=tui.menu("Kernel image","How should the kernel image /boot/nexusos be stored?",{
{label="Compressed (zlib): smaller"},
{label="Uncompressed: 4x larger, loads faster without a data card"},
},plan.kernel=="store"and 2 or 1)
if not i then return false end
plan.kernel=i==2 and"store"or"zlib"
local problem=spaceProblem(ctx,src,plan)
if problem then
tui.message("Not enough space",problem)
return nil
end
return true
end,
function()
return tui.yesno("Confirm",summary(),false)==true
end,
function()
local progress=tui.progress("Installing Nexus")
local ok,err=xpcall(run,debug.traceback,ctx,src,plan,progress)
if not ok and type(err)~="string"then error(err,0)end
if ok then
tui.message("Installation complete","Nexus is installed. "
..(plan.target~=ctx.bootAddress and"You can remove the install medium. "or"")
.."The computer restarts into Nexus; log in as "..plan.user.name..".")
computer.shutdown(true)
end
return failed(ctx,err,not ctx.erased)=="back"and false or nil
end,
}
local step,dir=1,1
while true do
local result=steps[step](dir)
if result==true then
step,dir=step+1,1
elseif result==false then
step,dir=math.max(1,step-1),-1
else
dir=1
end
end
end
function stage1.main(...)
local ctx=context((...)=="--updated")
ctx.ui=tui.init()
local a=ctx.answers
if ctx.answersError then
if not ctx.ui then error("nexus-install: "..ctx.answersError,0)end
tui.message("Answers","Ignoring "..STAGE.."/answers.lua: "..ctx.answersError)
end
if a.confirmed or a.unattended then return stage1.auto(ctx)end
if not ctx.ui then
error("nexus-install: no screen; put answers.lua with unattended = true in "..STAGE,0)
end
return stage1.interactive(ctx)
end
end
do
stage0={}
local USAGE=[[
usage: nexus-install [<address|label>] [options]
  Prepares the disk (default: the boot disk) and restarts into the
  installer. Nothing is erased before you confirm there.
  --from <dir|url>       release to install: a directory made by
                         `lua tools/nximg.lua dist` (copied to the disk,
                         installs offline) or its URL
  --answers <file>       answers.lua to start from
  --hostname <name>      --user <name>      --password-hash <hex>
  --groups <all|none|id,...>                --kernel <zlib|store>
  --unattended           install without questions (needs --user and
                         --password-hash, the /etc/shadow hash)
  -y, --yes              restart without asking
  --no-reboot            prepare only
  --self <file>          this installer's file, if it cannot be found]]
local VALUE={from=true,answers=true,hostname=true,user=true,["password-hash"]=true,
groups=true,kernel=true,self=true}
local function parse(args)
local opts={}
local i=1
while i<=args.n do
local a=args[i]
local long=a:match("^%-%-(.+)$")
if long and VALUE[long]then
i=i+1
if args[i]==nil then return nil,a.." needs a value"end
opts[long]=args[i]
elseif a=="-y"or a=="--yes"then
opts.yes=true
elseif a=="--unattended"then
opts.unattended=true
elseif a=="--no-reboot"then
opts.noReboot=true
elseif a=="-h"or a=="--help"then
opts.help=true
elseif a:sub(1,1)=="-"then
return nil,"unknown option "..a
elseif opts.target then
return nil,"more than one target"
else
opts.target=a
end
i=i+1
end
return opts
end
local function api(name)
local ok,lib=pcall(require,name)
if ok and type(lib)=="table"then return lib end
end
local function readHostFile(path)
local file=io.open(path,"rb")
if not file then return nil,"cannot open "..path end
local text=file:read("*a")
file:close()
return text
end
local function ownSource(given)
local candidates={given}
if debug and debug.getinfo then
for level=1,3 do
local info=debug.getinfo(level,"S")
local path=info and type(info.source)=="string"and info.source:match("^[@=](/.+)$")
if path then candidates[#candidates+1]=path end
end
end
local process=api("process")
if process and process.info then
local info=process.info()
if info and type(info.path)=="string"then candidates[#candidates+1]=info.path end
end
candidates[#candidates+1]=os.getenv and os.getenv("_")
for i=1,#candidates+1 do
local path=candidates[i]
if type(path)=="string"then
local text=readHostFile(path)
if text and text:find("local INSTALLER_REV%s*=")then return text end
end
end
end
local function findTarget(name,boot)
if not name then return boot end
for address in component.list("filesystem")do
if address:sub(1,#name)==name then return address end
end
for address in component.list("filesystem")do
if component.invoke(address,"getLabel")==name then return address end
end
end
function stage0.main(args)
local ok,result=xpcall(stage0.run,debug.traceback,args)
if ok then return result end
if type(result)~="string"then error(result,0)end
io.stderr:write("nexus-install: "..(result:match("^[^\n]*")or"?").."\n")
return 1
end
function stage0.run(args)
local function fail(message)
io.stderr:write("nexus-install: "..tostring(message).."\n")
return 1
end
local opts,perr=parse(args)
if not opts then return fail(perr.."\n"..USAGE)end
component=component or api("component")
computer=computer or api("computer")
if not component or not computer or not component.proxy or not computer.getBootAddress then
return fail("this OS gives programs no component access; boot an install medium "
.."instead (lua tools/nximg.lua media)")
end
local boot=computer.getBootAddress()
if opts.help then
print(USAGE)
print("disks:")
for _,d in ipairs(disk.list())do
print((d.boot and"* "or"  ")..disk.describe(d))
end
return 0
end
local code=ownSource(opts.self)
if not code then return fail("cannot find the installer's own file; pass --self <path>")end
local target=findTarget(opts.target,boot)
if not target then return fail("no filesystem matches "..tostring(opts.target))end
if target==(computer.tmpAddress and computer.tmpAddress())then return fail("the target is the tmpfs")end
local fs=component.proxy(target)
if fs.isReadOnly()then return fail("the target is read-only")end
local a={}
if opts.answers then
local text,err=readHostFile(opts.answers)
if not text then return fail(err)end
local loaded,lerr=util.loadData(text,opts.answers)
if type(loaded)~="table"then return fail(lerr or(opts.answers.." does not return a table"))end
a=loaded
end
if opts.hostname then a.hostname=opts.hostname end
if opts.user or opts["password-hash"]then
a.user=type(a.user)=="table"and a.user or{}
a.user.name=opts.user or a.user.name
a.user.hash=opts["password-hash"]or a.user.hash
end
if opts.groups then
if opts.groups=="all"or opts.groups=="none"then
a.groups=opts.groups
else
a.groups={}
for id in opts.groups:gmatch("[^,]+")do a.groups[#a.groups+1]=id end
end
end
if opts.kernel then a.kernel=opts.kernel end
if opts.unattended then a.unattended=true end
if a.unattended and(type(a.user)~="table"or not a.user.name or not a.user.hash)then
return fail("--unattended needs --user and --password-hash")
end
a.staged,a.restore_boot=true,boot
if a.target and a.target~=target then a.target=nil end
local bundle
if opts.from then
if opts.from:match("^%a[%w+.-]*://")then
a.base,a.source=opts.from,"online"
else
local dir=opts.from:gsub("/+$","")
local text,err=readHostFile(dir.."/manifest.lua")
if not text then return fail(err)end
local m,merr=source.parseManifest(text)
if not m then return fail(merr)end
bundle={dir=dir,manifest=m,text=text}
a.source="offline"
end
end
local need=#code+4096
if bundle then
need=need+#bundle.text
for _,f in ipairs(bundle.manifest.files)do need=need+(f.size or 0)end
end
local free=(fs.spaceTotal()or 0)-(fs.spaceUsed()or 0)+disk.treeSize(fs,STAGE)
if free<need then
return fail(string.format("not enough space on %s: %s free, %s needed",target:sub(1,8),
util.size(free),util.size(need)))
end
if fs.isDirectory(STAGE)then
for _,name in ipairs(fs.list(STAGE)or{})do
if name~="init.lua.orig"then disk.removeTree(fs,STAGE.."/"..name:gsub("/$",""))end
end
else
disk.mkdir(fs,STAGE)
end
if fs.exists("/init.lua")and not fs.exists(STAGE.."/init.lua.orig")then
local current,err=disk.readAll(fs,"/init.lua")
if not current then return fail(err)end
if not current:find("local INSTALLER_REV%s*=")then
disk.writeAll(fs,STAGE.."/init.lua.orig",current)
end
end
if bundle then
io.write("Copying the release from "..bundle.dir)
for _,f in ipairs(bundle.manifest.files)do
local file=io.open(bundle.dir.."/"..f.name,"rb")
if not file then return fail("cannot open "..bundle.dir.."/"..f.name)end
local write,close=disk.writer(fs,STAGE.."/"..f.name)
while true do
local chunk=file:read(8192)
if not chunk then break end
write(chunk)
end
close()
file:close()
io.write(".")
end
disk.writeAll(fs,STAGE.."/manifest.lua",bundle.text)
print("")
end
disk.writeAll(fs,STAGE.."/answers.lua","return "..util.serialize(a).."\n")
disk.replace(fs,"/init.lua",code)
if target~=boot then
if not computer.setBootAddress then return fail("cannot set the boot disk on this OS")end
computer.setBootAddress(target)
end
print("The installer is on "..target:sub(1,8).." as /init.lua; the old one is kept in "
..STAGE..".")
print("Nothing is erased before you confirm in the installer, and Cancel there restores the old system.")
if opts.noReboot then
print("Restart the computer to start the installer.")
return 0
end
if not opts.yes then
io.write("Restart into the installer now? [Y/n] ")
local answer=io.read()
if answer and answer:lower():match("^n")then
print("Restart the computer to start the installer.")
return 0
end
end
computer.shutdown(true)
return 0
end
end
do
local args=table.pack(...)
if require==nil and package==nil then
stage1.main(table.unpack(args,1,args.n))
else
return stage0.main(args)
end
end
