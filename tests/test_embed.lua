-- Single-file server: the Lua modules compiled into the binary
-- (src/embed.c, cmake/embed_lua.cmake) and how --datadir overrides them.
-- Skipped for builds with THITHER_EMBED_LUA=OFF.
local H = require "harness"
local U = require "util"
local Client = require "client"
local embed = require "serverembed"

local function embedded() return #embed.list() > 0 end

--- Copies the server binary alone into a fresh directory.
local function lone_server()
  local dir = U.tmpdir("embed")
  local exe = dir .. "/thither-server"
  local _, code = U.sh("cp " .. U.shq(EXEFILE) .. " " .. U.shq(exe))
  H.eq(code, 0, "copy server")
  return exe, dir
end

local function server_files()
  local list = embed.list()
  table.sort(list)
  return list
end

H.test("embed: the server modules are compiled in and --version shows the build id", function()
  if not embedded() then return end
  local list = server_files()
  for _, want in ipairs({ "thither/init.lua", "thither/ops_fs.lua", "thither/plugins.lua",
                          "thither/msgpack.lua", "thither/frame.lua" }) do
    local found = false
    for _, p in ipairs(list) do found = found or p == want end
    H.ok(found, "not embedded: " .. want)
  end
  for _, p in ipairs(list) do H.ok(p:match("^thither/[%w_]+%.lua$"), "unexpected embedded file: " .. p) end
  H.ok(embed.build_id:match("^%x%x%x%x%x%x%x%x%x%x%x%x$"), embed.build_id)
  local out = U.sh(U.shq(EXEFILE) .. " --version")
  H.ok(out:find("(protocol 1) build " .. embed.build_id, 1, true), out)
end)

H.test("embed: embedded files are the lua/ sources with LF line ends", function()
  if not embedded() then return end
  for _, p in ipairs(server_files()) do
    local disk = U.read_file(DATADIR .. "/" .. p)
    H.ok(disk, "missing in lua/: " .. p)
    local chunk = assert(embed.load(p))
    H.eq(debug.getinfo(chunk, "S").source, "@embedded:" .. p)
  end
  local dir = U.tmpdir("extract")
  local out, code = U.sh(U.shq(EXEFILE) .. " --extract-data " .. U.shq(dir))
  H.eq(code, 0, out)
  for _, p in ipairs(server_files()) do
    local disk = U.read_file(DATADIR .. "/" .. p):gsub("\r\n", "\n")
    H.eq(U.read_file(dir .. "/" .. p), disk, "extracted " .. p)
  end
  local missing = select(2, embed.load("thither/nope.lua"))
  H.ok(missing:find("no embedded file", 1, true), missing)
end)

H.test("embed: a lone binary without a data directory serves the protocol", function()
  if not embedded() then return end
  local exe = lone_server()
  local c, reply = Client.connect({ server = exe, datadir = false })
  H.eq(reply.build_id, embed.build_id)
  H.eq(c:request("ping", { data = "x" }), "x")
  local st = c:request("stat", { path = "/" })
  H.eq(st.type, "dir")
  local info = c:request("info")
  H.eq(info.build_id, embed.build_id)
  H.eq(c:close(), 0)
end)

H.test("embed: a stale lua directory next to the binary is ignored", function()
  if not embedded() then return end
  local exe, dir = lone_server()
  U.sh("mkdir -p " .. U.shq(dir .. "/lua/thither"))
  U.write_file(dir .. "/lua/thither/init.lua", "error('stale lua directory was loaded')\n")
  local c = Client.connect({ server = exe, datadir = false })
  H.eq(c:request("ping"), true)
  H.eq(c:close(), 0)
end)

H.test("embed: --datadir overrides the embedded modules, missing ones fall back", function()
  if not embedded() then return end
  local exe = lone_server()
  -- a data directory with only a patched thither/init.lua: the other modules
  -- must come from the binary
  local dir = U.tmpdir("override")
  U.sh("mkdir -p " .. U.shq(dir .. "/thither"))
  local src = U.read_file(DATADIR .. "/thither/init.lua")
  local patched, n = src:gsub("build_id = server%.build_id,", "build_id = server.build_id, overridden = true,")
  H.eq(n, 1, "patch point")
  U.write_file(dir .. "/thither/init.lua", patched)
  local c, reply = Client.connect({ server = exe, datadir = dir })
  H.eq(reply.overridden, true)
  H.eq(reply.build_id, embed.build_id)
  H.eq(c:request("stat", { path = "/" }).type, "dir")
  H.eq(c:close(), 0)
  -- without --datadir the embedded init.lua is used again
  c, reply = Client.connect({ server = exe, datadir = false })
  H.eq(reply.overridden, nil)
  H.eq(c:close(), 0)
end)

H.test("embed: a --datadir without thither/init.lua is an error", function()
  if not embedded() then return end
  local exe = lone_server()
  local dir = U.tmpdir("empty")
  local out, code = U.sh(U.shq(exe) .. " --datadir " .. U.shq(dir) .. " --stdio < /dev/null")
  H.eq(code, 1)
  H.ok(out:find("no thither/init.lua", 1, true), out)
end)

H.test("embed: --run scripts can require embedded modules without a data directory", function()
  if not embedded() then return end
  local exe, dir = lone_server()
  local script = dir .. "/probe.lua"
  U.write_file(script, table.concat({
    "local mp = require 'thither.msgpack'",
    "local frame = require 'thither.frame'",
    "assert(mp.decode(mp.encode({ a = 1 })).a == 1)",
    "assert(frame.encode({ a = 1 }))",
    "print(debug.getinfo(mp.encode, 'S').source, tostring(DATADIR))",
    "return 0",
  }, "\n"))
  local out, code = U.sh(U.shq(exe) .. " --run " .. U.shq(script))
  H.eq(code, 0, out)
  H.ok(out:find("@embedded:thither/msgpack.lua\tnil", 1, true), out)
end)

H.test("cleanup: embed tests", function() U.cleanup() end)
