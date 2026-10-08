-- The protocol modules are shared with the Lite XL client, which keeps its own
-- copies in data/plugins/thither/. They must stay identical to lua/thither/
-- (line ends aside). Skipped when thither/ is not inside the editor tree.
local H = require "harness"

local dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("a")
  f:close()
  return (data:gsub("\r\n", "\n"))
end

H.test("copies: Lite XL's msgpack.lua and frame.lua match lua/thither/", function()
  for _, name in ipairs({ "msgpack.lua", "frame.lua" }) do
    local ours = read(dir .. "/../lua/thither/" .. name)
    H.ok(ours, "missing lua/thither/" .. name)
    local theirs = read(dir .. "/../../data/plugins/thither/" .. name)
    if theirs then H.ok(theirs == ours, "data/plugins/thither/" .. name .. " differs from lua/thither/" .. name) end
  end
end)
