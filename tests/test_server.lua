-- Protocol-level loopback tests: handshake, framing limits, errors, root
-- jail, cancellation and server plugins.
local H = require "harness"
local U = require "util"
local Client = require "client"
local mp = require "thither.msgpack"
local frame = require "thither.frame"

local TEST_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR = system.absolute_path(TEST_DIR .. "/../plugins") or (TEST_DIR .. "/../plugins")

H.test("server: --version and --help", function()
  local out = U.sh(U.shq(EXEFILE) .. " --version")
  H.ok(out:match("^thither%-server .+ %(protocol 1%)"), out)
  H.ok(U.sh(U.shq(EXEFILE) .. " --help"):find("--stdio", 1, true))
  local _, code = U.sh(U.shq(EXEFILE) .. " --bogus")
  H.eq(code, 2)
end)

H.test("hello: handshake succeeds and reports server capabilities", function()
  local c, reply = Client.connect()
  H.eq(reply.ev, "hello")
  H.eq(reply.proto_version, 1)
  H.eq(type(reply.server_version), "string")
  H.eq(reply.max_frame, frame.MAX_FRAME)
  H.ok(reply.pid > 0)
  H.eq(reply.home, os.getenv("HOME"))
  local caps = {}
  for _, cap in ipairs(reply.caps) do caps[cap] = true end
  for _, want in ipairs({ "fs", "watch", "exec", "call", "large_file", "search" }) do
    H.ok(caps[want], "missing cap " .. want)
  end
  H.eq(c:request("ping", { data = "x" }), "x")
  H.eq(c:close(), 0)
end)

H.test("hello: protocol version mismatch is refused and the server exits", function()
  local c = Client.spawn()
  local reply = c:hello(999)
  H.eq(reply.ev, "hello")
  H.eq(reply.err.code, "version_mismatch")
  H.eq(reply.proto_version, 1)
  H.eq(c:wait_exit(5), 2)
end)

H.test("hello: a request before hello is refused", function()
  local c = Client.spawn()
  c:send({ id = 1, op = "ping", args = {} })
  local reply = c:recv(5)
  H.eq(reply.err.code, "bad_hello")
  H.eq(c:wait_exit(5), 2)
end)

H.test("hello: a second hello is an error but the session continues", function()
  local c = Client.connect()
  c:send({ ev = "hello", proto_version = 1 })
  local m = c:recv(5)
  H.eq(m.err.code, "bad_request")
  H.eq(c:request("ping"), true)
  c:close()
end)

H.test("server exits cleanly when stdin closes", function()
  local c = Client.connect()
  H.eq(c:close(), 0)
end)

H.test("frames: oversized frame is rejected and the connection is closed", function()
  local c = Client.connect()
  c:write_raw(string.pack("<I4", frame.MAX_FRAME + 1))
  local m = c:recv(5)
  H.eq(m.err.code, "frame_too_large")
  H.eq(c:wait_exit(5), 3)
end)

H.test("frames: a frame of exactly 16 MiB is accepted and echoed", function()
  local c = Client.connect()
  local data = string.rep("\0\1\2\3", 1024 * 1024 // 4 * 16)
  data = data:sub(1, frame.MAX_FRAME - 29)
  local payload = mp.encode({ id = 1, op = "ping", args = { data = mp.bin(data) } })
  H.eq(#payload, frame.MAX_FRAME, "payload size")
  c:write_raw(string.pack("<I4", #payload) .. payload)
  local id = 1
  local got = c:wait_response(id, 60)
  H.eq(#got, #data)
  H.ok(got == data, "echo differs")
  H.eq(c:close(), 0)
end)

H.test("frames: an oversized response becomes a too_large error", function()
  local c = Client.connect({ args = { "--plugins", PLUGIN_DIR } })
  local r, err = c:request("call", { service = "echo", method = "rep", args = { text = string.rep("x", 1024), n = 20000 } }, 60)
  H.eq(r, nil)
  H.eq(err.code, "too_large")
  H.eq(c:request("ping"), true)
  c:close()
end)

H.test("frames: a malformed payload yields bad_frame and the session continues", function()
  local c = Client.connect()
  c:write_raw(string.pack("<I4", 3) .. "\xc1\xc1\xc1")
  local m = c:recv(5)
  H.eq(m.err.code, "bad_frame")
  H.eq(c:request("ping", { data = 7 }), 7)
  c:close()
end)

H.test("requests: unknown op, bad args, duplicate id, notifications", function()
  local c = Client.connect()
  local r, err = c:request("no_such_op")
  H.eq(err.code, "unknown_op")
  c:send({ id = 50, op = "stat", args = "nope" })
  local m = c:recv(5)
  H.eq(m.id, 50); H.eq(m.err.code, "bad_request")
  c:send({ id = 51, op = 42 })
  m = c:recv(5)
  H.eq(m.err.code, "bad_request")
  r, err = c:request("stat", {})
  H.eq(err.code, "bad_request")
  r, err = c:request("stat", { path = "relative/path" })
  H.eq(err.code, "bad_path")
  -- a request without an id gets no response; the next one proves the order
  c:send({ op = "ping", args = {} })
  H.eq(c:request("ping", { data = "after" }), "after")
  -- a NaN id cannot be a table key: refused, the server keeps running
  c:send({ id = 0 / 0, op = "ping" })
  m = c:recv(5)
  H.ok(m and m.err and m.err.code == "bad_request", "NaN id not refused")
  H.eq(c:request("ping", { data = "alive" }), "alive")
  c:close()
end)

H.test("requests: info reports the environment", function()
  local c = Client.connect({ args = { "--plugins", PLUGIN_DIR } })
  local i = c:request("info")
  H.eq(i.proto_version, 1)
  H.ok(i.pid > 0)
  H.eq(i.services, { "echo" })
  H.eq(c:request("home"), os.getenv("HOME"))
  c:close()
end)

H.test("requests: many pipelined requests are all answered", function()
  local c = Client.connect()
  local ids = {}
  for i = 1, 500 do ids[i] = c:send_request("ping", { data = i }) end
  for i = 1, 500 do H.eq(c:wait_response(ids[i]), i) end
  c:close()
end)

H.test("root jail: paths outside --root are refused for file ops", function()
  local dir = U.tmpdir("jail")
  local root = dir .. "/root"
  U.sh("mkdir -p " .. root .. "/sub && mkdir -p " .. dir .. "/outside && echo secret > " .. dir .. "/outside/s.txt")
  U.sh("ln -s " .. dir .. "/outside " .. root .. "/escape")
  U.write_file(root .. "/sub/a.txt", "hello")
  local c, hello = Client.connect({ args = { "--root", root } })
  H.eq(hello.root, root)
  H.eq(c:request("stat", { path = root .. "/sub/a.txt" }).size, 5)
  local _, err = c:request("stat", { path = dir .. "/outside/s.txt" })
  H.eq(err.code, "jail")
  _, err = c:request("stat", { path = root .. "/../outside/s.txt" })
  H.eq(err.code, "jail", "lexical escape")
  _, err = c:request("read", { path = root .. "/escape/s.txt", offset = 0, len = 10 })
  H.eq(err.code, "jail", "symlink escape")
  _, err = c:request("write", { path = root .. "/escape/new.txt", data = "x" })
  H.eq(err.code, "jail", "write through symlink")
  H.ok(not U.exists(dir .. "/outside/new.txt"))
  _, err = c:request("rename", { from = root .. "/sub/a.txt", to = dir .. "/outside/a.txt" })
  H.eq(err.code, "jail")
  _, err = c:request("remove", { path = root, recursive = true })
  H.eq(err.code, "jail", "root itself")
  for _, r in ipairs({
    { "chmod", { path = dir .. "/outside/s.txt", mode = 438 } },
    { "utime", { path = root .. "/escape/s.txt" } },
    { "access", { path = dir .. "/outside/s.txt", mode = 4 } },
    { "symlink", { target = "x", path = dir .. "/outside/l" } },
    { "link", { from = dir .. "/outside/s.txt", to = root .. "/sub/h" } },
    { "copy", { from = dir .. "/outside/s.txt", to = root .. "/sub/c" } },
    { "copy", { from = root .. "/sub/a.txt", to = root .. "/escape/c" } },
  }) do
    local _, e = c:request(r[1], r[2])
    H.eq(e and e.code, "jail", r[1] .. " outside the root")
  end
  H.eq(U.ls(dir .. "/outside"), { "s.txt" })
  H.ok(c:request("symlink", { target = dir .. "/outside/s.txt", path = root .. "/sub/l" }),
    "a symlink's target is only text; following it later is jailed")
  _, err = c:request("read", { path = root .. "/sub/l", offset = 0, len = 10 })
  H.eq(err.code, "jail")
  H.ok(c:request("write", { path = root .. "/sub/b.txt", data = "ok", create_dirs = true }))
  H.eq(U.read_file(root .. "/sub/b.txt"), "ok")
  H.ok(c:request("write", { path = root .. "/deep/er/c.txt", data = "ok", create_dirs = true }))
  H.eq(c:request("realpath", { path = root .. "/sub/../sub/b.txt" }), root .. "/sub/b.txt")
  -- exec is not jailed (advisory jail)
  local r = c:request("exec", { argv = { "true" } })
  H.ok(r.stream)
  c:close()
end)

H.test("plugin: echo service, errors and unknown service", function()
  local c, hello = Client.connect({ args = { "--plugins", PLUGIN_DIR } })
  H.eq(hello.services, { "echo" })
  H.eq(c:request("call", { service = "echo", method = "echo", args = { a = 1, b = { 2, 3 } } }), { a = 1, b = { 2, 3 } })
  H.eq(c:request("call", { service = "echo", method = "upper", args = { text = "héllo" } }), "HéLLO")
  local _, err = c:request("call", { service = "echo", method = "upper", args = { text = 5 } })
  H.eq(err.code, "bad_request")
  _, err = c:request("call", { service = "nope", method = "x" })
  H.eq(err.code, "no_service")
  _, err = c:request("call", { service = "echo", method = "nope" })
  H.eq(err.code, "no_method")
  local st = c:request("call", { service = "echo", method = "stat", args = { path = PLUGIN_DIR .. "/echo.lua" } })
  H.eq(st.type, "file")
  H.ok(c:request("call", { service = "echo", method = "uptime" }) >= 0)
  c:close()
end)

H.test("plugin: streaming events and cancellation", function()
  local c = Client.connect({ args = { "--plugins", PLUGIN_DIR } })
  local id = c:send_request("call", { service = "echo", method = "count", args = { n = 5, delay_ms = 5 } })
  H.eq(c:wait_response(id, 10), 5)
  local evs = c:take_events(function(m) return m.ev == "call" and m.id == id end)
  H.eq(#evs, 5)
  for i, e in ipairs(evs) do H.eq(e.data.i, i) end

  local t0 = system.get_time()
  id = c:send_request("call", { service = "echo", method = "count", args = { n = 100000, delay_ms = 20 } })
  c:wait_event(function(m) return m.ev == "call" and m.id == id end, 5)
  c:send({ cancel = id })
  local _, err = c:wait_response(id, 5)
  H.eq(err.code, "cancelled")
  H.ok(system.get_time() - t0 < 4, "cancel took too long")
  H.eq(c:request("ping", { data = 1 }), 1)
  c:close()
end)

H.test("plugin: a broken plugin does not stop the server", function()
  local dir = U.tmpdir("plug")
  U.write_file(dir .. "/bad.lua", "error('boom')")
  U.write_file(dir .. "/syntax.lua", "this is not lua")
  U.write_file(dir .. "/good.lua", [[
    local server = require "thither"
    local seen = {}
    server.on_root(function(p) seen.root = p end)
    server.on_shutdown(function() local f = io.open(os.getenv("THITHER_SHUTDOWN_FILE"), "w") f:write("bye") f:close() end)
    server.register("good", {
      root = function() return seen.root end,
      boom = function() error("handler exploded") end,
      pair = function() return nil, "custom_code", "custom message" end,
    })
    server.notify("loaded", { ok = true })
  ]])
  local marker = dir .. "/shutdown"
  local c, hello = Client.connect({ args = { "--plugins", dir }, env = { THITHER_SHUTDOWN_FILE = marker } })
  H.eq(hello.services, { "good" })
  H.eq(c:request("call", { service = "good", method = "root" }), true)
  H.ok(c:request("set_root", { path = dir }))
  H.eq(c:request("call", { service = "good", method = "root" }), dir)
  local _, err = c:request("call", { service = "good", method = "boom" })
  H.eq(err.code, "internal")
  H.ok(err.msg:find("handler exploded", 1, true))
  _, err = c:request("call", { service = "good", method = "pair" })
  H.eq(err.code, "custom_code"); H.eq(err.msg, "custom message")
  c:close()
  H.eq(U.read_file(marker), "bye", "on_shutdown ran")
end)

H.test("plugin: server.notify reaches the client", function()
  local dir = U.tmpdir("plug2")
  U.write_file(dir .. "/n.lua", [[
    local server = require "thither"
    server.register("n", { go = function(args, req) server.notify("tick", { n = args.n }) return true end })
  ]])
  local c = Client.connect({ args = { "--plugins", dir } })
  c:request("call", { service = "n", method = "go", args = { n = 9 } })
  local ev = c:wait_event(function(m) return m.ev == "notify" end, 5)
  H.eq(ev.name, "tick"); H.eq(ev.data.n, 9)
  c:close()
end)

H.test("log file records requests", function()
  local dir = U.tmpdir("log")
  local c = Client.connect({ args = { "--log", dir .. "/server.log" } })
  c:request("stat", { path = "/" })
  c:close()
  local log = U.read_file(dir .. "/server.log")
  H.ok(log and log:find("stat", 1, true), "log is missing the request")
  H.ok(log:find("exiting", 1, true))
end)

H.test("cleanup: server tests", function() U.cleanup() end)
