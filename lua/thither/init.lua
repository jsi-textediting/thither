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
  hooks = { on_start = {}, on_root = {}, on_shutdown = {} },
  tickers = {},      -- function() -> optional max wait in ms, run every loop turn
  cancel_hooks = {}, -- function(request_id)
  start_hooks = {},  -- function(request_id), before a request with an id starts
  caps = { "fs", "write_stream", "watch", "exec", "call", "large_file", "search", "blob",
           "fs_meta", "host_info" },
}
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

function server.log(fmt, ...)
  if not logfh then return end
  local ok, msg = pcall(string.format, fmt, ...)
  logfh:write(os.date("%Y-%m-%d %H:%M:%S "), ok and msg or fmt, "\n")
  logfh:flush()
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
-- output queue
---------------------------------------------------------------------------

local outq, out_head, out_tail, out_off, out_bytes = {}, 1, 0, 0, 0
local peer_closed = false

local function enqueue(data)
  out_tail = out_tail + 1
  outq[out_tail] = data
  out_bytes = out_bytes + #data
end

--- Queues a message (a table) as one frame.
local function send(msg)
  local ok, data = pcall(frame.encode, msg)
  if not ok then
    -- too big for one frame: tell the client instead of dropping the request
    if msg.id then
      data = frame.encode({ id = msg.id, err = { code = "too_large", msg = "response exceeds the frame limit" } })
    else
      server.log("dropping oversized message: %s", tostring(data))
      return
    end
  end
  enqueue(data)
end
server.send = send

local function flush()
  while out_head <= out_tail do
    local s = outq[out_head]
    local n = serverio.write(s, out_off)
    if not n then peer_closed = true; return end
    out_off = out_off + n
    if out_off >= #s then
      outq[out_head] = nil
      out_head = out_head + 1
      out_bytes = out_bytes - #s
      out_off = 0
    else
      return
    end
  end
end

--- Sends a message right now, blocking briefly (used before exiting).
local function send_final(msg)
  send(msg)
  while out_head <= out_tail do
    local s = outq[out_head]
    local rest = out_off > 0 and s:sub(out_off + 1) or s
    outq[out_head] = nil
    out_head = out_head + 1
    out_bytes = out_bytes - #s
    out_off = 0
    if not serverio.write_blocking(rest, 1000) then break end
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
  send({ ev = "call", id = self.id, data = data })
end

local requests = {}   -- id -> req
local live = {}       -- list of suspended requests, resumed every turn
local nlive = 0

local function trace_handler(e)
  if type(e) == "table" then return e end
  return { code = "internal", msg = tostring(e), trace = debug.traceback("", 2) }
end

local function reply_ok(req, val)
  if req.id == nil then return end
  requests[req.id] = nil
  if val == nil then val = true end
  send({ id = req.id, ok = val })
end

local function reply_err(req, err)
  if req.id ~= nil then requests[req.id] = nil end
  if type(err) ~= "table" then err = { code = "internal", msg = tostring(err) } end
  local e = {}
  for k, v in pairs(err) do if k ~= "trace" then e[k] = v end end
  if err.trace then server.log("error in op %s: %s\n%s", tostring(req.op), tostring(err.msg), err.trace) end
  if req.id ~= nil then
    send({ id = req.id, err = e })
  else
    server.log("notification %s failed: %s", tostring(req.op), tostring(e.msg))
  end
end

local function resume(req)
  local ok, xok, a, b, c = coroutine.resume(req.co, req)
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

local function start_request(id, op, handler, args)
  if id ~= nil then
    -- the id now names this request (ids may be reused once answered)
    for _, fn in ipairs(server.start_hooks) do
      local ok, err = pcall(fn, id)
      if not ok then server.log("start hook failed: %s", tostring(err)) end
    end
  end
  local req = setmetatable({ id = id, op = op, args = args }, Req)
  req.co = coroutine.create(function(r)
    return xpcall(handler, trace_handler, r.args, r)
  end)
  if id ~= nil then requests[id] = req end
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

local function handle_cancel(id)
  local req = requests[id]
  if req then req.cancelled = true end
  for _, fn in ipairs(server.cancel_hooks) do
    local ok, err = pcall(fn, id)
    if not ok then server.log("cancel hook failed: %s", tostring(err)) end
  end
end

local function handle_request(msg)
  local id, op = msg.id, msg.op
  if id ~= id then
    -- NaN cannot be a table key (nor be echoed back meaningfully)
    send({ err = { code = "bad_request", msg = "invalid request id" } })
    return
  end
  if type(op) ~= "string" then
    if id ~= nil then send({ id = id, err = { code = "bad_request", msg = "missing op" } }) end
    return
  end
  local handler = server.ops[op]
  if not handler then
    if id ~= nil then send({ id = id, err = { code = "unknown_op", msg = "unknown op: " .. op } }) end
    return
  end
  local args = msg.args
  if args == nil then args = {} end
  if type(args) ~= "table" then
    if id ~= nil then send({ id = id, err = { code = "bad_request", msg = "args must be a map" } }) end
    return
  end
  if id ~= nil and requests[id] then
    send({ id = id, err = { code = "bad_request", msg = "duplicate request id" } })
    return
  end
  server.log("req %s %s", tostring(id), op)
  start_request(id, op, handler, args)
end

---------------------------------------------------------------------------
-- plugin-facing API (see docs/protocol.md, "Server plugins")
---------------------------------------------------------------------------

--- Registers a service: server.register("name", { method = function(args, req) ... end })
function server.register(service, methods)
  assert(type(service) == "string" and type(methods) == "table", "server.register(service, methods)")
  server.services[service] = methods
end

function server.on_start(fn) table.insert(server.hooks.on_start, fn) end
function server.on_root(fn) table.insert(server.hooks.on_root, fn) end
function server.on_shutdown(fn) table.insert(server.hooks.on_shutdown, fn) end

--- Pushes an event to the client: { ev = "notify", name = event, data = data }.
function server.notify(event, data)
  local msg = { ev = "notify", name = event, data = data }
  if not server.greeted then
    -- nothing may precede the hello reply: hold events raised during startup
    server.held = server.held or {}
    table.insert(server.held, msg)
    return
  end
  send(msg)
end

local function run_hooks(name, ...)
  for _, fn in ipairs(server.hooks[name]) do
    local ok, err = pcall(fn, ...)
    if not ok then server.log("hook %s failed: %s", name, tostring(err)) end
  end
end

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
function server.path(p)
  if type(p) ~= "string" or p == "" then server.raise("bad_request", "path must be a non-empty string") end
  if p:find("\0", 1, true) then server.raise("bad_request", "path contains NUL") end
  if p:sub(1, 1) ~= "/" then server.raise("bad_path", "path must be absolute: " .. p) end
  if not server.root then return p end
  local norm = normalize(p)
  if not under(norm, server.root) then server.raise("jail", "path is outside the server root") end
  local probe = norm
  while true do
    local rp = serverfs.realpath(probe)
    if rp then
      if not under(rp, server.root) then server.raise("jail", "path resolves outside the server root") end
      break
    end
    if probe == "/" then break end
    probe = probe:match("^(.*)/[^/]*$")
    if probe == "" then probe = "/" end
  end
  return norm
end

---------------------------------------------------------------------------
-- built-in ops
---------------------------------------------------------------------------

local function info()
  local names = {}
  for name in pairs(server.services) do names[#names + 1] = name end
  table.sort(names)
  return {
    server_version = server.version,
    build_id = server.build_id,
    proto_version = server.proto_version,
    pid = system.get_process_id(),
    platform = PLATFORM,
    arch = ARCH,
    home = server.home,
    root = server.root,
    cwd = serverfs.realpath("."),
    services = names,
    caps = server.caps,
    max_frame = server.max_frame,
  }
end

server.ops.ping = function(a) return a.data == nil and true or a.data end
server.ops.info = function() return info() end
server.ops.home = function() return server.home end
-- The account and environment the server (and every exec child) runs with.
server.ops.host_info = function()
  local ids = serverfs.ids()
  local path = {}
  for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do path[#path + 1] = dir end
  return {
    user = ids.user, uid = ids.uid, gid = ids.gid, gids = ids.gids,
    home = server.home, shell = os.getenv("SHELL"), path = path,
  }
end
server.ops.set_root = function(a)
  local p = server.path(a.path)
  server.project_root = p
  run_hooks("on_root", p)
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
  run_hooks("on_shutdown")
  return status
end

local function handshake_failed(code, text)
  send_final({ ev = "hello", proto_version = server.proto_version, server_version = server.version,
               err = { code = code, msg = text } })
end

local function main()
  server.log("thither-server %s pid %d started (root=%s)", server.version, system.get_process_id(), tostring(server.root))
  run_hooks("on_start", { root = server.root, home = server.home, userdir = server.userdir,
                          version = server.version, proto_version = server.proto_version })

  local reader = frame.reader(server.max_frame)
  local greeted = false
  local tick_hint = IDLE_WAIT_MS
  local more_frames = false

  while true do
    flush()
    if peer_closed then return bye(0, "peer closed the output pipe") end
    local timeout = tick_hint
    local live_hint = live_wait_hint()
    if live_hint and live_hint < timeout then timeout = live_hint end
    if more_frames then timeout = 0 end
    local want_write = out_head <= out_tail
    local readable = serverio.wait(timeout, want_write, out_bytes < OUT_HIGH_WATER)
    local sig = serverio.signalled()
    if sig then return bye(0, "terminated by signal " .. sig) end
    if readable then
      local data, err = serverio.read(262144)
      if data == nil then return bye(0, "stdin closed (" .. tostring(err) .. ")") end
      reader:feed(data)
    end

    more_frames = false
    for n = 1, FRAMES_PER_TURN do
      if n == FRAMES_PER_TURN then more_frames = true end
      local msg, code, detail = reader:next()
      if msg == nil then
        more_frames = false
        if code == "frame_too_large" then
          send_final({ err = { code = "frame_too_large", msg = "frame of " .. tostring(detail) ..
                       " bytes exceeds the " .. server.max_frame .. " byte limit" } })
          return bye(3, "oversized frame")
        elseif code == "bad_frame" then
          send({ err = { code = "bad_frame", msg = tostring(detail) } })
        else
          break
        end
      elseif type(msg) ~= "table" then
        send({ err = { code = "bad_frame", msg = "frame is not a map" } })
      elseif not greeted then
        if msg.ev ~= "hello" then
          handshake_failed("bad_hello", "the first frame must be a hello")
          return bye(2, "no hello")
        end
        if msg.proto_version ~= server.proto_version then
          handshake_failed("version_mismatch", string.format("server speaks protocol %d, client sent %s",
            server.proto_version, tostring(msg.proto_version)))
          return bye(2, "version mismatch")
        end
        greeted = true
        server.greeted = true
        local reply = info()
        reply.ev = "hello"
        reply.root = server.root
        send(reply)
        for _, held in ipairs(server.held or {}) do send(held) end
        server.held = nil
        server.log("client hello: %s", tostring(msg.client_version))
      elseif msg.cancel ~= nil then
        handle_cancel(msg.cancel)
      elseif msg.ev == "hello" then
        send({ err = { code = "bad_request", msg = "duplicate hello" } })
      else
        handle_request(msg)
      end
    end

    resume_live()

    tick_hint = IDLE_WAIT_MS
    for _, ticker in ipairs(server.tickers) do
      local ok, hint = pcall(ticker)
      if not ok then server.log("ticker failed: %s", tostring(hint))
      elseif hint and hint < tick_hint then tick_hint = hint end
    end
    serverio.flush_events()
  end
end

local status = main()
flush()
return status
