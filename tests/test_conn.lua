-- Tests for multi-connection core: 2 Conn objects in one server runtime
local H = require "harness"
local U = require "util"
local mp = require "thither.msgpack"
local frame = require "thither.frame"

local function create_mock_conn(id, opts)
  local server = require "thither"
  local in_chunks = {}
  local out_chunks = {}

  local copts = {
    root = opts and opts.root,
    read = function(n)
      if #in_chunks == 0 then return "" end
      local c = table.remove(in_chunks, 1)
      return c
    end,
    write = function(s, off)
      local chunk = s:sub(off + 1)
      out_chunks[#out_chunks + 1] = chunk
      return #chunk
    end,
    write_blocking = function(s, timeout)
      out_chunks[#out_chunks + 1] = s
      return true
    end,
  }

  local conn = server.Conn.new(id, copts)
  table.insert(server.connections, conn)

  local mock = {
    conn = conn,
    in_chunks = in_chunks,
    out_chunks = out_chunks,
    decoder = frame.reader(),
  }

  function mock:feed(msg)
    local encoded = frame.encode(msg)
    self.conn.reader:feed(encoded)
  end

  function mock:step()
    return self.conn:process_frames()
  end

  function mock:flush()
    self.conn:flush()
  end

  function mock:recv()
    self:flush()
    local combined = table.concat(out_chunks)
    for i = 1, #out_chunks do out_chunks[i] = nil end
    if #combined > 0 then
      self.decoder:feed(combined)
    end
    local msg, code, detail = self.decoder:next()
    if code then error("recv decode error: " .. code .. " " .. tostring(detail)) end
    return msg
  end

  function mock:close()
    self.conn:close()
  end

  return mock
end

H.test("conn: 2 concurrent connections in one server process", function()
  local server = require "thither"

  local c1 = create_mock_conn(101)
  local c2 = create_mock_conn(102)

  -- Hello on both
  c1:feed({ ev = "hello", proto_version = server.proto_version, client_version = "mock-1" })
  c2:feed({ ev = "hello", proto_version = server.proto_version, client_version = "mock-2" })

  c1:step()
  c2:step()

  local r1 = c1:recv()
  local r2 = c2:recv()

  H.ok(r1 and r1.ev == "hello", "c1 hello")
  H.ok(r2 and r2.ev == "hello", "c2 hello")

  -- Interleaved ping requests
  c1:feed({ id = 1, op = "ping", args = { data = "from_c1" } })
  c2:feed({ id = 1, op = "ping", args = { data = "from_c2" } })

  c1:step()
  c2:step()

  local resp1 = c1:recv()
  local resp2 = c2:recv()

  H.eq(resp1.id, 1)
  H.eq(resp1.ok, "from_c1")
  H.eq(resp2.id, 1)
  H.eq(resp2.ok, "from_c2")

  c1:close()
  c2:close()
end)

H.test("conn: independent root jails per connection", function()
  local server = require "thither"
  local tmp1 = U.tmpdir()
  local tmp2 = U.tmpdir()

  U.write_file(tmp1 .. "/file1.txt", "content1")
  U.write_file(tmp2 .. "/file2.txt", "content2")

  local c1 = create_mock_conn(201, { root = tmp1 })
  local c2 = create_mock_conn(202, { root = tmp2 })

  c1:feed({ ev = "hello", proto_version = server.proto_version })
  c2:feed({ ev = "hello", proto_version = server.proto_version })
  c1:step(); c2:step()
  c1:recv(); c2:recv()

  -- c1 reading inside tmp1 should succeed
  c1:feed({ id = 1, op = "stat", args = { path = tmp1 .. "/file1.txt" } })
  c1:step()
  local res1 = c1:recv()
  H.ok(res1.ok and res1.ok.type == "file")

  -- c1 reading inside tmp2 should fail with jail error
  c1:feed({ id = 2, op = "stat", args = { path = tmp2 .. "/file2.txt" } })
  c1:step()
  local res2 = c1:recv()
  H.eq(res2.err.code, "jail")

  -- c2 reading inside tmp2 should succeed
  c2:feed({ id = 1, op = "stat", args = { path = tmp2 .. "/file2.txt" } })
  c2:step()
  local res3 = c2:recv()
  H.ok(res3.ok and res3.ok.type == "file")

  -- c2 reading inside tmp1 should fail with jail error
  c2:feed({ id = 2, op = "stat", args = { path = tmp1 .. "/file1.txt" } })
  c2:step()
  local res4 = c2:recv()
  H.eq(res4.err.code, "jail")

  c1:close()
  c2:close()
  U.cleanup()
end)

H.test("conn: isolated disconnect cleanup", function()
  local server = require "thither"
  local tmp = U.tmpdir()

  local c1 = create_mock_conn(301)
  local c2 = create_mock_conn(302)

  c1:feed({ ev = "hello", proto_version = server.proto_version })
  c2:feed({ ev = "hello", proto_version = server.proto_version })
  c1:step(); c2:step()
  c1:recv(); c2:recv()

  -- c1 starts an exec stream
  c1:feed({ id = 10, op = "exec", args = { argv = { "sleep", "10" } } })
  c1:step()
  local r1 = c1:recv()
  H.ok(r1.ok and r1.ok.stream, "c1 stream started")
  local sid1 = r1.ok.stream

  -- c2 starts an exec stream
  c2:feed({ id = 20, op = "exec", args = { argv = { "sleep", "10" } } })
  c2:step()
  local r2 = c2:recv()
  H.ok(r2.ok and r2.ok.stream, "c2 stream started")
  local sid2 = r2.ok.stream

  -- Check stream ownership
  H.ok(c1.conn.streams[sid1] ~= nil)
  H.ok(c2.conn.streams[sid2] ~= nil)

  -- c1 disconnects
  c1:close()

  -- c1 stream is killed and cleaned up
  H.ok(c1.conn.streams[sid1] == nil)

  -- c2 stream is still alive!
  H.ok(c2.conn.streams[sid2] ~= nil)

  -- c2 can kill its stream normally
  c2:feed({ id = 21, op = "kill", args = { stream = sid2, signal = "kill" } })
  c2:step()
  local r3 = c2:recv()
  H.ok(r3.ok, "c2 kill succeeded")

  c2:close()
  U.cleanup()
end)
