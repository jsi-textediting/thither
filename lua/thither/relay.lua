-- thither-server relay: connects stdio to a persistent session daemon over Unix domain socket.
local frame = require "thither.frame"
local serverio = require "serverio"
local serverfs = require "serverfs"
local session = require "thither.session"

local opts = SERVER_OPTS or {}
local sname, serr = session.validate_name(opts.session)
if not sname then
  io.stderr:write("thither-server: ", serr, "\n")
  return 1
end

-- 1. Determine and verify runtime directory
local rundir, rerr = session.runtime_dir()
if not rundir then
  io.stderr:write("thither-server: ", rerr, "\n")
  return 1
end

local sock_path, sperr = session.socket_path(rundir, sname)
if not sock_path then
  io.stderr:write("thither-server: ", sperr, "\n")
  return 1
end
local lock_path = session.lock_path(rundir, sname)

-- Only ever connect to / remove a socket of our own (lstat: no symlinks).
local sock_ok, sock_why = session.check_socket(sock_path)
if not sock_ok then
  io.stderr:write("thither-server: refusing ", sock_why, "\n")
  return 1
end

local function now() return system.get_time() end

--- serverio.connect: fd, or nil when no daemon answers. A socket owned by
--- another uid ("forbidden") is never talked to: give up at once.
local function connect()
  local fd, err = serverio.connect(sock_path)
  if not fd and err == "forbidden" then
    io.stderr:write("thither-server: refusing ", sock_path, ": the socket belongs to another user\n")
    os.exit(1)
  end
  return fd
end

--- Waits (poll) until fd is readable or `deadline` passes; true when readable.
local function wait_readable(fd, deadline)
  local rem = math.ceil((deadline - now()) * 1000)
  if rem <= 0 then return false end
  local p = serverio.poll({ [fd] = "r" }, math.min(rem, 1000))
  return p and p[fd] ~= nil
end

--- Reads the next frame from fd before `deadline`: msg | nil, why.
local function read_frame(fd, reader, deadline)
  while true do
    local msg, code = reader:next()
    if msg ~= nil then return msg end
    if code then return nil, code end
    if now() >= deadline then return nil, "timeout" end
    if wait_readable(fd, deadline) then
      local d = serverio.read(65536, fd)
      if d == nil then return nil, "eof" end
      if #d > 0 then reader:feed(d) end
    end
  end
end

-- Handle --kill
if opts.kill then
  local sfd = sock_why == "socket" and connect()
  if not sfd then
    io.stderr:write("thither-server: session '", sname, "' is not running\n")
    return 0
  end
  local deadline = now() + 5
  local function give_up(why)
    serverio.close(sfd)
    io.stderr:write("thither-server: session '", sname, "' did not answer (", why, "); not killed\n")
    return 1
  end
  local hello = frame.encode({ ev = "hello", proto_version = PROTO_VERSION, client_version = SERVER_VERSION })
  if not serverio.write_blocking(hello, 1000, sfd) then return give_up("cannot send") end
  local r = frame.reader()
  local msg, why = read_frame(sfd, r, deadline)
  if not msg then return give_up(why) end
  if msg.ev ~= "hello" or msg.err then return give_up("handshake refused") end
  local kill = frame.encode({ id = 1, op = "session_shutdown", args = {} })
  if not serverio.write_blocking(kill, 1000, sfd) then return give_up("cannot send") end
  while true do
    msg, why = read_frame(sfd, r, deadline)
    if not msg then
      -- EOF after the request was sent: the daemon is going away anyway
      if why == "eof" then break end
      return give_up(why)
    end
    if msg.id == 1 then
      if msg.err then
        serverio.close(sfd)
        io.stderr:write("thither-server: session_shutdown failed: ", tostring(msg.err.msg), "\n")
        return 1
      end
      break
    end
  end
  serverio.close(sfd)
  return 0
end

-- Connect to daemon, starting it if not running
local sock_fd = sock_why == "socket" and connect() or nil
if not sock_fd then
  local lock_fd, lerr = serverio.lock(lock_path)
  local deadline = now() + 5
  while not lock_fd and now() < deadline do
    system.sleep(0.05)
    sock_fd = connect()
    if sock_fd then break end
    lock_fd = serverio.lock(lock_path)
  end

  if not sock_fd and lock_fd then
    sock_fd = connect()
    if not sock_fd then
      -- we hold the lock, so no daemon is alive: a socket left there is stale
      local ok, why = session.check_socket(sock_path)
      if not ok then
        serverio.unlock(lock_fd)
        io.stderr:write("thither-server: refusing ", why, "\n")
        return 1
      end
      if why == "socket" then os.remove(sock_path) end
      local daemon_args = {
        EXEFILE,
        "--daemon",
        "--session", sname,
        "--idle-exit", tostring(opts.idle_exit or 600),
        "--retain-exited", tostring(opts.retain_exited or 3600),
      }
      if DATADIR then
        table.insert(daemon_args, "--datadir")
        table.insert(daemon_args, DATADIR)
      end
      if opts.root then
        table.insert(daemon_args, "--root")
        table.insert(daemon_args, opts.root)
      end
      if opts.log then
        table.insert(daemon_args, "--log")
        table.insert(daemon_args, opts.log)
      end
      if opts.plugins then
        for _, p in ipairs(opts.plugins) do
          table.insert(daemon_args, "--plugins")
          table.insert(daemon_args, p)
        end
      end
      local ok, derr = serverio.daemonize(daemon_args)
      serverio.unlock(lock_fd)
      lock_fd = nil
      if not ok then
        io.stderr:write("thither-server: cannot spawn daemon: ", tostring(derr), "\n")
        return 1
      end

      local start_deadline = now() + 5
      while now() < start_deadline do
        system.sleep(0.02)
        sock_fd = connect()
        if sock_fd then break end
      end
    end
    if lock_fd then serverio.unlock(lock_fd) end
  end
end

if not sock_fd then
  io.stderr:write("thither-server: cannot connect to session '", sname, "'\n")
  return 1
end

-- Preamble handshake. A relative --root is made absolute here: the daemon
-- runs in another directory (it keeps the spelling, the daemon realpaths it).
local popts = {}
for k, v in pairs(opts) do popts[k] = v end
if type(popts.root) == "string" and popts.root:sub(1, 1) ~= "/" then
  local cwd = serverfs.realpath(".")
  if cwd then popts.root = cwd .. "/" .. popts.root end
end
local preamble = {
  ev = "relay",
  relay_version = SERVER_VERSION,
  pid = system.get_process_id(),
  env = {
    SSH_AUTH_SOCK = os.getenv("SSH_AUTH_SOCK"),
    SSH_CONNECTION = os.getenv("SSH_CONNECTION"),
    SSH_CLIENT = os.getenv("SSH_CLIENT"),
    SSH_TTY = os.getenv("SSH_TTY"),
    TERM = os.getenv("TERM"),
    LANG = os.getenv("LANG"),
    LC_ALL = os.getenv("LC_ALL"),
  },
  opts = popts,
}

local ok = serverio.write_blocking(frame.encode(preamble), 2000, sock_fd)
if not ok then
  serverio.close(sock_fd)
  io.stderr:write("thither-server: failed to send relay preamble\n")
  return 1
end

-- Await relay_ok
local r = frame.reader()
local msg, why = read_frame(sock_fd, r, now() + 5)
if not msg or msg.ev ~= "relay_ok" then
  serverio.close(sock_fd)
  io.stderr:write("thither-server: no relay_ok from the daemon (", tostring(why or msg.ev), ")\n")
  return 1
end
if msg.err then
  -- the client gets an error hello in place of the daemon's
  serverio.close(sock_fd)
  local e = type(msg.err) == "table" and msg.err or { code = "relay_refused", msg = tostring(msg.err) }
  io.stderr:write("thither-server: relay rejected: ", tostring(e.msg or e.code), "\n")
  serverio.write_blocking(frame.encode({ ev = "hello", proto_version = PROTO_VERSION, server_version = SERVER_VERSION,
    err = { code = tostring(e.code or "relay_refused"), msg = tostring(e.msg or e.code) } }), 1000)
  return 2
end

-- Bidirectional raw byte pump loop. fd 0/1 in the poll set and the fd-less
-- read/write name the protocol channel (serverio keeps the real stdio there).
local MAX_BUF = 262144
local DRAIN_IDLE = 1      -- after stdin EOF: wait this long for more daemon output
local DRAIN_MAX = 10      -- ... but no longer than this in total
local in_buf = ""
local out_buf = r:unread_bytes()
local stdin_eof = false
local sock_eof = false
local drain_start, drain_last

local function has(ev, ch) return ev ~= nil and ev:find(ch, 1, true) ~= nil end

while true do
  -- stdin is done and everything it sent reached the daemon: there is no
  -- shutdown(SHUT_WR) in serverio, so give the daemon a bounded time to
  -- answer what is in flight, then go
  if stdin_eof and #in_buf == 0 and not drain_start then
    drain_start, drain_last = now(), now()
  end
  if sock_eof and #out_buf == 0 then break end
  if drain_start and #out_buf == 0 then
    local t = now()
    if t - drain_last >= DRAIN_IDLE or t - drain_start >= DRAIN_MAX then break end
  end

  local poll_map = {}
  if not stdin_eof and #in_buf < MAX_BUF then poll_map[0] = "r" end
  if not sock_eof then
    local ev = ""
    if #in_buf > 0 then ev = ev .. "w" end
    if #out_buf < MAX_BUF then ev = ev .. "r" end
    if ev ~= "" then poll_map[sock_fd] = ev end
  end
  if #out_buf > 0 then poll_map[1] = "w" end

  local timeout = 1000
  if drain_start then
    timeout = math.ceil(math.max(0, math.min(drain_last + DRAIN_IDLE, drain_start + DRAIN_MAX) - now()) * 1000)
    if #out_buf > 0 then timeout = 1000 end
  end
  local rev = serverio.poll(poll_map, timeout) or {}

  if serverio.signalled() then
    serverio.close(sock_fd)
    return 0
  end

  -- Write to stdout
  if has(rev[1], "w") or has(rev[1], "e") then
    local n = serverio.write(out_buf, 0)
    if not n then break end -- the client is gone
    if n > 0 then out_buf = out_buf:sub(n + 1) end
  end

  -- Write to the daemon
  if #in_buf > 0 and (has(rev[sock_fd], "w") or has(rev[sock_fd], "e")) then
    local n = serverio.write(in_buf, 0, sock_fd)
    if not n then
      sock_eof, in_buf = true, ""
    elseif n > 0 then
      in_buf = in_buf:sub(n + 1)
    end
  end

  -- Read from stdin ("r", "hup" and "err" all end in a read that tells)
  if has(rev[0], "r") or has(rev[0], "h") then
    local data = serverio.read(65536)
    if data == nil then
      stdin_eof = true
    elseif #data > 0 then
      in_buf = in_buf .. data
    end
  end

  -- Read from the daemon
  if not sock_eof and (has(rev[sock_fd], "r") or has(rev[sock_fd], "h")) then
    local data = serverio.read(65536, sock_fd)
    if data == nil then
      sock_eof, in_buf = true, ""
    elseif #data > 0 then
      out_buf = out_buf .. data
      if drain_start then drain_last = now() end
    end
  end
end

if #out_buf > 0 then
  serverio.write_blocking(out_buf, 1000)
end

serverio.close(sock_fd)
return 0
