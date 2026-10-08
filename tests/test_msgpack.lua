-- msgpack encoder/decoder tests. Run standalone: lua tests/test_msgpack.lua
local dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/../lua/?.lua;" .. package.path
local H = require "harness"
local mp = require "thither.msgpack"
local hex, unhex = H.hex, H.unhex

local function rt(v) return mp.decode_exact(mp.encode(v)) end

H.test("msgpack: scalar encodings match the spec", function()
  H.eq(hex(mp.encode(nil)), "c0")
  H.eq(hex(mp.encode(true)), "c3")
  H.eq(hex(mp.encode(false)), "c2")
  H.eq(hex(mp.encode(0)), "00")
  H.eq(hex(mp.encode(127)), "7f")
  H.eq(hex(mp.encode(128)), "cc80")
  H.eq(hex(mp.encode(255)), "ccff")
  H.eq(hex(mp.encode(256)), "cd0100")
  H.eq(hex(mp.encode(65535)), "cdffff")
  H.eq(hex(mp.encode(65536)), "ce00010000")
  H.eq(hex(mp.encode(4294967295)), "ceffffffff")
  H.eq(hex(mp.encode(4294967296)), "cf0000000100000000")
  H.eq(hex(mp.encode(math.maxinteger)), "cf7fffffffffffffff")
  H.eq(hex(mp.encode(-1)), "ff")
  H.eq(hex(mp.encode(-32)), "e0")
  H.eq(hex(mp.encode(-33)), "d0df")
  H.eq(hex(mp.encode(-128)), "d080")
  H.eq(hex(mp.encode(-129)), "d1ff7f")
  H.eq(hex(mp.encode(-32768)), "d18000")
  H.eq(hex(mp.encode(-32769)), "d2ffff7fff")
  H.eq(hex(mp.encode(-2147483648)), "d280000000")
  H.eq(hex(mp.encode(-2147483649)), "d3ffffffff7fffffff")
  H.eq(hex(mp.encode(math.mininteger)), "d38000000000000000")
  H.eq(hex(mp.encode(1.5)), "cb3ff8000000000000")
  H.eq(hex(mp.encode("")), "a0")
  H.eq(hex(mp.encode("abc")), "a3616263")
  H.eq(hex(mp.encode({})), "90")
  H.eq(hex(mp.encode({ 1, 2, 3 })), "93010203")
  H.eq(hex(mp.encode({ a = 1 })), "81a16101")
  H.eq(hex(mp.encode(mp.map({}))), "80")
end)

H.test("msgpack: integers round trip with their subtype", function()
  local vals = { 0, 1, 31, 32, 127, 128, 255, 256, 65535, 65536, 1 << 31, 1 << 32, (1 << 32) - 1,
                 math.maxinteger, -1, -31, -32, -33, -127, -128, -129, -32768, -32769,
                 -(1 << 31), -(1 << 31) - 1, math.mininteger }
  for _, v in ipairs(vals) do
    local r = rt(v)
    H.eq(r, v)
    H.eq(math.type(r), "integer", "subtype of " .. v)
  end
end)

H.test("msgpack: floats round trip with their subtype", function()
  for _, v in ipairs({ 0.0, -0.0, 1.5, -1.5, 3.0, 1e308, 5e-324, math.huge, -math.huge, 0.1 }) do
    local r = rt(v)
    H.eq(r, v)
    H.eq(math.type(r), "float")
  end
  local nan = rt(0/0)
  H.ok(nan ~= nan, "nan survives")
  H.eq(1 / rt(-0.0), -math.huge, "negative zero keeps its sign")
  H.eq(math.type(rt(3.0)), "float")
end)

H.test("msgpack: float32 and uint64 decoding", function()
  H.eq(mp.decode_exact(unhex("ca3fc00000")), 1.5)
  H.eq(mp.decode_exact(unhex("cfffffffffffffffff")), 18446744073709551615.0)
  H.eq(math.type(mp.decode_exact(unhex("cfffffffffffffffff"))), "float")
end)

H.test("msgpack: string vs bin rule", function()
  H.eq(hex(mp.encode("h\xc3\xa9llo")):sub(1, 2), "a6", "valid utf-8 -> str")
  H.eq(hex(mp.encode("\xff\xfe")), "c402fffe", "invalid utf-8 -> bin")
  H.eq(hex(mp.encode("a\0b")):sub(1, 2), "a3", "NUL is valid utf-8 -> str")
  H.eq(hex(mp.encode("\xed\xa0\x80")):sub(1, 2), "c4", "surrogate -> bin")
  H.eq(hex(mp.encode(mp.bin("abc"))), "c403616263", "explicit bin")
  H.eq(hex(mp.encode(mp.bin(""))), "c400")
  H.eq(hex(mp.encode(string.rep("a", 31))):sub(1, 2), "bf")
  H.eq(hex(mp.encode(string.rep("a", 32))):sub(1, 4), "d920")
  H.eq(hex(mp.encode(string.rep("a", 256))):sub(1, 6), "da0100")
  H.eq(hex(mp.encode(string.rep("a", 65536))):sub(1, 10), "db00010000")
  H.eq(hex(mp.encode(mp.bin(string.rep("a", 256)))):sub(1, 6), "c50100")
  H.eq(hex(mp.encode(mp.bin(string.rep("a", 65536)))):sub(1, 10), "c600010000")
end)

H.test("msgpack: all 256 byte values survive, as str-or-bin", function()
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  local s = table.concat(all)
  H.eq(rt(s), s)
  H.eq(rt(mp.bin(s)), s)
  local big = string.rep(s, 1000)
  H.eq(rt(big), big)
  for i = 0, 255 do
    local c = string.char(i)
    H.eq(rt(c), c)
    H.eq(rt(mp.bin(c)), c)
  end
end)

H.test("msgpack: decoder treats str and bin alike", function()
  H.eq(mp.decode_exact(unhex("a3616263")), "abc")
  H.eq(mp.decode_exact(unhex("c403616263")), "abc")
  H.eq(mp.decode_exact(unhex("d903616263")), "abc")
  H.eq(mp.decode_exact(unhex("da0003616263")), "abc")
  H.eq(mp.decode_exact(unhex("db00000003616263")), "abc")
  H.eq(mp.decode_exact(unhex("c50003616263")), "abc")
  H.eq(mp.decode_exact(unhex("c600000003616263")), "abc")
end)

H.test("msgpack: container size boundaries", function()
  for _, n in ipairs({ 0, 1, 15, 16, 17, 255, 256, 65535, 65536, 70000 }) do
    local a = {}
    for i = 1, n do a[i] = i end
    local r = rt(a)
    H.eq(#r, n, "array " .. n)
    if n > 0 then H.eq(r[n], n) end
  end
  for _, n in ipairs({ 1, 15, 16, 17, 65535, 65536 }) do
    local m = {}
    for i = 1, n do m["k" .. i] = i end
    local r = rt(m)
    local c = 0
    for k, v in pairs(r) do c = c + 1; H.eq(k, "k" .. v) end
    H.eq(c, n, "map " .. n)
  end
  local a16 = {}
  for i = 1, 16 do a16[i] = 0 end
  H.eq(hex(mp.encode(a16)):sub(1, 6), "dc0010")
end)

H.test("msgpack: table classification", function()
  H.eq(hex(mp.encode({})), "90", "empty table is an array")
  H.eq(rt({}), {})
  H.eq(hex(mp.encode({ [1] = "a", [3] = "c" })):sub(1, 2), "82", "sparse -> map")
  H.eq(rt({ [1] = "a", [3] = "c" }), { [1] = "a", [3] = "c" })
  H.eq(hex(mp.encode({ 1, 2, x = 3 })):sub(1, 2), "83", "mixed -> map")
  H.eq(rt({ 1, 2, x = 3 }), { 1, 2, x = 3 })
  H.eq(rt({ [-5] = true, [2.5] = "f", [true] = 1 }), { [-5] = true, [2.5] = "f", [true] = 1 })
  H.eq(rt(mp.map({})), {})
  H.eq(hex(mp.encode({ {}, {} })), "929090")
end)

H.test("msgpack: nil and null handling", function()
  H.eq(mp.decode_exact("\xc0"), nil)
  local r = rt({ 1, mp.null, 3 })
  H.eq(r[1], 1); H.eq(r[2], mp.null); H.eq(r[3], 3); H.eq(#r, 3)
  H.eq(rt({ a = 1 }), { a = 1 })
  -- a nil map value on the wire means the key is absent
  H.eq(mp.decode_exact(unhex("82 a1 61 c0 a1 62 02")), { b = 2 })
  H.eq(rt(mp.null), nil)
  H.raises(function() mp.encode({ [mp.null] = 1 }) end, "null")
  H.raises(function() mp.decode_exact(unhex("81 c0 01")) end, "nil map key")
end)

H.test("msgpack: nested structures", function()
  local v = { id = 7, op = "readdir", args = { path = "/tmp", list = { 1, 2.5, "x", { true, false } },
              blob = mp.bin("\0\1\2\255") } }
  local r = rt(v)
  H.eq(r.args.blob, "\0\1\2\255")
  v.args.blob = "\0\1\2\255"
  H.eq(r, v)
end)

H.test("msgpack: decode returns the next position", function()
  local s = mp.encode(1) .. mp.encode("two") .. mp.encode({ 3 })
  local v1, i = mp.decode(s, 1)
  local v2, j = mp.decode(s, i)
  local v3, k = mp.decode(s, j)
  H.eq(v1, 1); H.eq(v2, "two"); H.eq(v3, { 3 }); H.eq(k, #s + 1)
  H.raises(function() mp.decode_exact(s) end, "trailing")
end)

H.test("msgpack: truncated input never over-reads", function()
  local complex = mp.encode({ a = { 1, 2.5, "h\xc3\xa9llo", mp.bin(string.rep("x", 300)) },
                              b = { c = -70000, d = 1 << 40 }, e = string.rep("y", 70000) })
  local cut = 0
  while cut < #complex do
    local ok = pcall(mp.decode_exact, complex:sub(1, cut))
    if ok then error("prefix of length " .. cut .. " decoded without error") end
    cut = cut + (cut > 200 and 997 or 1)
  end
  H.raises(function() mp.decode_exact(complex:sub(1, #complex - 1)) end, "truncated")
  H.eq(mp.decode_exact(complex).e, string.rep("y", 70000))
end)

H.test("msgpack: hostile sizes are rejected", function()
  H.raises(function() mp.decode_exact(unhex("dd ffffffff")) end, "truncated")
  H.raises(function() mp.decode_exact(unhex("df ffffffff")) end, "truncated")
  H.raises(function() mp.decode_exact(unhex("db ffffffff 61")) end, "truncated")
  H.raises(function() mp.decode_exact(unhex("c6 ffffffff")) end, "truncated")
  H.raises(function() mp.decode_exact(unhex("dc ffff 01")) end, "truncated")
end)

H.test("msgpack: depth is bounded", function()
  local deep = {}
  local cur = deep
  for _ = 1, 100 do local n = {}; cur[1] = n; cur = n end
  H.raises(function() mp.encode(deep) end, "too deep")
  H.raises(function() mp.decode_exact(string.rep("\x91", 100) .. "\x90") end, "too deep")
  local ok = {}
  cur = ok
  for _ = 1, 50 do local n = {}; cur[1] = n; cur = n end
  mp.encode(ok)
end)

H.test("msgpack: what encode accepts at the depth limit decodes", function()
  -- 64 nested containers (depths 0..63) whose innermost holds scalars
  local top = {}
  local cur = top
  for _ = 1, 63 do local n = {}; cur[1] = n; cur = n end
  cur[1], cur[2], cur[3], cur[4] = "leaf", true, 1.5, 300
  local v = rt(top)
  for _ = 1, 63 do v = v[1] end
  H.eq(v[1], "leaf"); H.eq(v[2], true); H.eq(v[3], 1.5); H.eq(v[4], 300)
  -- one more container level is refused by both sides
  cur[5] = {}
  H.raises(function() mp.encode(top) end, "too deep")
  H.raises(function() mp.decode_exact(string.rep("\x91", 64) .. "\x90") end, "too deep")
  mp.decode_exact(string.rep("\x91", 63) .. "\x90")
end)

H.test("msgpack: unsupported types", function()
  H.raises(function() mp.decode_exact(unhex("d4 01 00")) end, "ext")
  H.raises(function() mp.decode_exact(unhex("c1")) end, "0xc1")
  H.raises(function() mp.encode(function() end) end, "cannot encode")
  H.raises(function() mp.encode({ f = print }) end, "cannot encode")
  H.raises(function() mp.decode_exact("") end, "truncated")
end)

H.test("msgpack: randomized round trip", function()
  math.randomseed(12345)
  local function rstr()
    local t = {}
    for i = 1, math.random(0, 40) do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
  end
  local function rval(depth)
    local k = math.random(1, depth > 3 and 6 or 8)
    if k == 1 then return math.random(math.mininteger, math.maxinteger)
    elseif k == 2 then return math.random(-300, 300)
    elseif k == 3 then return math.random() * 10 ^ math.random(-10, 10)
    elseif k == 4 then return rstr()
    elseif k == 5 then return math.random() < 0.5
    elseif k == 6 then return mp.bin(rstr())
    elseif k == 7 then
      local a = {}
      for i = 1, math.random(1, 6) do a[i] = rval(depth + 1) end
      return a
    else
      local m = {}
      for _ = 1, math.random(1, 6) do m[rstr() .. "k"] = rval(depth + 1) end
      return m
    end
  end
  local function normalize(v)
    if type(v) == "table" then
      if getmetatable(v) and v.s then return v.s end
      local r = {}
      for k, x in pairs(v) do r[k] = normalize(x) end
      return r
    end
    return v
  end
  for _ = 1, 2000 do
    local v = rval(0)
    H.eq(rt(v), normalize(v))
  end
end)

if H.standalone("test_msgpack.lua") then
  local p, f = H.run()
  print(string.format("%d passed, %d failed", p, f))
  os.exit(f == 0 and 0 or 1)
end
