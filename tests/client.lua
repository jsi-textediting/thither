-- Loopback protocol client used by the tests: spawns `thither-server --stdio`
-- and speaks the framed msgpack protocol over its pipes.
-- Runs inside `thither-server --run` (needs the process and system libs).
local msgpack = require "thither.msgpack"
local frame = require "thither.frame"

local Client = {}
Client.__index = Client

local function now() return system.get_time() end

--- opts: args (extra server arguments), datadir (false: none, use the
--- embedded modules), server (executable)
function Client.spawn(opts)
  opts = opts or {}
  local cmd = { opts.server or EXEFILE, "--stdio" }
  if opts.datadir ~= false then
    cmd[#cmd + 1] = "--datadir"
    cmd[#cmd + 1] = opts.datadir or DATADIR
  end
  for _, a in ipairs(opts.args or {}) do cmd[#cmd + 1] = a end
  local env
  if opts.env then
    local parts = {}
    for k, v in pairs(opts.env) do parts[#parts + 1] = k .. "=" .. v .. "\0" end
    local blob = table.concat(parts)
    env = function() return blob end
  end
  local proc = assert(process.start(cmd, { env = env }))
  return setmetatable({
    proc = proc, reader = frame.reader(), inbox = {}, events = {}, next_id = 1,
    stderr = "", sent_bytes = 0,
  }, Client)
end

--- Reads whatever the server has produced so far (never blocks).
function Client:pump()
  local got = false
  while true do
    local data = self.proc:read_stdout(262144)
    if not data or data == "" then break end
    self.reader:feed(data)
    got = true
  end
  local err = self.proc:read_stderr(65536)
  if err and err ~= "" then self.stderr = self.stderr .. err end
  while true do
    local v, code, detail = self.reader:next()
    if v == nil then
      if code then error("client: bad frame from server: " .. code .. " " .. tostring(detail)) end
      break
    end
    self.inbox[#self.inbox + 1] = v
    got = true
  end
  return got
end

--- Sends a raw string, interleaving reads so a full pipe can never deadlock.
function Client:write_raw(data)
  local off = 0
  while off < #data do
    local piece = off == 0 and data or data:sub(off + 1)
    local n = self.proc:write(piece)
    if n == 0 then
      if not self.proc:running() then error("client: server exited while writing") end
      if not self:pump() then system.sleep(0.0005) end
    else
      off = off + n
    end
  end
  self.sent_bytes = self.sent_bytes + #data
end

function Client:send(msg)
  self:write_raw(frame.encode(msg))
end

--- Next message from the server or nil after `timeout` seconds / on exit.
function Client:recv(timeout)
  local deadline = now() + (timeout or 10)
  while true do
    if #self.inbox > 0 then return table.remove(self.inbox, 1) end
    if not self:pump() then
      if #self.inbox > 0 then goto continue end
      if not self.proc:running() then
        self:pump()
        if #self.inbox > 0 then goto continue end
        return nil, "exited"
      end
      if now() >= deadline then return nil, "timeout" end
      system.sleep(0.001)
    end
    ::continue::
  end
end

function Client:hello(proto_version)
  self:send({ ev = "hello", proto_version = proto_version or 1, client_version = "tests", caps = {} })
  return self:recv(10)
end

--- Sends a request and returns (ok_value) or (nil, err_table). Events that
--- arrive meanwhile are kept in self.events.
function Client:request(op, args, timeout)
  local id = self:send_request(op, args)
  return self:wait_response(id, timeout)
end

function Client:send_request(op, args)
  local id = self.next_id
  self.next_id = id + 1
  self:send({ id = id, op = op, args = args or {} })
  return id
end

function Client:wait_response(id, timeout)
  local deadline = now() + (timeout or 30)
  while true do
    for i, m in ipairs(self.events) do
      if m.id == id and (m.ok ~= nil or m.err ~= nil) then
        table.remove(self.events, i)
        if m.err then return nil, m.err end
        return m.ok
      end
    end
    local m, why = self:recv(math.max(0.01, deadline - now()))
    if not m then error("client: no response to request " .. id .. " (" .. tostring(why) .. ")\nserver stderr: " .. self.stderr) end
    self.events[#self.events + 1] = m
    if now() > deadline then error("client: timeout waiting for request " .. id) end
  end
end

--- Waits for an event matching pred(msg); returns it (removing it from the queue).
function Client:wait_event(pred, timeout)
  local deadline = now() + (timeout or 10)
  while true do
    for i, m in ipairs(self.events) do
      if pred(m) then table.remove(self.events, i) return m end
    end
    local m = self:recv(math.max(0.01, deadline - now()))
    if not m then return nil end
    self.events[#self.events + 1] = m
    if now() > deadline then return nil end
  end
end

--- Removes and returns all queued events matching pred (or all events).
function Client:take_events(pred)
  local out, keep = {}, {}
  for _, m in ipairs(self.events) do
    if not pred or pred(m) then out[#out + 1] = m else keep[#keep + 1] = m end
  end
  self.events = keep
  return out
end

--- Closes the server's stdin and waits for it to exit; returns its exit code.
function Client:close(timeout)
  self.proc:close_stream(process.STREAM_STDIN)
  local deadline = now() + (timeout or 10)
  while self.proc:running() and now() < deadline do
    self:pump()
    system.sleep(0.002)
  end
  if self.proc:running() then
    self.proc:kill()
    return nil, "server did not exit"
  end
  self:pump()
  return self.proc:returncode()
end

--- Waits for the server process to exit by itself.
function Client:wait_exit(timeout)
  local deadline = now() + (timeout or 10)
  while self.proc:running() and now() < deadline do
    self:pump()
    system.sleep(0.002)
  end
  if self.proc:running() then return nil end
  self:pump()
  return self.proc:returncode()
end

--- Spawns a server, completes the handshake and returns the client and hello reply.
function Client.connect(opts)
  local c = Client.spawn(opts)
  local reply, why = c:hello()
  assert(reply and reply.ev == "hello" and not reply.err, "handshake failed: " ..
    tostring(reply and reply.err and reply.err.msg or why) .. "\nserver stderr: " .. c.stderr)
  return c, reply
end

return Client
