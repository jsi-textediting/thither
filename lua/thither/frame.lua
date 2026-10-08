--- Framing for the remote protocol: `u32 little-endian length | msgpack`.
--- Pure Lua, no lite-xl dependencies (runs under plain Lua 5.4+).
-- sibling module: "plugins.thither.msgpack" in Lite XL, "thither.msgpack" in thither
local msgpack = require((((...) or "thither.frame"):gsub("frame$", "msgpack")))

local frame = {}

--- Maximum payload length of a frame (16 MiB).
frame.MAX_FRAME = 16 * 1024 * 1024

local spack, sunpack, ssub = string.pack, string.unpack, string.sub
local tconcat = table.concat

--- 4-byte length header for a payload of `len` bytes.
function frame.header(len)
  return spack("<I4", len)
end

--- Encodes a value as a complete frame. Raises if it exceeds MAX_FRAME.
function frame.encode(value)
  local payload = msgpack.encode(value)
  if #payload > frame.MAX_FRAME then
    error("frame too large: " .. #payload .. " bytes", 0)
  end
  return spack("<I4", #payload) .. payload
end

---@class frame.Reader
--- Incremental frame parser. Feed it bytes as they arrive, then call next()
--- until it returns nothing. Large frames arriving in many small reads are
--- collected in a list and joined once, so reading is linear in frame size.
local Reader = {}
Reader.__index = Reader

function frame.reader(max_frame)
  return setmetatable({
    max = max_frame or frame.MAX_FRAME,
    buf = "",      -- unread bytes (starting at pos)
    pos = 1,
    parts = {},    -- bytes received but not yet joined into buf
    nparts = 0,
    plen = 0,      -- total length of parts
    need = nil,    -- payload length of the frame being collected
  }, Reader)
end

function Reader:feed(data)
  if #data == 0 then return end
  self.nparts = self.nparts + 1
  self.parts[self.nparts] = data
  self.plen = self.plen + #data
end

local function flatten(self)
  if self.nparts == 0 then return end
  local rest = self.pos > #self.buf and "" or ssub(self.buf, self.pos)
  self.parts[0] = rest
  self.buf = tconcat(self.parts, "", rest == "" and 1 or 0, self.nparts)
  self.parts, self.nparts, self.plen, self.pos = {}, 0, 0, 1
end

--- Number of buffered bytes not yet consumed.
function Reader:buffered()
  return #self.buf - self.pos + 1 + self.plen
end

--- Returns the next decoded value, or:
---   nil                       when more bytes are needed
---   nil, "frame_too_large", n when the announced length exceeds the cap
---                             (the stream cannot be resynchronised)
---   nil, "bad_frame", msg     when the payload is not valid msgpack; the
---                             frame is consumed, later frames still parse
function Reader:next()
  if not self.need then
    if self:buffered() < 4 then return nil end
    flatten(self)
    local len = sunpack("<I4", self.buf, self.pos)
    if len > self.max then return nil, "frame_too_large", len end
    self.pos = self.pos + 4
    self.need = len
  end
  if self:buffered() < self.need then return nil end
  flatten(self)
  local payload = ssub(self.buf, self.pos, self.pos + self.need - 1)
  self.pos = self.pos + self.need
  self.need = nil
  local ok, value = pcall(msgpack.decode_exact, payload)
  if not ok then return nil, "bad_frame", tostring(value) end
  if value == nil then return nil, "bad_frame", "frame holds nil" end
  return value
end

return frame
