-- thither-server relay: connects stdio to a persistent session daemon over Unix domain socket.
local frame = require "thither.frame"
local serverio = require "serverio"
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

-- Handle --kill
if opts.kill then
  local sfd = serverio.connect(sock_path)
  if not sfd then
    io.stderr:write("thither-server: session '", sname, "' is not running\n")
    return 0
  end
  local encoded_hello = frame.encode({ ev = "hello", proto_version = PROTO_VERSION, client_version = SERVER_VERSION })
  serverio.write_blocking(encoded_hello, 1000, sfd)
  local r = frame.reader()
  while true do
    local d = serverio.read(65536, sfd)
    if d and #d > 0 then r:feed(d) end
    local msg = r:next()
    if msg and msg.ev == "hello" then break end
    if d == nil then break end
  end
  local encoded_kill = frame.encode({ id = 1, op = "session_shutdown", args = {} })
  serverio.write_blocking(encoded_kill, 1000, sfd)
  serverio.close(sfd)
  return 0
end

-- Connect to daemon, starting it if not running
local sock_fd = serverio.connect(sock_path)
if not sock_fd then
  local lock_fd, lerr = serverio.lock(lock_path)
  local deadline = system.get_time() + 5
  while not lock_fd and system.get_time() < deadline do
    system.sleep(0.05)
    sock_fd = serverio.connect(sock_path)
    if sock_fd then break end
    lock_fd = serverio.lock(lock_path)
  end

  if not sock_fd and lock_fd then
    sock_fd = serverio.connect(sock_path)
    if not sock_fd then
      os.remove(sock_path)
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

      local start_deadline = system.get_time() + 5
      while system.get_time() < start_deadline do
        system.sleep(0.02)
        sock_fd = serverio.connect(sock_path)
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

-- Preamble handshake
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
  opts = opts,
}

local ok = serverio.write_blocking(frame.encode(preamble), 2000, sock_fd)
if not ok then
  serverio.close(sock_fd)
  io.stderr:write("thither-server: failed to send relay preamble\n")
  return 1
end

-- Await relay_ok
local r = frame.reader()
local greeted = false
local g_deadline = system.get_time() + 5
while system.get_time() < g_deadline do
  local p = serverio.poll({ [sock_fd] = "r" }, 100)
  if p[sock_fd] and p[sock_fd]:find("r") then
    local data, err = serverio.read(65536, sock_fd)
    if data and #data > 0 then
      r:feed(data)
      local msg = r:next()
      if msg and msg.ev == "relay_ok" then
        greeted = true
        break
      elseif msg and msg.err then
        serverio.close(sock_fd)
        io.stderr:write("thither-server: relay rejected: ", tostring(msg.err.msg or msg.err.code), "\n")
        return 2
      end
    elseif data == nil then
      break
    end
  end
end

if not greeted then
  serverio.close(sock_fd)
  io.stderr:write("thither-server: timeout waiting for relay_ok\n")
  return 1
end

-- Bidirectional raw byte pump loop
local in_buf = ""
local out_buf = r:unread_bytes()
local stdio_eof = false
local sock_eof = false

while true do
  local poll_map = {}
  if not stdio_eof and #in_buf < 262144 then
    poll_map[0] = "r"
  end
  if #in_buf > 0 then
    poll_map[sock_fd] = (poll_map[sock_fd] or "") .. "w"
  end
  if not sock_eof and #out_buf < 262144 then
    poll_map[sock_fd] = (poll_map[sock_fd] or "") .. "r"
  end
  if #out_buf > 0 then
    poll_map[1] = "w"
  end

  local rev = serverio.poll(poll_map, 1000)

  local sig = serverio.signalled()
  if sig then break end

  -- Write to stdio
  if rev[1] and rev[1]:find("w") and #out_buf > 0 then
    local n = serverio.write(out_buf, 0)
    if n and n > 0 then
      out_buf = out_buf:sub(n + 1)
    elseif not n then
      break
    end
  end

  -- Write to sock_fd
  if rev[sock_fd] and rev[sock_fd]:find("w") and #in_buf > 0 then
    local n = serverio.write(in_buf, 0, sock_fd)
    if n and n > 0 then
      in_buf = in_buf:sub(n + 1)
    elseif not n then
      break
    end
  end

  -- Read from stdio
  if rev[0] and (rev[0]:find("r") or rev[0]:find("hup")) then
    local data, err = serverio.read(65536)
    if data and #data > 0 then
      in_buf = in_buf .. data
    elseif data == nil then
      stdio_eof = true
      break
    end
  end

  -- Read from sock_fd
  if rev[sock_fd] and (rev[sock_fd]:find("r") or rev[sock_fd]:find("hup")) then
    local data, err = serverio.read(65536, sock_fd)
    if data and #data > 0 then
      out_buf = out_buf .. data
    elseif data == nil then
      sock_eof = true
      break
    end
  end
end

if #out_buf > 0 then
  serverio.write_blocking(out_buf, 500)
end

serverio.close(sock_fd)
return 0
