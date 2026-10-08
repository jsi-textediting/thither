--- MessagePack encoder/decoder in pure Lua (5.4+), shared by the remote client
--- and thither-server. It has no dependency on any lite-xl module, so it also
--- runs under a plain `lua` interpreter.
---
--- Type mapping (Lua -> msgpack):
---   nil / msgpack.null  -> nil
---   boolean             -> true / false
---   integer             -> smallest int/uint encoding
---   float               -> float64 (always, so math.type round-trips)
---   string              -> `str` if the bytes are valid UTF-8, otherwise `bin`
---   msgpack.bin(s)      -> `bin`, regardless of content (use it for payloads)
---   table               -> `array` if its keys are exactly 1..#t (an empty
---                          table is an empty array), otherwise `map`
---   msgpack.map(t)      -> forces `map` (e.g. for an empty map)
---
--- Type mapping (msgpack -> Lua):
---   nil                 -> nil at the top level and as a map value (the key
---                          is simply absent); inside an array: msgpack.null
---   str and bin         -> Lua string (byte-exact, both are the same in Lua)
---   int/uint            -> integer (uint64 >= 2^63 becomes a float)
---   float32/float64     -> float
---   array / map         -> table
---   ext types           -> error (not used by the protocol)
---
--- Errors are raised with error(<string>); decode never reads past the end of
--- its input and bounds container sizes by the remaining input length.
local msgpack = {}

local spack, sunpack, ssub, sbyte, srep = string.pack, string.unpack, string.sub, string.byte, string.rep
local mtype, utf8len = math.type, utf8.len
local tconcat = table.concat
local type, pairs, next, error, setmetatable = type, pairs, next, error, setmetatable

local MAX_DEPTH = 64

--- Sentinel for nil inside arrays (Lua tables cannot hold nil).
local null = setmetatable({}, {
  __tostring = function() return "msgpack.null" end,
  __name = "msgpack.null",
})
msgpack.null = null

local BinMT = { __name = "msgpack.bin" }
local forced_map = setmetatable({}, { __mode = "k" })

--- Marks a string to be encoded as msgpack `bin`.
function msgpack.bin(s)
  return setmetatable({ s = s }, BinMT)
end

--- Marks a table to be encoded as a map even when it is empty.
function msgpack.map(t)
  forced_map[t] = true
  return t
end

---------------------------------------------------------------------------
-- encoder
---------------------------------------------------------------------------

local encode_value

local function encode_int(v, buf, n)
  if v >= 0 then
    if v < 0x80 then buf[n] = spack("B", v)
    elseif v < 0x100 then buf[n] = spack(">BI1", 0xcc, v)
    elseif v < 0x10000 then buf[n] = spack(">BI2", 0xcd, v)
    elseif v < 0x100000000 then buf[n] = spack(">BI4", 0xce, v)
    else buf[n] = spack(">BI8", 0xcf, v) end
  else
    if v >= -32 then buf[n] = spack("b", v)
    elseif v >= -0x80 then buf[n] = spack(">Bi1", 0xd0, v)
    elseif v >= -0x8000 then buf[n] = spack(">Bi2", 0xd1, v)
    elseif v >= -0x80000000 then buf[n] = spack(">Bi4", 0xd2, v)
    else buf[n] = spack(">Bi8", 0xd3, v) end
  end
  return n + 1
end

local function encode_str(s, buf, n, as_bin)
  local len = #s
  if as_bin then
    if len < 0x100 then buf[n] = spack(">BI1", 0xc4, len)
    elseif len < 0x10000 then buf[n] = spack(">BI2", 0xc5, len)
    else buf[n] = spack(">BI4", 0xc6, len) end
  else
    if len < 32 then buf[n] = spack("B", 0xa0 | len)
    elseif len < 0x100 then buf[n] = spack(">BI1", 0xd9, len)
    elseif len < 0x10000 then buf[n] = spack(">BI2", 0xda, len)
    else buf[n] = spack(">BI4", 0xdb, len) end
  end
  buf[n + 1] = s
  return n + 2
end

local function is_array(t)
  if forced_map[t] then return false end
  if next(t) == nil then return true, 0 end
  local len = #t
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  if count ~= len then return false end
  for i = 1, len do
    if t[i] == nil then return false end
  end
  return true, len
end

encode_value = function(v, buf, n, depth)
  local t = type(v)
  if t == "string" then
    return encode_str(v, buf, n, utf8len(v) == nil)
  elseif t == "number" then
    if mtype(v) == "integer" then return encode_int(v, buf, n) end
    buf[n] = spack(">Bd", 0xcb, v)
    return n + 1
  elseif t == "boolean" then
    buf[n] = v and "\xc3" or "\xc2"
    return n + 1
  elseif t == "nil" or v == null then
    buf[n] = "\xc0"
    return n + 1
  elseif t == "table" then
    if getmetatable(v) == BinMT then return encode_str(v.s, buf, n, true) end
    if depth >= MAX_DEPTH then error("msgpack: nesting too deep") end
    local arr, len = is_array(v)
    if arr then
      if len < 16 then buf[n] = spack("B", 0x90 | len)
      elseif len < 0x10000 then buf[n] = spack(">BI2", 0xdc, len)
      else buf[n] = spack(">BI4", 0xdd, len) end
      n = n + 1
      for i = 1, len do n = encode_value(v[i], buf, n, depth + 1) end
      return n
    end
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    if count < 16 then buf[n] = spack("B", 0x80 | count)
    elseif count < 0x10000 then buf[n] = spack(">BI2", 0xde, count)
    else buf[n] = spack(">BI4", 0xdf, count) end
    n = n + 1
    for k, val in pairs(v) do
      if k == null then error("msgpack: null cannot be a map key") end
      n = encode_value(k, buf, n, depth + 1)
      n = encode_value(val, buf, n, depth + 1)
    end
    return n
  end
  error("msgpack: cannot encode a " .. t)
end

--- Encodes a Lua value, returns the msgpack bytes.
function msgpack.encode(v)
  local buf = {}
  encode_value(v, buf, 1, 0)
  return tconcat(buf)
end

---------------------------------------------------------------------------
-- decoder
---------------------------------------------------------------------------

local decode_value

local function need(s, i, len)
  if i + len - 1 > #s then error("msgpack: truncated input") end
end

-- only containers count towards the nesting limit, as in the encoder: a
-- container at depth MAX_DEPTH is refused, its scalar elements are fine
local function decode_array(s, i, count, depth)
  if depth >= MAX_DEPTH then error("msgpack: nesting too deep") end
  if count > #s - i + 1 then error("msgpack: truncated input") end
  local t = {}
  for k = 1, count do
    local v
    v, i = decode_value(s, i, depth + 1)
    if v == nil then v = null end
    t[k] = v
  end
  return t, i
end

local function decode_map(s, i, count, depth)
  if depth >= MAX_DEPTH then error("msgpack: nesting too deep") end
  if count * 2 > #s - i + 1 then error("msgpack: truncated input") end
  local t = {}
  for _ = 1, count do
    local k, v
    k, i = decode_value(s, i, depth + 1)
    if k == nil then error("msgpack: nil map key") end
    v, i = decode_value(s, i, depth + 1)
    t[k] = v
  end
  return t, i
end

local function decode_str(s, i, len)
  need(s, i, len)
  return ssub(s, i, i + len - 1), i + len
end

decode_value = function(s, i, depth)
  local b = sbyte(s, i)
  if not b then error("msgpack: truncated input") end
  i = i + 1
  if b < 0x80 then return b, i end
  if b >= 0xe0 then return b - 256, i end
  if b >= 0xa0 and b <= 0xbf then return decode_str(s, i, b & 0x1f) end
  if b >= 0x90 and b <= 0x9f then return decode_array(s, i, b & 0x0f, depth) end
  if b >= 0x80 and b <= 0x8f then return decode_map(s, i, b & 0x0f, depth) end
  if b == 0xc0 then return nil, i end
  if b == 0xc2 then return false, i end
  if b == 0xc3 then return true, i end
  local len
  if b == 0xc4 or b == 0xd9 then len, i = sunpack(">I1", s, i); return decode_str(s, i, len) end
  if b == 0xc5 or b == 0xda then len, i = sunpack(">I2", s, i); return decode_str(s, i, len) end
  if b == 0xc6 or b == 0xdb then len, i = sunpack(">I4", s, i); return decode_str(s, i, len) end
  if b == 0xcc then return sunpack(">I1", s, i) end
  if b == 0xcd then return sunpack(">I2", s, i) end
  if b == 0xce then return sunpack(">I4", s, i) end
  if b == 0xcf then
    local v, ni = sunpack(">I8", s, i)
    if v < 0 then v = v + 18446744073709551616.0 end
    return v, ni
  end
  if b == 0xd0 then return sunpack(">i1", s, i) end
  if b == 0xd1 then return sunpack(">i2", s, i) end
  if b == 0xd2 then return sunpack(">i4", s, i) end
  if b == 0xd3 then return sunpack(">i8", s, i) end
  if b == 0xca then return sunpack(">f", s, i) end
  if b == 0xcb then return sunpack(">d", s, i) end
  if b == 0xdc then len, i = sunpack(">I2", s, i); return decode_array(s, i, len, depth) end
  if b == 0xdd then len, i = sunpack(">I4", s, i); return decode_array(s, i, len, depth) end
  if b == 0xde then len, i = sunpack(">I2", s, i); return decode_map(s, i, len, depth) end
  if b == 0xdf then len, i = sunpack(">I4", s, i); return decode_map(s, i, len, depth) end
  if b == 0xc1 then error("msgpack: invalid type byte 0xc1") end
  error(string.format("msgpack: unsupported ext type byte 0x%02x", b))
end

--- Decodes one value starting at byte `init` (default 1).
--- Returns the value and the index of the first unread byte.
function msgpack.decode(s, init)
  local ok, v, i = pcall(decode_value, s, init or 1, 0)
  if not ok then
    -- string.unpack reports short data in its own words
    local msg = tostring(v)
    if msg:find("too short", 1, true) then msg = "msgpack: truncated input" end
    error(msg, 0)
  end
  return v, i
end

--- Like decode but the whole string must be exactly one value.
function msgpack.decode_exact(s)
  local v, i = msgpack.decode(s, 1)
  if i ~= #s + 1 then error("msgpack: trailing bytes after value", 0) end
  return v
end

return msgpack
