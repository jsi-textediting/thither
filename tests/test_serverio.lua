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
