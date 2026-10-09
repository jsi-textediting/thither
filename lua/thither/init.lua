-- thither-server main module: framing, handshake, request dispatch and the
-- event loop. Protocol reference: docs/protocol.md
--
-- Loaded by src/main.c with these globals: ARGS, SERVER_VERSION,
-- PROTO_VERSION, SERVER_OPTS (root, log, plugins), PLATFORM, ARCH, EXEFILE,
-- DATADIR (only when modules come from a data directory) and SERVER_BUILD
-- (only when they are compiled into the binary, see src/embed.c).
-- The returned value of this chunk is the process exit status.
local msgpack = require "thither.msgpack"
local frame = require "thither.frame"
local serverio = require "serverio"
local serverfs = require "serverfs"

local opts = SERVER_OPTS or {}

---@class server
local server = {
  version = SERVER_VERSION,
  build_id = SERVER_BUILD,
  proto_version = PROTO_VERSION,
  max_frame = frame.MAX_FRAME,
  opts = opts,
  ops = {},          -- op name -> function(args, req)
  services = {},     -- service name -> { method = function(args, req) }
  hooks = { on_start = {}, on_root = {}, on_shutdown = {}, on_connect = {}, on_disconnect = {} },
  tickers = {},      -- function() -> optional max wait in ms, run every loop turn
  cancel_hooks = {}, -- function(request_id)
  start_hooks = {},  -- function(request_id), before a request with an id starts
  caps = { "fs", "write_stream", "watch", "exec", "call", "large_file", "search", "blob",
           "fs_meta", "host_info" },
  is_daemon = opts.daemon == true,
  started_at = os.time(),
}
if opts.daemon then
  table.insert(server.caps, "session")
end
package.loaded["thither"] = server

local OUT_HIGH_WATER = 32 * 1024 * 1024
local FRAMES_PER_TURN = 256
local IDLE_WAIT_MS = 1000

---------------------------------------------------------------------------
-- logging
---------------------------------------------------------------------------

local logfh
if opts.log then
  logfh = io.open(opts.log, "ab")
  if not logfh then io.stderr:write("thither-server: cannot open log file ", opts.log, "\n")
  else serverfs.set_cloexec(logfh) end
end

function server.set_log_file(path)
  if logfh then logfh:close() end
  opts.log = path
  logfh = io.open(path, "ab")
  if logfh then serverfs.set_cloexec(logfh) end
end

function server.log(fmt, ...)
  if not logfh then return end
  local ok, msg = pcall(string.format, fmt, ...)
  logfh:write(os.date("%Y-%m-%d %H:%M:%S "), ok and msg or fmt, "\n")
  logfh:flush()
  if server.is_daemon and opts.log then
    local sz = logfh:seek("end")
    if sz and sz > 1048576 then
      logfh:close()
      os.remove(opts.log .. ".1")
      os.rename(opts.log, opts.log .. ".1")
      logfh = io.open(opts.log, "ab")
      if logfh then serverfs.set_cloexec(logfh) end
    end
  end
end

---------------------------------------------------------------------------
-- errors
---------------------------------------------------------------------------

--- Builds an error value understood by the dispatcher.
function server.err(code, msg, extra)
  local e = extra or {}
  e.code = code
  e.msg = msg or code
  return e
end

--- Raises a protocol error (code, msg) from inside a handler.
function server.raise(code, msg, extra)
  error(server.err(code, msg, extra), 0)
end

--- unwrap(serverfs.something(...)): returns the results or raises the error.
function server.unwrap(v, code, msg)
  if v == nil then
    if code == "conflict" then
      error(server.err("conflict", "etag mismatch", { etag = msg }), 0)
    end
    error(server.err(code or "EIO", msg or "I/O error"), 0)
  end
  return v, code, msg
end

---------------------------------------------------------------------------
-- connection objects & output queues
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- paths, root jail
---------------------------------------------------------------------------

server.home = serverfs.home() or "/"
server.userdir = os.getenv("THITHER_USERDIR")
  or ((os.getenv("XDG_CONFIG_HOME") or (server.home .. "/.config")) .. "/thither")
USERDIR = server.userdir

local function normalize(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  return "/" .. table.concat(parts, "/")
end
server.normalize = normalize

local function under(path, root)
  if root == "/" then return true end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

if opts.root then
  local rp = serverfs.realpath(opts.root)
  if not rp then
    io.stderr:write("thither-server: --root ", opts.root, ": no such directory\n")
    return 2
  end
  server.root = rp
end

--- Validates and normalizes a client supplied path. With --root the path must
--- stay inside the root, also after resolving symlinks of its existing part.
function server.path(p, conn)
  if type(p) ~= "string" or p == "" then server.raise("bad_request", "path must be a non-empty string") end
  if p:find("\0", 1, true) then server.raise("bad_request", "path contains NUL") end
  if p:sub(1, 1) ~= "/" then server.raise("bad_path", "path must be absolute: " .. p) end
  local root = (conn and conn.root) or (server.current_conn and server.current_conn.root) or server.root
  if not root then return p end
  local norm = normalize(p)
  if not under(norm, root) then server.raise("jail", "path is outside the server root") end
  local probe = norm
  while true do
    local rp = serverfs.realpath(probe)
    if rp then
      if not under(rp, root) then server.raise("jail", "path resolves outside the server root") end
      break
    end
    if probe == "/" then break end
    probe = probe:match("^(.*)/[^/]*$")
    if probe == "" then probe = "/" end
  end
  return norm
end

---------------------------------------------------------------------------
-- built-in ops & info
---------------------------------------------------------------------------

local function info(conn)
  local names = {}
  for name in pairs(server.services) do names[#names + 1] = name end
  table.sort(names)
  local root = (conn and conn.root) or (server.current_conn and server.current_conn.root) or server.root
  local res = {
    server_version = server.version,
    build_id = server.build_id,
    proto_version = server.proto_version,
    pid = system.get_process_id(),
    platform = PLATFORM,
    arch = ARCH,
    home = server.home,
    root = root,
    cwd = serverfs.realpath("."),
    services = names,
    caps = server.caps,
    max_frame = server.max_frame,
  }
  if server.is_daemon then
    res.session = {
      name = opts.session or "default",
      daemon_pid = system.get_process_id(),
      started = server.started_at,
      version = server.version,
      version_skew = (conn and conn.relay_version and conn.relay_version ~= server.version) and conn.relay_version or nil,
      plugins = opts.plugins or {},
      connections = #server.connections,
    }
  end
  return res
end

server.ops.ping = function(a) return a.data == nil and true or a.data end
server.ops.info = function(a, req) return info(req and req.conn) end
server.ops.home = function() return server.home end
server.ops.host_info = function()
  local ids = serverfs.ids()
  local path = {}
  for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do path[#path + 1] = dir end
  local res = {
    user = ids.user, uid = ids.uid, gid = ids.gid, gids = ids.gids,
    home = server.home, shell = os.getenv("SHELL"), path = path,
  }
  if server.is_daemon then
    res.session_name = opts.session or "default"
  end
  return res
end
server.ops.set_root = function(a, req)
  local c = req and req.conn or server.current_conn
  local p = server.path(a.path, c)
  if c then c.root = p end
  server.project_root = p
  if server.hooks.on_root then
    for _, fn in ipairs(server.hooks.on_root) do pcall(fn, p, c) end
  end
  return true
end
server.ops.session_info = function(a, req)
  if not server.is_daemon then
    server.raise("bad_request", "session_info is only available in daemon mode")
  end
  local c = req and req.conn or server.current_conn
  return {
    name = opts.session or "default",
    daemon_pid = system.get_process_id(),
    started = server.started_at,
    version = server.version,
    version_skew = (c and c.relay_version and c.relay_version ~= server.version) and c.relay_version or nil,
    plugins = opts.plugins or {},
    connections = #server.connections,
    procs = 0,
    rings_bytes = 0,
  }
end
server.ops.session_shutdown = function(a, req)
  if not server.is_daemon then
    server.raise("bad_request", "session_shutdown is only available in daemon mode")
  end
  server.shutdown_requested = true
  server.shutdown_timeout = a.timeout_ms or 2000
  return true
end
server.ops.call = function(a, req)
  local svc = server.services[a.service]
  if not svc then server.raise("no_service", "no such service: " .. tostring(a.service)) end
  local method = svc[a.method]
  if type(method) ~= "function" then
    server.raise("no_method", "no such method: " .. tostring(a.service) .. "." .. tostring(a.method))
  end
  return method(a.args, req)
end

---------------------------------------------------------------------------
-- plugin-facing API & hooks
---------------------------------------------------------------------------

local function run_hooks(name, ...)
  for _, fn in ipairs(server.hooks[name] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then server.log("hook %s failed: %s", name, tostring(err)) end
  end
end

--- Registers a service: server.register("name", { method = function(args, req) ... end })
function server.register(service, methods)
  assert(type(service) == "string" and type(methods) == "table", "server.register(service, methods)")
  server.services[service] = methods
end

function server.on_start(fn) table.insert(server.hooks.on_start, fn) end
function server.on_root(fn) table.insert(server.hooks.on_root, fn) end
function server.on_shutdown(fn) table.insert(server.hooks.on_shutdown, fn) end
function server.on_connect(fn) table.insert(server.hooks.on_connect, fn) end
function server.on_disconnect(fn) table.insert(server.hooks.on_disconnect, fn) end

---------------------------------------------------------------------------
-- connection objects & output queues
---------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

function Conn.new(id, copts)
  copts = copts or {}
  local c = setmetatable({
    id = id,
    fd = copts.fd,
    reader = frame.reader(server.max_frame),
    outq = {},
    out_head = 1,
    out_tail = 0,
    out_off = 0,
    out_bytes = 0,
    requests = {},
    greeted = false,
    peer_closed = false,
    closed = false,
    root = copts.root or server.root,
    log = copts.log or opts.log,
    env = copts.env or {},
    streams = {},
    watches = {},
    writers = {},
    held = nil,
    write_fn = copts.write or serverio.write,
    read_fn = copts.read or serverio.read,
    write_blocking_fn = copts.write_blocking or serverio.write_blocking,
    close_fn = copts.close,
  }, Conn)
  return c
end

function Conn:enqueue(data)
  self.out_tail = self.out_tail + 1
  self.outq[self.out_tail] = data
  self.out_bytes = self.out_bytes + #data
end

function Conn:send(msg)
  local ok, data = pcall(frame.encode, msg)
  if not ok then
    if msg.id then
      data = frame.encode({ id = msg.id, err = { code = "too_large", msg = "response exceeds the frame limit" } })
    else
      server.log("dropping oversized message: %s", tostring(data))
      return
    end
  end
  self:enqueue(data)
end

function Conn:flush()
  while self.out_head <= self.out_tail do
    local s = self.outq[self.out_head]
    local n = self.write_fn(s, self.out_off)
    if not n then self.peer_closed = true; return end
    self.out_off = self.out_off + n
    if self.out_off >= #s then
      self.outq[self.out_head] = nil
      self.out_head = self.out_head + 1
      self.out_bytes = self.out_bytes - #s
      self.out_off = 0
    else
      return
    end
  end
end

function Conn:send_final(msg)
  self:send(msg)
  while self.out_head <= self.out_tail do
    local s = self.outq[self.out_head]
    local rest = self.out_off > 0 and s:sub(self.out_off + 1) or s
    self.outq[self.out_head] = nil
    self.out_head = self.out_head + 1
    self.out_bytes = self.out_bytes - #s
    self.out_off = 0
    if not self.write_blocking_fn(rest, 1000) then break end
  end
end

function Conn:close()
  if self.closed then return end
  self.closed = true
  for _, req in pairs(self.requests) do
    req.cancelled = true
  end
  run_hooks("on_disconnect", self)
  if self.close_fn then
    pcall(self.close_fn)
    self.close_fn = nil
  end
end

server.Conn = Conn
server.connections = {}
server.current_conn = nil

local function update_agent_symlink()
  if not server.agent_link then return end
  local sock
  for i = #server.connections, 1, -1 do
    local c = server.connections[i]
    if not c.closed and c.env and c.env.SSH_AUTH_SOCK and c.env.SSH_AUTH_SOCK ~= "" then
      sock = c.env.SSH_AUTH_SOCK
      break
    end
  end
  os.remove(server.agent_link)
  if sock then
    serverfs.symlink(sock, server.agent_link, true)
  end
end
server.update_agent_symlink = update_agent_symlink

local function send(msg)
  local c = server.current_conn or server.connections[1]
  if c then c:send(msg) end
end
server.send = send

--- Pushes an event to the client: { ev = "notify", name = event, data = data }.
function server.notify(event, data, conn)
  local msg = { ev = "notify", name = event, data = data }
  if conn then
    if conn.greeted and not conn.closed then conn:send(msg) end
    return
  end
  if not server.greeted then
    -- nothing may precede the hello reply: hold events raised during startup
    server.held = server.held or {}
    table.insert(server.held, msg)
    return
  end
  for _, c in ipairs(server.connections) do
    if c.greeted and not c.closed then
      c:send(msg)
    end
  end
end

---------------------------------------------------------------------------
-- requests
---------------------------------------------------------------------------

local Req = {}
Req.__index = Req

--- Yields to the event loop for one turn; raises "cancelled" if the client
--- cancelled the request meanwhile.
function Req:yield()
  coroutine.yield()
  if self.cancelled then server.raise("cancelled", "request cancelled") end
end

function Req:check()
  if self.cancelled then server.raise("cancelled", "request cancelled") end
end

--- Sleeps (cooperatively) for `ms` milliseconds.
function Req:sleep(ms)
  self.wake_at = system.get_time() + ms / 1000
  self:yield()
  self.wake_at = nil
end

--- Sends an event tied to this request: { ev = "call", id = <request id>, data = ... }.
function Req:emit(data)
  local c = self.conn or server.current_conn
  if c then
    c:send({ ev = "call", id = self.id, data = data })
  else
    send({ ev = "call", id = self.id, data = data })
  end
end

local live = {}       -- list of suspended requests, resumed every turn
local nlive = 0

local function trace_handler(e)
  if type(e) == "table" then return e end
  return { code = "internal", msg = tostring(e), trace = debug.traceback("", 2) }
end

local function reply_ok(req, val)
  if req.id == nil then return end
  if req.conn then req.conn.requests[req.id] = nil end
  if val == nil then val = true end
  if req.conn then
    req.conn:send({ id = req.id, ok = val })
  else
    send({ id = req.id, ok = val })
  end
end

local function reply_err(req, err)
  if req.id ~= nil and req.conn then req.conn.requests[req.id] = nil end
  if type(err) ~= "table" then err = { code = "internal", msg = tostring(err) } end
  local e = {}
  for k, v in pairs(err) do if k ~= "trace" then e[k] = v end end
  if err.trace then server.log("error in op %s: %s\n%s", tostring(req.op), tostring(err.msg), err.trace) end
  if req.id ~= nil then
    if req.conn then
      req.conn:send({ id = req.id, err = e })
    else
      send({ id = req.id, err = e })
    end
  else
    server.log("notification %s failed: %s", tostring(req.op), tostring(e.msg))
  end
end

local function resume(req)
  local prev = server.current_conn
  server.current_conn = req.conn
  local ok, xok, a, b, c = coroutine.resume(req.co, req)
  server.current_conn = prev
  if coroutine.status(req.co) == "suspended" then
    nlive = nlive + 1
    live[nlive] = req
  elseif not ok then
    reply_err(req, xok)
  elseif not xok then
    reply_err(req, a)            -- error raised by the handler
  elseif a == nil and b ~= nil then
    reply_err(req, server.err(b, c))   -- handler returned nil, code, msg
  else
    reply_ok(req, a)
  end
end

local function start_request(conn, id, op, handler, args)
  if id ~= nil then
    -- the id now names this request (ids may be reused once answered)
    for _, fn in ipairs(server.start_hooks) do
      local ok, err = pcall(fn, id, conn)
      if not ok then server.log("start hook failed: %s", tostring(err)) end
    end
  end
  local req = setmetatable({ id = id, op = op, args = args, conn = conn }, Req)
  req.co = coroutine.create(function(r)
    return xpcall(handler, trace_handler, r.args, r)
  end)
  if id ~= nil and conn then conn.requests[id] = req end
  resume(req)
end

local function resume_live()
  if nlive == 0 then return end
  local list, n = live, nlive
  live, nlive = {}, 0
  local now = system.get_time()
  for i = 1, n do
    local req = list[i]
    if req.wake_at and not req.cancelled and req.wake_at > now then
      nlive = nlive + 1
      live[nlive] = req
    else
      resume(req)
    end
  end
end

local function live_wait_hint()
  if nlive == 0 then return nil end
  local hint = 0
  local now = system.get_time()
  local soonest
  for i = 1, nlive do
    local req = live[i]
    if not req.wake_at or req.cancelled then return 0 end
    local d = (req.wake_at - now) * 1000
    if not soonest or d < soonest then soonest = d end
  end
  hint = math.max(0, math.ceil(soonest or 0))
  return hint
end

local function handle_cancel(conn, id)
  if conn and conn.requests then
    local req = conn.requests[id]
    if req then req.cancelled = true end
  end
  for _, fn in ipairs(server.cancel_hooks) do
    local ok, err = pcall(fn, id, conn)
    if not ok then server.log("cancel hook failed: %s", tostring(err)) end
  end
end

local function handle_request(conn, msg)
  conn = conn or server.current_conn or server.connections[1]
  local id, op = msg.id, msg.op
  if id ~= id then
    -- NaN cannot be a table key (nor be echoed back meaningfully)
    if conn then conn:send({ err = { code = "bad_request", msg = "invalid request id" } }) end
    return
  end
  if type(op) ~= "string" then
    if id ~= nil and conn then conn:send({ id = id, err = { code = "bad_request", msg = "missing op" } }) end
    return
  end
  local handler = server.ops[op]
  if not handler then
    if id ~= nil and conn then conn:send({ id = id, err = { code = "unknown_op", msg = "unknown op: " .. op } }) end
    return
  end
  local args = msg.args
  if args == nil then args = {} end
  if type(args) ~= "table" then
    if id ~= nil and conn then conn:send({ id = id, err = { code = "bad_request", msg = "args must be a map" } }) end
    return
  end
  if id ~= nil and conn and conn.requests and conn.requests[id] then
    conn:send({ id = id, err = { code = "bad_request", msg = "duplicate request id" } })
    return
  end
  server.log("req %s %s", tostring(id), op)
  start_request(conn, id, op, handler, args)
end

function Conn:handle_frame(msg)
  if type(msg) ~= "table" then
    self:send({ err = { code = "bad_frame", msg = "frame is not a map" } })
    return true
  end
  if not self.greeted then
    if msg.ev == "relay" then
      self.relay_info = msg
      self.relay_version = msg.relay_version
      self.env = msg.env or {}
      if msg.opts and msg.opts.root then
        self.root = server.path(msg.opts.root, self)
      end
      if server.update_agent_symlink then server.update_agent_symlink() end
      self:send({
        ev = "relay_ok",
        daemon_version = server.version,
        daemon_pid = system.get_process_id(),
        session = opts.session or "default",
      })
      return true
    end
    if msg.ev ~= "hello" then
      self:send_final({ ev = "hello", proto_version = server.proto_version, server_version = server.version,
                        err = { code = "bad_hello", msg = "the first frame must be a hello" } })
      return false
    end
    if msg.proto_version ~= server.proto_version then
      self:send_final({ ev = "hello", proto_version = server.proto_version, server_version = server.version,
                        err = { code = "version_mismatch", msg = string.format("server speaks protocol %d, client sent %s",
                          server.proto_version, tostring(msg.proto_version)) } })
      return false
    end
    self.greeted = true
    server.greeted = true
    local reply = info(self)
    reply.ev = "hello"
    reply.root = self.root or server.root
    self:send(reply)
    for _, held in ipairs(server.held or {}) do self:send(held) end
    server.held = nil
    server.log("client hello: %s", tostring(msg.client_version))
    return true
  end

  if msg.cancel ~= nil then
    handle_cancel(self, msg.cancel)
  elseif msg.ev == "hello" then
    self:send({ err = { code = "bad_request", msg = "duplicate hello" } })
  else
    handle_request(self, msg)
  end
  return true
end

function Conn:process_frames(max_frames)
  max_frames = max_frames or FRAMES_PER_TURN
  local more = false
  for n = 1, max_frames do
    if n == max_frames then more = true end
    local msg, code, detail = self.reader:next()
    if msg == nil then
      more = false
      if code == "frame_too_large" then
        self:send_final({ err = { code = "frame_too_large", msg = "frame of " .. tostring(detail) ..
                     " bytes exceeds the " .. server.max_frame .. " byte limit" } })
        self:close()
        return false, 3, "oversized frame"
      elseif code == "bad_frame" then
        self:send({ err = { code = "bad_frame", msg = tostring(detail) } })
      else
        break
      end
    else
      local ok = self:handle_frame(msg)
      if not ok then
        self:close()
        return false, 2, "handshake failed"
      end
    end
  end
  return true, more
end

require("thither.ops_fs")(server)
require("thither.ops_large")(server)
require("thither.ops_exec")(server)
require("thither.ops_watch")(server)
require("thither.plugins")(server)

---------------------------------------------------------------------------
-- main loop
---------------------------------------------------------------------------

local function bye(status, reason)
  server.log("exiting: %s", reason)
  for _, c in ipairs(server.connections) do
    c:close()
  end
  run_hooks("on_shutdown")
  return status
end

local function main_stdio()
  server.log("thither-server %s pid %d started (root=%s)", server.version, system.get_process_id(), tostring(server.root))
  run_hooks("on_start", { root = server.root, home = server.home, userdir = server.userdir,
                          version = server.version, proto_version = server.proto_version })

  local stdio_conn = Conn.new(1, { root = server.root })
  server.connections = { stdio_conn }
  server.current_conn = stdio_conn
  run_hooks("on_connect", stdio_conn)

  local tick_hint = IDLE_WAIT_MS
  local more_frames = false

  while true do
    stdio_conn:flush()
    if stdio_conn.peer_closed then return bye(0, "peer closed the output pipe") end
    local timeout = tick_hint
    local live_hint = live_wait_hint()
    if live_hint and live_hint < timeout then timeout = live_hint end
    if more_frames then timeout = 0 end
    local want_write = stdio_conn.out_head <= stdio_conn.out_tail
    local readable = serverio.wait(timeout, want_write, stdio_conn.out_bytes < OUT_HIGH_WATER)
    local sig = serverio.signalled()
    if sig then return bye(0, "terminated by signal " .. sig) end
    if readable then
      local data, err = stdio_conn.read_fn(262144)
      if data == nil then return bye(0, "stdin closed (" .. tostring(err) .. ")") end
      stdio_conn.reader:feed(data)
    end

    local ok, more_or_code, reason = stdio_conn:process_frames()
    if not ok then
      return bye(more_or_code, reason)
    end
    more_frames = more_or_code

    resume_live()

    tick_hint = IDLE_WAIT_MS
    for _, ticker in ipairs(server.tickers) do
      local tok, hint = pcall(ticker)
      if not tok then server.log("ticker failed: %s", tostring(hint))
      elseif hint and hint < tick_hint then tick_hint = hint end
    end
    serverio.flush_events()
  end
end

local function main_daemon()
  server.is_daemon = true
  local session = require "thither.session"
  local sname, serr = session.validate_name(opts.session)
  if not sname then
    server.log("invalid session name: %s", tostring(serr))
    return 1
  end

  local rundir, rerr = session.runtime_dir()
  if not rundir then
    server.log("runtime dir error: %s", tostring(rerr))
    return 1
  end

  local sock_path, sperr = session.socket_path(rundir, sname)
  if not sock_path then
    server.log("socket path error: %s", tostring(sperr))
    return 1
  end
  local lock_path = session.lock_path(rundir, sname)

  local statedir, sterr = session.state_dir(sname)
  if not statedir then
    server.log("state dir error: %s", tostring(sterr))
    return 1
  end

  server.agent_link = session.agent_link(statedir)
  server.statedir = statedir

  if not logfh and not opts.log then
    server.set_log_file(session.daemon_log(statedir))
  end

  -- Lock must be acquired by the daemon
  local lock_fd, lerr = serverio.lock(lock_path)
  local ldeadline = system.get_time() + 3
  while not lock_fd and system.get_time() < ldeadline do
    system.sleep(0.01)
    lock_fd = serverio.lock(lock_path)
  end
  if not lock_fd then
    server.log("failed to acquire lock on %s: %s", lock_path, tostring(lerr))
    return 1
  end

  os.remove(sock_path)
  local listen_fd, lkerr = serverio.listen(sock_path)
  if not listen_fd then
    serverio.unlock(lock_fd)
    server.log("failed to listen on %s: %s", sock_path, tostring(lkerr))
    return 1
  end

  server.log("thither-server daemon %s pid %d started (session=%s, sock=%s)",
             server.version, system.get_process_id(), sname, sock_path)
  run_hooks("on_start", { root = server.root, home = server.home, userdir = server.userdir,
                          version = server.version, proto_version = server.proto_version,
                          session = sname })

  server.connections = {}
  local next_conn_id = 1
  local idle_since = system.get_time() + 5
  local idle_exit_sec = opts.idle_exit or 600
  local tick_hint = IDLE_WAIT_MS
  local more_frames = false

  while true do
    local sig = serverio.signalled()
    if sig then
      server.log("daemon received signal %d", sig)
      break
    end
    if server.shutdown_requested then
      server.log("daemon shutdown requested")
      break
    end

    local poll_map = { [listen_fd] = "r" }
    local ev_fd = serverio.events_fd and serverio.events_fd()
    if ev_fd and ev_fd >= 0 then poll_map[ev_fd] = "r" end

    for _, c in ipairs(server.connections) do
      if not c.closed and c.fd then
        local ev = ""
        if c.out_bytes < OUT_HIGH_WATER then ev = ev .. "r" end
        if c.out_head <= c.out_tail then ev = ev .. "w" end
        if ev ~= "" then poll_map[c.fd] = ev end
      end
    end

    local timeout = tick_hint
    local live_hint = live_wait_hint()
    if live_hint and live_hint < timeout then timeout = live_hint end
    if more_frames then timeout = 0 end

    if idle_exit_sec > 0 then
      local live_count = #server.connections + (server.procs_count or 0)
      if live_count == 0 then
        if not idle_since then idle_since = system.get_time() end
        local elapsed = system.get_time() - idle_since
        local rem = (idle_exit_sec - elapsed) * 1000
        if rem <= 0 then
          server.log("idle timeout reached (%ds), exiting daemon", idle_exit_sec)
          break
        elseif rem < timeout then
          timeout = rem
        end
      else
        idle_since = nil
      end
    end
    if timeout < 0 then timeout = 0 end

    local rev = serverio.poll(poll_map, timeout)
    sig = serverio.signalled()
    if sig then
      server.log("daemon received signal %d", sig)
      break
    end

    if rev and rev[listen_fd] and rev[listen_fd]:find("r") then
      while true do
        local cfd, uid = serverio.accept(listen_fd)
        if not cfd then break end
        local conn = Conn.new(next_conn_id, {
          fd = cfd,
          root = server.root,
          read = function(max) return serverio.read(max, cfd) end,
          write = function(chunk, off) return serverio.write(chunk, off, cfd) end,
          write_blocking = function(chunk, to) return serverio.write_blocking(chunk, to, cfd) end,
          close = function() serverio.close(cfd) end,
        })
        next_conn_id = next_conn_id + 1
        table.insert(server.connections, conn)
        server.log("accepted connection %d (fd %d, uid %s)", conn.id, cfd, tostring(uid))
        run_hooks("on_connect", conn)
      end
    end

    more_frames = false
    local dead = {}
    for i, c in ipairs(server.connections) do
      server.current_conn = c
      if rev and rev[c.fd] and rev[c.fd]:find("w") then
        c:flush()
      end
      if c.peer_closed then
        c:close()
        table.insert(dead, i)
      else
        if rev and rev[c.fd] and (rev[c.fd]:find("r") or rev[c.fd]:find("hup")) then
          local data, err = c.read_fn(262144)
          if data and #data > 0 then
            c.reader:feed(data)
          elseif data == nil then
            c:close()
            table.insert(dead, i)
          end
        end

        if not c.closed then
          local ok, more_or_code, reason = c:process_frames()
          if not ok then
            c:close()
            table.insert(dead, i)
          elseif more_or_code then
            more_frames = true
          end
        end
      end
    end

    if #dead > 0 then
      for j = #dead, 1, -1 do
        local idx = dead[j]
        local c = server.connections[idx]
        server.log("connection %d closed", c.id)
        table.remove(server.connections, idx)
      end
      update_agent_symlink()
    end

    resume_live()

    for _, c in ipairs(server.connections) do
      if not c.closed and c.out_head <= c.out_tail then
        c:flush()
      end
    end

    tick_hint = IDLE_WAIT_MS
    for _, ticker in ipairs(server.tickers) do
      local tok, hint = pcall(ticker)
      if not tok then server.log("ticker failed: %s", tostring(hint))
      elseif hint and hint < tick_hint then tick_hint = hint end
    end
    serverio.flush_events()
  end

  server.log("daemon shutting down...")
  for _, c in ipairs(server.connections) do
    if not c.closed then
      c:send({ ev = "session_closing" })
      c:flush()
      c:close()
    end
  end
  serverio.close(listen_fd)
  os.remove(sock_path)
  if server.agent_link then os.remove(server.agent_link) end
  serverio.unlock(lock_fd)
  run_hooks("on_shutdown")
  return 0
end

local function main()
  if opts.daemon then
    return main_daemon()
  else
    return main_stdio()
  end
end

if not (arg and arg[0]) then
  local status = main()
  if server.connections[1] then
    server.connections[1]:flush()
  end
  return status
else
  server.main = main
  return server
end
