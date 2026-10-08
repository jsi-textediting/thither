-- Framing tests. Run standalone: lua tests/test_frame.lua
local dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/../lua/?.lua;" .. package.path
local H = require "harness"
local mp = require "thither.msgpack"
local frame = require "thither.frame"

H.test("frame: encode layout is u32le length + msgpack", function()
  H.eq(H.hex(frame.encode({ 1, 2, 3 })), "04000000" .. "93010203")
  H.eq(frame.header(0x01020304), "\4\3\2\1")
end)

H.test("frame: reader handles frames split at any boundary", function()
  local msgs = { { id = 1, op = "stat" }, { id = 2, ok = { size = 5 } }, { ev = "x", data = mp.bin("\0\255") } }
  local stream = ""
  for _, m in ipairs(msgs) do stream = stream .. frame.encode(m) end
  for chunk = 1, 7 do
    local r = frame.reader()
    local got = {}
    for i = 1, #stream, chunk do
      r:feed(stream:sub(i, i + chunk - 1))
      while true do
        local v, err = r:next()
        if v == nil then H.eq(err, nil); break end
        got[#got + 1] = v
      end
    end
    H.eq(#got, 3, "chunk " .. chunk)
    H.eq(got[1], msgs[1]); H.eq(got[2], msgs[2])
    H.eq(got[3].data, "\0\255")
  end
end)

H.test("frame: many frames in one feed", function()
  local parts = {}
  for i = 1, 5000 do parts[i] = frame.encode({ id = i }) end
  local r = frame.reader()
  r:feed(table.concat(parts))
  for i = 1, 5000 do
    H.eq(r:next().id, i)
  end
  H.eq(r:next(), nil)
  H.eq(r:buffered(), 0)
end)

H.test("frame: a 16 MiB frame arrives in 64 KiB reads in linear time", function()
  -- payload exactly at the cap: bin32 header (5 bytes) + data
  local data = string.rep("z", frame.MAX_FRAME - 5)
  local payload = "\xc6" .. string.pack(">I4", #data) .. data
  H.eq(#payload, frame.MAX_FRAME)
  local stream = string.pack("<I4", #payload) .. payload
  local r = frame.reader()
  local t0 = os.clock()
  local got
  for i = 1, #stream, 65536 do
    r:feed(stream:sub(i, i + 65535))
    got = r:next() or got
  end
  H.ok(os.clock() - t0 < 5, "too slow")
  H.eq(#got, #data)
end)

H.test("frame: oversized announcement is rejected", function()
  local r = frame.reader()
  r:feed(string.pack("<I4", frame.MAX_FRAME + 1))
  local v, code, n = r:next()
  H.eq(v, nil); H.eq(code, "frame_too_large"); H.eq(n, frame.MAX_FRAME + 1)
  H.raises(function() frame.encode(mp.bin(string.rep("a", frame.MAX_FRAME))) end, "too large")
  local r2 = frame.reader(100)
  r2:feed(string.pack("<I4", 101))
  H.eq(select(2, r2:next()), "frame_too_large")
end)

H.test("frame: a malformed payload is consumed and later frames still parse", function()
  local r = frame.reader()
  r:feed(string.pack("<I4", 3) .. "\xc1\xc1\xc1" .. frame.encode({ ok = true }))
  local v, code = r:next()
  H.eq(v, nil); H.eq(code, "bad_frame")
  H.eq(r:next(), { ok = true })
  r:feed(string.pack("<I4", 2) .. "\x01\x02")
  H.eq(select(2, r:next()), "bad_frame", "trailing bytes")
  r:feed(string.pack("<I4", 0))
  H.eq(select(2, r:next()), "bad_frame", "empty payload")
end)

if H.standalone("test_frame.lua") then
  local p, f = H.run()
  print(string.format("%d passed, %d failed", p, f))
  os.exit(f == 0 and 0 or 1)
end
