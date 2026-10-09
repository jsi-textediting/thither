-- Unit tests for serverio: Unix domain sockets, multi-FD poll, and flock
local H = require "harness"
local U = require "util"
local serverio = require "serverio"

H.test("serverio: listen, accept, connect and data exchange", function()
  local dir = U.tmpdir("sock")
  local sock_path = dir .. "/test.sock"

  local lfd, err = serverio.listen(sock_path)
  H.ok(lfd, "listen failed: " .. tostring(err))

  -- Verify permissions: mode 0600
  local out = U.sh("stat -c %a " .. U.shq(sock_path))
  H.ok(out:find("600"), "socket permissions must be 0600, got: " .. out)

  local cfd, cerr = serverio.connect(sock_path)
  H.ok(cfd, "connect failed: " .. tostring(cerr))

  local afd, uid = serverio.accept(lfd)
  H.ok(afd, "accept failed: " .. tostring(uid))
  H.ok(uid > 0, "peer uid must be valid")

  -- Send from client to accepted server fd
  local n = serverio.write("ping_payload", 0, cfd)
  H.eq(n, #"ping_payload")

  -- Poll accepted fd
  local p = serverio.poll({ [afd] = "r" }, 1000)
  H.ok(p[afd] and p[afd]:find("r"), "accepted fd readable")

  local data = serverio.read(1024, afd)
  H.eq(data, "ping_payload")

  -- Send back reply
  local rn = serverio.write("pong_reply", 0, afd)
  H.eq(rn, #"pong_reply")

  local cp = serverio.poll({ [cfd] = "r" }, 1000)
  H.ok(cp[cfd] and cp[cfd]:find("r"), "client fd readable")

  local rdata = serverio.read(1024, cfd)
  H.eq(rdata, "pong_reply")

  serverio.close(cfd)
  serverio.close(afd)
  serverio.close(lfd)
  U.cleanup()
end)

H.test("serverio: file locking with flock", function()
  local dir = U.tmpdir("lock")
  local lock_path = dir .. "/session.lock"

  local fd1, err1 = serverio.lock(lock_path)
  H.ok(fd1, "first lock should succeed: " .. tostring(err1))

  -- Second non-blocking lock attempt must fail with "locked"
  local fd2, err2 = serverio.lock(lock_path)
  H.eq(fd2, nil)
  H.eq(err2, "locked")

  -- Unlock first
  local u = serverio.unlock(fd1)
  H.ok(u)

  -- Now second lock succeeds
  local fd3, err3 = serverio.lock(lock_path)
  H.ok(fd3, "lock after unlock should succeed: " .. tostring(err3))

  serverio.unlock(fd3)
  U.cleanup()
end)

H.test("serverio: poll timeout and multiple descriptors", function()
  local dir = U.tmpdir("poll")
  local sock_path = dir .. "/poll.sock"
  local lfd = serverio.listen(sock_path)
  H.ok(lfd)

  -- Poll with no ready event should timeout
  local t0 = system.get_time()
  local p0 = serverio.poll({ [lfd] = "r" }, 50)
  local elapsed = (system.get_time() - t0) * 1000
  H.ok(elapsed >= 40, "poll should have waited approx 50ms")
  H.ok(p0[lfd] == nil, "no connection yet")

  local cfd = serverio.connect(sock_path)
  local p1 = serverio.poll({ [lfd] = "r" }, 1000)
  H.ok(p1[lfd] and p1[lfd]:find("r"), "listener readable on incoming connection")

  local afd = serverio.accept(lfd)
  H.ok(afd)

  serverio.close(cfd)
  serverio.close(afd)
  serverio.close(lfd)
  U.cleanup()
end)

H.test("serverio: poll accepts fractional and negative timeouts", function()
  local dir = U.tmpdir("pollf")
  local lfd = serverio.listen(dir .. "/f.sock")
  H.ok(lfd)
  -- the daemon passes (idle_exit - elapsed) * 1000, which is a float
  local t0 = system.get_time()
  local p = serverio.poll({ [lfd] = "r" }, 20.25)
  H.ok(p and p[lfd] == nil, "no connection yet")
  H.ok((system.get_time() - t0) * 1000 >= 15, "fractional timeout waited")
  t0 = system.get_time()
  p = serverio.poll({ [lfd] = "r" }, -2.5)
  H.ok(p and p[lfd] == nil)
  H.ok(system.get_time() - t0 < 0.5, "negative timeout does not wait")
  H.ok(serverio.poll({}, 0.5))
  local r, w = serverio.wait(0.5, false, false)
  H.eq(r, false)
  H.eq(w, false)
  serverio.close(lfd)
  U.cleanup()
end)

-- fd 0/1 in poll() stand for the protocol channel that serverio_setup() moved
-- away from fd 0/1 (which become /dev/null and stderr): a child server runs a
-- script after the same switch.
H.test("serverio: poll maps fd 0/1 to the protocol channel", function()
  local dir = U.tmpdir("pollmap")
  local script = dir .. "/s.lua"
  U.write_file(script, [[
local serverio = require "serverio"
assert(serverio.setup())
if arg[1] == "idle" then
  local p = serverio.poll({ [0] = "r" }, 300)
  io.stderr:write("poll0=", tostring(p[0]), "\n")
  local w = serverio.poll({ [1] = "w" }, 300)
  io.stderr:write("poll1=", tostring(w[1]), "\n")
  serverio.write("PROTO_OUT", 0, 1)
  print("STRAY_PRINT")
else
  local p = serverio.poll({ [0] = "r" }, 3000)
  io.stderr:write("poll0=", tostring(p[0]), "\n")
  io.stderr:write("data=", tostring(serverio.read(100, 0)), "\n")
end
]])
  local exe = U.shq(EXEFILE) .. (DATADIR and (" --datadir " .. U.shq(DATADIR)) or "")
  local out_f, err_f = dir .. "/out", dir .. "/err"
  local redir = " > " .. U.shq(out_f) .. " 2> " .. U.shq(err_f)

  -- stdin is an open pipe with nothing in it: fd 0 must not be reported
  -- readable (it would be with /dev/null polled instead: a busy loop)
  local _, code = U.sh("sleep 2 | " .. exe .. " --run " .. U.shq(script) .. " idle" .. redir)
  H.eq(code, 0)
  local err = U.read_file(err_f) or ""
  H.ok(err:find("poll0=nil", 1, true), "idle protocol input reported ready: " .. err)
  H.ok(err:find("poll1=w", 1, true), "protocol output writable: " .. err)
  H.ok(err:find("STRAY_PRINT", 1, true), "print() goes to stderr: " .. err)
  H.eq(U.read_file(out_f), "PROTO_OUT")

  _, code = U.sh("printf hello | " .. exe .. " --run " .. U.shq(script) .. " feed" .. redir)
  H.eq(code, 0)
  err = U.read_file(err_f) or ""
  H.ok(err:find("poll0=r", 1, true), "pending protocol input reported: " .. err)
  H.ok(err:find("data=hello", 1, true), "protocol input read: " .. err)
  U.cleanup()
end)

H.test("serverio: accept errors carry an errno code", function()
  local dir = U.tmpdir("accerr")
  local lfd = serverio.listen(dir .. "/a.sock")
  H.ok(lfd)
  local a, code = serverio.accept(lfd)
  H.eq(a, nil)
  H.eq(code, "again")
  local fd = serverio.lock(dir .. "/not-a-socket")
  local msg
  a, code, msg = serverio.accept(fd)
  H.eq(a, nil)
  H.eq(code, "ENOTSOCK")
  H.ok(type(msg) == "string" and #msg > 0)
  serverio.unlock(fd)
  serverio.close(lfd)
  U.cleanup()
end)

-- connecting to a socket owned by another uid ("forbidden") needs root to set
-- up; check that our own sockets still pass the peer check.
H.test("serverio: connect checks the peer and accepts our own socket", function()
  local dir = U.tmpdir("peer")
  local path = dir .. "/p.sock"
  local lfd = serverio.listen(path)
  local cfd, cerr = serverio.connect(path)
  H.ok(cfd, "connect to own socket: " .. tostring(cerr))
  local afd = serverio.accept(lfd)
  H.ok(afd)
  serverio.close(cfd)
  serverio.close(afd)
  serverio.close(lfd)
  local nfd, nerr = serverio.connect(path)  -- nobody listening any more
  H.eq(nfd, nil)
  H.ok(nerr and nerr ~= "forbidden", "plain connect error: " .. tostring(nerr))
  U.cleanup()
end)

H.test("serverio: daemonize reports exec failures and returns the pid", function()
  local pid, code, msg = serverio.daemonize({ "/nonexistent/thither-no-such-daemon" })
  H.eq(pid, nil)
  H.eq(code, "ENOENT")
  H.ok(type(msg) == "string" and msg:find("thither-no-such-daemon", 1, true), tostring(msg))

  pid, code = serverio.daemonize({ "thither-no-such-daemon-in-path" })
  H.eq(pid, nil)
  H.eq(code, "ENOENT")

  local dir = U.tmpdir("daemon")
  local f = dir .. "/pid"
  pid, code = serverio.daemonize({ "sh", "-c", "echo $$ > " .. U.shq(f) .. ".tmp && mv " .. U.shq(f) .. ".tmp " .. U.shq(f) })
  H.ok(math.type(pid) == "integer" and pid > 0, "daemon pid: " .. tostring(pid) .. " " .. tostring(code))
  local got
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    got = U.read_file(f)
    if got then break end
    system.sleep(0.02)
  end
  H.eq(got and tonumber(got:match("%d+")), pid)
  U.cleanup()
end)
