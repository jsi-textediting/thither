-- Integration tests for Phase 2: sessions, daemon, relay and lifecycle
local H = require "harness"
local U = require "util"
local Client = require "client"
local serverio = require "serverio"
local serverfs = require "serverfs"
local session = require "thither.session"

H.test("session: relay spawns daemon and completes handshake", function()
  local sname = "sess_spawn_" .. tostring(system.get_process_id())
  local c, reply = Client.connect({ args = { "--session", sname } })

  H.eq(reply.ev, "hello")
  H.ok(reply.session ~= nil, "hello reply should include session table")
  H.eq(reply.session.name, sname)
  H.ok(reply.session.daemon_pid > 0, "session should have positive daemon_pid")
  H.eq(type(reply.session.started), "number")

  local caps = {}
  for _, cap in ipairs(reply.caps) do caps[cap] = true end
  H.ok(caps["session"], "session cap should be advertised in daemon mode")

  -- Ping
  local pong = c:request("ping", { data = "hello_daemon" })
  H.eq(pong, "hello_daemon")

  -- host_info includes session_name
  local hinfo = c:request("host_info")
  H.eq(hinfo.session_name, sname)

  -- session_info op
  local sinfo = c:request("session_info")
  H.eq(sinfo.name, sname)
  H.eq(sinfo.daemon_pid, reply.session.daemon_pid)
  H.eq(sinfo.connections, 1)

  -- Socket file exists
  local rundir = assert(session.runtime_dir())
  local sock_path = assert(session.socket_path(rundir, sname))
  H.ok(serverfs.stat(sock_path) ~= nil, "daemon socket file should exist")

  -- Shutdown daemon cleanly
  local sok = c:request("session_shutdown")
  H.ok(sok)
  c:close()

  -- Verify daemon exits
  local deadline = system.get_time() + 3
  local dead = false
  while system.get_time() < deadline do
    local _, kcode = U.sh("kill -0 " .. reply.session.daemon_pid)
    if kcode ~= 0 then dead = true; break end
    system.sleep(0.05)
  end
  H.ok(dead, "daemon process should exit after session_shutdown")
  H.ok(serverfs.stat(sock_path) == nil, "daemon socket should be removed after shutdown")
end)

H.test("session: session ops outside daemon mode are refused with bad_request", function()
  local c = Client.connect() -- stdio mode

  local res, err = c:request("session_info")
  H.eq(res, nil)
  H.ok(err and err.code == "bad_request", "expected bad_request for session_info")

  res, err = c:request("session_shutdown")
  H.eq(res, nil)
  H.ok(err and err.code == "bad_request", "expected bad_request for session_shutdown")

  c:close()
end)

H.test("session: multiple concurrent relays attach to same daemon", function()
  local sname = "sess_multi_" .. tostring(system.get_process_id())
  local c1, rep1 = Client.connect({ args = { "--session", sname } })
  local c2, rep2 = Client.connect({ args = { "--session", sname } })

  H.eq(rep1.session.daemon_pid, rep2.session.daemon_pid, "both relays must attach to the same daemon")

  local sinfo = c1:request("session_info")
  H.eq(sinfo.connections, 2, "daemon should report 2 active connections")

  -- Interleaved requests on both connections
  H.eq(c1:request("ping", { data = "c1_data" }), "c1_data")
  H.eq(c2:request("ping", { data = "c2_data" }), "c2_data")

  -- Close one connection; other continues
  c1:close()
  H.eq(c2:request("ping", { data = "c2_alive" }), "c2_alive")

  c2:request("session_shutdown")
  c2:close()
end)

H.test("session: killing relay leaves daemon running, and second relay can reattach", function()
  local sname = "sess_reattach_" .. tostring(system.get_process_id())
  local c1, rep1 = Client.connect({ args = { "--session", sname } })
  local daemon_pid = rep1.session.daemon_pid

  -- Kill the relay process immediately
  c1.proc:kill()
  c1:wait_exit(2)

  -- Daemon must survive the dropped relay connection
  system.sleep(0.1)
  local _, kcode = U.sh("kill -0 " .. daemon_pid)
  H.eq(kcode, 0, "daemon process should still be running after relay killed")

  -- Reconnect with fresh relay
  local c2, rep2 = Client.connect({ args = { "--session", sname } })
  H.eq(rep2.session.daemon_pid, daemon_pid, "second relay should connect to existing daemon")
  H.eq(c2:request("ping"), true)

  c2:request("session_shutdown")
  c2:close()
end)

H.test("session: dynamic SSH_AUTH_SOCK agent.sock symlink", function()
  local sname = "sess_agent_" .. tostring(system.get_process_id())
  local sock1 = "/tmp/thither_fake_agent1_" .. tostring(system.get_process_id()) .. ".sock"
  local sock2 = "/tmp/thither_fake_agent2_" .. tostring(system.get_process_id()) .. ".sock"
  local notsock = "/tmp/thither_fake_agent3_" .. tostring(system.get_process_id()) .. ".sock"
  -- the link may only point at sockets owned by us: real listening sockets
  local lfd1 = assert(serverio.listen(sock1))
  local lfd2 = assert(serverio.listen(sock2))
  U.write_file(notsock, "not a socket")

  local c1, rep1 = Client.connect({
    args = { "--session", sname },
    env = { SSH_AUTH_SOCK = sock1 },
  })

  local statedir = assert(session.state_dir(sname))
  local agent_link = session.agent_link(statedir)

  local st = serverfs.stat(agent_link, true)
  H.ok(st and st.is_link, "agent.sock should be a symlink")
  H.eq(st.link, sock1)

  -- Connect second relay with different SSH_AUTH_SOCK
  local c2, rep2 = Client.connect({
    args = { "--session", sname },
    env = { SSH_AUTH_SOCK = sock2 },
  })

  st = serverfs.stat(agent_link, true)
  H.ok(st and st.is_link)
  H.eq(st.link, sock2, "agent.sock should update to latest connection's agent socket")

  -- Disconnect c2; agent.sock should revert to c1
  c2:close()
  system.sleep(0.1)
  st = serverfs.stat(agent_link, true)
  H.ok(st and st.is_link)
  H.eq(st.link, sock1, "agent.sock should revert to remaining c1 agent socket")

  -- a relay whose SSH_AUTH_SOCK is not a socket does not move the link
  local c3 = Client.connect({
    args = { "--session", sname },
    env = { SSH_AUTH_SOCK = notsock },
  })
  st = serverfs.stat(agent_link, true)
  H.ok(st and st.is_link)
  H.eq(st.link, sock1, "a regular file is never the agent socket")
  c3:close()

  c1:request("session_shutdown")
  c1:close()
  serverio.close(lfd1)
  serverio.close(lfd2)
  os.remove(sock1)
  os.remove(sock2)
  os.remove(notsock)
end)

H.test("session: CLI --kill terminates daemon", function()
  local sname = "sess_kill_" .. tostring(system.get_process_id())
  local c, rep = Client.connect({ args = { "--session", sname } })
  local daemon_pid = rep.session.daemon_pid

  local datadir_arg = DATADIR and (" --datadir " .. U.shq(DATADIR)) or ""
  local out, code = U.sh(U.shq(EXEFILE) .. datadir_arg .. " --session " .. sname .. " --kill")
  H.eq(code, 0, "CLI --kill should exit 0")

  local deadline = system.get_time() + 3
  local dead = false
  while system.get_time() < deadline do
    local _, kcode = U.sh("kill -0 " .. daemon_pid)
    if kcode ~= 0 then dead = true; break end
    system.sleep(0.05)
  end
  H.ok(dead, "daemon process should exit after CLI --kill")
  c:close()
end)

H.test("session: directory and session name security validation", function()
  H.ok(session.validate_name("valid_name-1.0"))
  H.ok(not session.validate_name("bad/name"))
  H.ok(not session.validate_name("bad name"))
  H.ok(not session.validate_name(string.rep("x", 33)))

  local symlink_dir = U.tmpdir("symsec")
  local real_target = U.tmpdir("realtarget")
  local link_path = symlink_dir .. "/link"
  serverfs.symlink(real_target, link_path, true)

  local ok, err = session.verify_dir(link_path)
  H.ok(not ok, "symlinks must be rejected as secure directories")
end)

H.test("session: idle exit timer", function()
  local sname = "sess_idle_" .. tostring(system.get_process_id())
  local agent = "/tmp/thither_idle_agent_" .. tostring(system.get_process_id()) .. ".sock"
  local afd = assert(serverio.listen(agent))
  os.remove(session.daemon_log(assert(session.state_dir(sname))))
  local c, rep = Client.connect({ args = { "--session", sname, "--idle-exit", "1" },
                                  env = { SSH_AUTH_SOCK = agent } })
  local daemon_pid = rep.session.daemon_pid
  local statedir = assert(session.state_dir(sname))
  local sock_path = assert(session.socket_path(assert(session.runtime_dir()), sname))
  H.ok(serverfs.stat(session.agent_link(statedir), true), "agent link while attached")

  H.eq(c:request("ping"), true)
  c:close()

  -- Wait for 1 second idle exit + small buffer
  local deadline = system.get_time() + 5
  local dead = false
  while system.get_time() < deadline do
    local _, kcode = U.sh("kill -0 " .. daemon_pid)
    if kcode ~= 0 then dead = true; break end
    system.sleep(0.1)
  end
  H.ok(dead, "daemon should exit after idle timeout expires")
  -- a clean shutdown, not a crash: the socket and the agent link are gone and
  -- the log has the idle line and the final one
  H.ok(serverfs.stat(sock_path, true) == nil, "socket removed")
  H.ok(serverfs.stat(session.agent_link(statedir), true) == nil, "agent link removed")
  local log = U.read_file(session.daemon_log(statedir)) or ""
  H.ok(log:find("idle timeout reached", 1, true), "idle exit logged:\n" .. log)
  H.ok(log:find("daemon exited cleanly", 1, true), "clean exit logged:\n" .. log)
  serverio.close(afd)
  os.remove(agent)
end)

---------------------------------------------------------------------------
-- review fixes (2026-10-09): preamble validation, roots, relay I/O, --kill,
-- directory and socket checks, start-up races
---------------------------------------------------------------------------

local frame = require "thither.frame"

local function sname_of(tag) return "s_" .. tag .. "_" .. tostring(system.get_process_id()) end

local function sock_of(sname)
  return assert(session.socket_path(assert(session.runtime_dir()), sname))
end

local function alive(pid)
  local _, k = U.sh("kill -0 " .. pid)
  return k == 0
end

local function wait_dead(pid, secs)
  local deadline = system.get_time() + (secs or 3)
  while system.get_time() < deadline do
    if not alive(pid) then return true end
    system.sleep(0.05)
  end
  return false
end

local function shutdown(c, pid)
  c:request("session_shutdown")
  c:close()
  if pid then H.ok(wait_dead(pid), "daemon did not exit") end
end

--- Sends a relay preamble straight to the daemon's socket and returns the
--- first frame it answers with (nil on EOF / timeout).
local function raw_preamble(sock_path, pre)
  local fd = assert(serverio.connect(sock_path))
  pre.ev = "relay"
  assert(serverio.write_blocking(frame.encode(pre), 2000, fd))
  local r = frame.reader()
  local deadline = system.get_time() + 5
  local msg
  while not msg and system.get_time() < deadline do
    local p = serverio.poll({ [fd] = "r" }, 100)
    if p and p[fd] then
      local d = serverio.read(65536, fd)
      if d == nil then break end
      if #d > 0 then r:feed(d) end
      msg = r:next()
    end
  end
  serverio.close(fd)
  return msg
end

-- CPU ticks (utime + stime) of a process from /proc, nil without it
local CLK_TCK = tonumber((U.sh("getconf CLK_TCK")):match("%d+")) or 100
local function ticks_of(pid)
  local stat = U.read_file("/proc/" .. pid .. "/stat")
  if not stat then return nil end
  local fields = {}
  for x in stat:match("%)%s+(.*)$"):gmatch("%S+") do fields[#fields + 1] = x end
  return tonumber(fields[12]) + tonumber(fields[13])
end

H.test("session: a bad relay preamble is refused, the daemon survives", function()
  local dir = U.tmpdir("badpre")
  local root = dir .. "/root"
  U.sh("mkdir -p " .. U.shq(root .. "/sub") .. " " .. U.shq(dir .. "/outside")
    .. " && ln -s " .. U.shq(dir .. "/outside") .. " " .. U.shq(root .. "/escape")
    .. " && echo x > " .. U.shq(root .. "/file"))
  local sname = sname_of("badpre")
  local c, rep = Client.connect({ args = { "--session", sname, "--root", root } })
  local pid = rep.session.daemon_pid
  local sock = sock_of(sname)
  for _, case in ipairs({
    { "relative root", { opts = { root = "sub" } }, "bad_path" },
    { "missing root", { opts = { root = root .. "/nope" } }, "ENOENT" },
    { "root that is a file", { opts = { root = root .. "/file" } }, "ENOTDIR" },
    { "non-table env", { env = "SSH_AUTH_SOCK=x" }, "bad_request" },
    { "non-string env value", { env = { TERM = 1 } }, "bad_request" },
    { "non-table opts", { opts = "x" }, "bad_request" },
    { "non-string root", { opts = { root = 5 } }, "bad_request" },
    { "non-string log", { opts = { log = 5 } }, "bad_request" },
    { "relative log", { opts = { log = "req.log" } }, "bad_request" },
    { "non-table plugins", { opts = { plugins = "x" } }, "bad_request" },
    { "plugins with a table in it", { opts = { plugins = { {} } } }, "bad_request" },
    { "plugins with a boolean in it", { opts = { plugins = { true } } }, "bad_request" },
    { "sparse plugins", { opts = { plugins = { "a", [3] = "c" } } }, "bad_request" },
    { "non-string relay_version", { relay_version = 5 }, "bad_request" },
    { "non-string build_id", { build_id = {} }, "bad_request" },
  }) do
    local m = raw_preamble(sock, case[2])
    H.ok(m and m.ev == "relay_ok" and m.err, case[1] .. ": expected an error relay_ok")
    H.eq(m and m.err and m.err.code, case[3], case[1])
    H.ok(alive(pid), case[1] .. ": the daemon died")
  end
  -- the first relay's --root is its own jail, not the daemon's: a root
  -- outside it (also through a symlink) is fine for another connection
  local m = raw_preamble(sock, { opts = { root = root .. "/escape" } })
  H.ok(m and m.ev == "relay_ok" and not m.err, "a root outside the first relay's: " .. tostring(m and m.err and m.err.code))
  -- through a real relay: the client gets an error hello, the relay exits 2
  local bad = Client.spawn({ args = { "--session", sname, "--root", root .. "/nope" } })
  local hello = bad:hello()
  H.ok(hello and hello.ev == "hello" and hello.err, "error hello from a refused relay")
  H.eq(hello and hello.err and hello.err.code, "ENOENT")
  H.eq(bad:wait_exit(5), 2)
  -- a good relay still works, on the same daemon
  local c2, rep2 = Client.connect({ args = { "--session", sname, "--root", root .. "/sub" } })
  H.eq(rep2.session.daemon_pid, pid)
  H.eq(c2:request("ping", { data = "ok" }), "ok")
  H.eq(c2:request("info").root, serverfs.realpath(root .. "/sub"))
  H.eq(c:request("ping", { data = "still" }), "still")
  c2:close()
  shutdown(c, pid)
end)

--- Port of the --root jail rules for a connection whose root is `spelled`
--- (a path through a symlink) and resolves to `real`.
local function check_symlinked_root(c, dir, spelled, real)
  H.eq(c:request("stat", { path = spelled .. "/sub/a.txt" }).size, 5, "via the symlink spelling")
  H.eq(c:request("stat", { path = real .. "/sub/a.txt" }).size, 5, "via the real path")
  H.ok(c:request("write", { path = spelled .. "/new.txt", data = "n" }))
  H.eq(U.read_file(real .. "/new.txt"), "n")
  local _, err = c:request("stat", { path = dir .. "/outside/s.txt" })
  H.eq(err and err.code, "jail", "outside the root")
  _, err = c:request("read", { path = spelled .. "/escape/s.txt", offset = 0, len = 10 })
  H.eq(err and err.code, "jail", "symlink escape")
  for _, p in ipairs({ spelled, real, spelled .. "/sub/..", real .. "/sub/..", spelled .. "/" }) do
    local _, rerr = c:request("remove", { path = p, recursive = true })
    H.eq(rerr and rerr.code, "jail", "remove of the root as " .. p)
  end
  H.ok(U.exists(real .. "/sub/a.txt"), "the root is still there")
  -- nofollow: a link in the root that points outside can be stat'ed and removed
  H.eq(c:request("stat", { path = spelled .. "/escape", nofollow = true }).type, "symlink")
  _, err = c:request("stat", { path = spelled .. "/escape/s.txt", nofollow = true })
  H.eq(err and err.code, "jail", "only the last component may be a link out")
  H.ok(c:request("remove", { path = spelled .. "/escape/", recursive = true }))
  H.ok(not U.exists(real .. "/escape"), "link removed")
  H.eq(U.read_file(dir .. "/outside/s.txt"), "secret\n", "the target is untouched")
end

local function symlinked_tree(tag)
  local dir = U.tmpdir(tag)
  U.sh("mkdir -p " .. U.shq(dir .. "/real/proj/sub") .. " " .. U.shq(dir .. "/outside")
    .. " && echo secret > " .. U.shq(dir .. "/outside/s.txt")
    .. " && ln -s real " .. U.shq(dir .. "/link")
    .. " && ln -s " .. U.shq(dir .. "/outside") .. " " .. U.shq(dir .. "/real/proj/escape"))
  U.write_file(dir .. "/real/proj/sub/a.txt", "hello")
  return dir, dir .. "/link/proj", serverfs.realpath(dir .. "/real/proj")
end

H.test("session: set_root records a per-connection project root and does not jail", function()
  local dir, spelled, real = symlinked_tree("sroot")
  local sname = sname_of("setroot")
  local c, rep = Client.connect({ args = { "--session", sname } })
  local c2 = Client.connect({ args = { "--session", sname } })
  H.ok(c:request("set_root", { path = spelled }))
  local info = c:request("info")
  H.eq(info.project_root, real, "the project root is stored as its realpath")
  H.eq(info.root, nil, "set_root is not a jail")
  H.eq(c:request("stat", { path = dir .. "/outside/s.txt" }).type, "file", "outside the project is reachable")
  H.eq(c2:request("info").project_root, nil, "the other connection has its own project root")
  -- set_root to a missing directory is an error, the old project root stays
  local _, err = c:request("set_root", { path = real .. "/missing" })
  H.eq(err and err.code, "ENOENT")
  H.eq(c:request("info").project_root, real)
  c2:close()
  shutdown(c, rep.session.daemon_pid)
end)

H.test("session: --root through a symlink (per-connection preamble root)", function()
  local dir, spelled, real = symlinked_tree("proot")
  local sname = sname_of("symroot")
  local c, rep = Client.connect({ args = { "--session", sname, "--root", spelled } })
  H.eq(rep.root, real)
  check_symlinked_root(c, dir, spelled, real)
  -- the root in its symlinked spelling can be stat'ed without following
  H.eq(c:request("stat", { path = spelled, nofollow = true }).type, "dir", "stat{nofollow} of the spelled root")
  H.eq(c:request("stat", { path = real, nofollow = true }).type, "dir", "stat{nofollow} of the real root")
  for _, op in ipairs({
    { "rename", { from = spelled, to = spelled .. "/sub/moved" } },
    { "symlink", { target = "/tmp", path = spelled, overwrite = true } },
  }) do
    local _, err = c:request(op[1], op[2])
    H.eq(err and err.code, "jail", op[1] .. " of the spelled root")
  end
  H.ok(U.exists(real .. "/sub/a.txt"), "the root is still there")
  shutdown(c, rep.session.daemon_pid)
end)

H.test("session: --root and --log are per connection, not inherited from the first relay", function()
  local dir = U.tmpdir("multiroot")
  U.sh("mkdir -p " .. U.shq(dir .. "/a") .. " " .. U.shq(dir .. "/b"))
  U.write_file(dir .. "/a/fa.txt", "a")
  U.write_file(dir .. "/b/fb.txt", "bb")
  local ra, rb = serverfs.realpath(dir .. "/a"), serverfs.realpath(dir .. "/b")
  local sname = sname_of("multiroot")
  local statedir = assert(session.state_dir(sname))
  os.remove(session.daemon_log(statedir))
  local loga = dir .. "/a.log"
  -- the first relay starts the daemon
  local c1, rep1 = Client.connect({ args = { "--session", sname, "--root", ra, "--log", loga } })
  local pid = rep1.session.daemon_pid
  H.eq(rep1.root, ra)
  -- a second relay with another root, outside the first one's
  local c2, rep2 = Client.connect({ args = { "--session", sname, "--root", rb } })
  H.eq(rep2.session.daemon_pid, pid, "same daemon")
  H.eq(rep2.root, rb)
  H.eq(c2:request("stat", { path = rb .. "/fb.txt" }).size, 2)
  local _, err = c2:request("stat", { path = ra .. "/fa.txt" })
  H.eq(err and err.code, "jail", "the second relay is jailed to its own root")
  _, err = c1:request("stat", { path = rb .. "/fb.txt" })
  H.eq(err and err.code, "jail", "the first relay keeps its root")
  -- a third relay without --root is not jailed at all
  local c3, rep3 = Client.connect({ args = { "--session", sname } })
  H.eq(rep3.session.daemon_pid, pid, "same daemon")
  H.eq(rep3.root, nil, "no jail inherited from the first relay")
  H.eq(c3:request("info").root, nil)
  H.eq(c3:request("stat", { path = ra .. "/fa.txt" }).size, 1)
  H.eq(c3:request("stat", { path = rb .. "/fb.txt" }).size, 2)
  H.ok(c3:request("host_info"))
  c2:close()
  c3:close()
  shutdown(c1, pid)
  -- the first relay's --log is its request log only, the daemon logs to its
  -- state directory
  local la = U.read_file(loga) or ""
  H.ok(la:find("req %d+ stat"), "the first relay's requests in its log:\n" .. la)
  H.ok(not la:find("host_info", 1, true), "another connection's requests in the first relay's log:\n" .. la)
  H.ok(not la:find("accepted connection", 1, true), "daemon log lines in a request log:\n" .. la)
  local dl = U.read_file(session.daemon_log(statedir)) or ""
  H.ok(dl:find("accepted connection", 1, true), "the daemon log is in the state dir:\n" .. dl)
end)

H.test("session: an attached idle relay does not spin", function()
  local sname = sname_of("relaycpu")
  local c, rep = Client.connect({ args = { "--session", sname } })
  local rpid = c.proc:pid()
  if not ticks_of(rpid) then shutdown(c) print("     (skipped: no /proc)") return end
  H.eq(c:request("ping"), true)
  local a = ticks_of(rpid)
  local da = ticks_of(rep.session.daemon_pid)
  system.sleep(2)
  local used, dused = ticks_of(rpid) - a, ticks_of(rep.session.daemon_pid) - da
  H.ok(used < CLK_TCK // 10, string.format("relay used %d ticks in 2 s while idle", used))
  H.ok(dused < CLK_TCK // 10, string.format("daemon used %d ticks in 2 s while idle", dused))
  shutdown(c, rep.session.daemon_pid)
end)

H.test("session: relay stdin EOF still delivers large and async replies in flight", function()
  local dir = U.tmpdir("relayeof2")
  local path = dir .. "/f"
  local MB = 1024 * 1024
  U.sh("yes 'a line for the relay stdin eof test' | head -c " .. (8 * MB) .. " > " .. U.shq(path))
  local sname = sname_of("relayeof2")
  local c0, rep = Client.connect({ args = { "--session", sname } })
  local c = Client.spawn({ args = { "--session", sname } })
  c:send({ ev = "hello", proto_version = 1, client_version = "tests", caps = {} })
  -- a reply far larger than the socket buffer, and a job that yields
  c:send({ id = 1, op = "read", args = { path = path, offset = 0, len = 4 * MB } })
  c:send({ id = 2, op = "lineindex", args = { path = path, chunk_size = 65536 } })
  c.proc:close_stream(process.STREAM_STDIN)
  H.eq(c:wait_exit(10), 0, "relay exit status")
  local got = {}
  for _ = 1, 3 do
    local m = c:recv(1)
    if m then got[m.id or m.ev] = m end
  end
  H.ok(got.hello, "hello reply")
  H.ok(got[1] and got[1].ok and #got[1].ok.data == 4 * MB,
    "the whole read reply: " .. tostring(got[1] and (got[1].err and got[1].err.code or #got[1].ok.data)))
  H.ok(got[2] and got[2].ok, "the lineindex reply: " .. tostring(got[2] and got[2].err and got[2].err.code))
  shutdown(c0, rep.session.daemon_pid)
end)

H.test("session: relay stdin EOF still delivers the replies in flight", function()
  local sname = sname_of("relayeof")
  local c0, rep = Client.connect({ args = { "--session", sname } })
  local c = Client.spawn({ args = { "--session", sname } })
  c:send({ ev = "hello", proto_version = 1, client_version = "tests", caps = {} })
  c:send({ id = 1, op = "ping", args = { data = "late" } })
  c.proc:close_stream(process.STREAM_STDIN)
  H.eq(c:wait_exit(5), 0, "relay exit status")
  local hello, pong = c:recv(1), c:recv(1)
  H.ok(hello and hello.ev == "hello", "hello reply")
  H.ok(pong and pong.id == 1 and pong.ok == "late", "ping reply after stdin EOF")
  shutdown(c0, rep.session.daemon_pid)
end)

H.test("session: --kill gives up on a daemon that does not answer", function()
  local datadir_arg = DATADIR and (" --datadir " .. U.shq(DATADIR)) or ""
  local kill = U.shq(EXEFILE) .. datadir_arg .. " --session "
  -- absent
  local t0 = system.get_time()
  local _, code = U.sh(kill .. sname_of("killnone") .. " --kill")
  H.eq(code, 0, "--kill of a session that is not running")
  H.ok(system.get_time() - t0 < 3, "absent: quick")
  -- stuck: something listens on the socket but never answers
  local sname = sname_of("killstuck")
  local sock = sock_of(sname)
  local lfd = assert(serverio.listen(sock))
  t0 = system.get_time()
  local out
  out, code = U.sh(kill .. sname .. " --kill")
  local took = system.get_time() - t0
  serverio.close(lfd)
  os.remove(sock)
  H.ok(code ~= 0, "--kill of a stuck daemon fails: " .. out)
  H.ok(took < 8, string.format("--kill took %.1f s", took))
end)

H.test("session: verify_dir refuses a directory with the wrong mode", function()
  local base = U.tmpdir("vdir")
  local d = base .. "/open"
  U.sh("mkdir " .. U.shq(d) .. " && chmod 755 " .. U.shq(d))
  local ok, err = session.verify_dir(d)
  H.ok(not ok and err:find("0700", 1, true), "0755 dir accepted: " .. tostring(err))
  H.eq(serverfs.stat(d, true).mode, 493, "and left alone (no chmod)")
  -- a directory created by verify_dir is fine, also with a narrow umask
  H.ok(session.verify_dir(base .. "/new/deeper"))
  H.eq(serverfs.stat(base .. "/new/deeper", true).mode, 448)
  -- a file is not a directory
  U.write_file(base .. "/file", "x")
  H.ok(not session.verify_dir(base .. "/file"))
end)

H.test("session: a stale socket is recovered, a non-socket is refused", function()
  local sname = sname_of("stale")
  local sock = sock_of(sname)
  -- a socket file nobody listens on any more
  serverio.close(assert(serverio.listen(sock)))
  H.ok(serverfs.stat(sock, true), "stale socket file in place")
  local c, rep = Client.connect({ args = { "--session", sname } })
  H.eq(c:request("ping", { data = "fresh" }), "fresh")
  shutdown(c, rep.session.daemon_pid)
  -- a regular file in place of the socket is never connected to nor removed
  U.write_file(sock, "not a socket")
  local bad = Client.spawn({ args = { "--session", sname } })
  H.eq(bad:wait_exit(5), 1, "relay refuses a non-socket")
  H.ok(bad.stderr:find("not a socket", 1, true), "stderr: " .. bad.stderr)
  H.eq(U.read_file(sock), "not a socket", "file untouched")
  os.remove(sock)
end)

H.test("session: relays started at once share one daemon", function()
  local sname = sname_of("race")
  local clients = {}
  for i = 1, 6 do clients[i] = Client.spawn({ args = { "--session", sname } }) end
  local pid
  for i, c in ipairs(clients) do
    local hello = c:hello()
    H.ok(hello and hello.ev == "hello" and not hello.err, "relay " .. i .. ": " .. c.stderr)
    pid = pid or hello.session.daemon_pid
    H.eq(hello.session.daemon_pid, pid, "relay " .. i .. " reached another daemon")
  end
  H.eq(clients[1]:request("session_info").connections, #clients)
  -- a daemon that lost the lock race gives up on its own; one is left
  local deadline, n = system.get_time() + 5, nil
  repeat
    n = tonumber((U.sh("pgrep -fc -- '--daemon --session " .. sname .. "( |$)'")):match("%d+"))
    if n == 1 then break end
    system.sleep(0.1)
  until system.get_time() > deadline
  H.eq(n, 1, "daemon processes for the session")
  for i = 2, #clients do clients[i]:close() end
  shutdown(clients[1], pid)
end)

H.test("session: SIGTERM to daemon shuts it down cleanly", function()
  local sname = sname_of("sigterm")
  local c, rep = Client.connect({ args = { "--session", sname } })
  local pid = rep.session.daemon_pid
  local sock = sock_of(sname)
  H.ok(serverfs.stat(sock) ~= nil, "socket exists")

  -- Send SIGTERM directly to daemon process
  U.sh("kill -TERM " .. pid)
  H.ok(wait_dead(pid, 3), "daemon should exit cleanly on SIGTERM")
  H.ok(serverfs.stat(sock) == nil, "daemon socket should be removed on SIGTERM")
  c:close()
end)

H.test("session: per-connection --log writes request log", function()
  local sname = sname_of("conn_log")
  local logdir = U.tmpdir("log")
  local logfile = logdir .. "/client.log"
  local c, rep = Client.connect({ args = { "--session", sname, "--log", logfile } })
  H.eq(c:request("ping", { data = "logged_req" }), "logged_req")
  local pid = rep.session.daemon_pid
  shutdown(c, pid)

  local content = U.read_file(logfile)
  H.ok(content and content:find("req %d+ ping"), "per-connection log should contain ping request: " .. tostring(content))
  H.ok(content:find("rep %d+ ok"), "per-connection log should contain ping reply: " .. tostring(content))
  -- a request log, not the daemon log (that stays in the state dir)
  H.ok(not content:find("accepted connection", 1, true), "daemon log lines in the request log: " .. content)
end)

H.test("session: plugin mismatch reported in relay_ok", function()
  local sname = sname_of("plugin_mismatch")
  local c, rep = Client.connect({ args = { "--session", sname } })
  local sock = sock_of(sname)
  local msg = raw_preamble(sock, {
    relay_version = "0.9.0",
    build_id = "differ123456",
    opts = { plugins = { "/custom/plugin/path" } }
  })
  H.ok(msg and msg.ev == "relay_ok" and not msg.err, "relay_ok response")
  H.eq(type(msg.daemon_plugins), "table")
  H.ok(msg.daemon_build ~= nil)
  -- the daemon logs the mismatch
  local dlog = U.read_file(session.daemon_log(assert(session.state_dir(sname)))) or ""
  H.ok(dlog:find("differ from daemon plugins", 1, true), "mismatch in the daemon log:\n" .. dlog)
  -- and a real relay asking for other plugins warns on its stderr
  local plugdir = U.tmpdir("noplug")
  local c2 = Client.connect({ args = { "--session", sname, "--plugins", plugdir } })
  H.eq(c2:request("ping", { data = 1 }), 1)
  c2:pump()
  H.ok(c2.stderr:find("session plugins differ", 1, true), "relay warning: " .. c2.stderr)
  c2:close()
  shutdown(c, rep.session.daemon_pid)
end)

H.test("session: version skew includes build_id in hello session table", function()
  local sname = sname_of("skew")
  local server = require "thither"
  local c1, rep1 = Client.connect({ args = { "--session", sname } })
  local sock = sock_of(sname)
  local fd = assert(serverio.connect(sock))
  -- Send preamble with different version and build_id
  assert(serverio.write_blocking(frame.encode({
    ev = "relay",
    relay_version = "0.1.0",
    build_id = "testbuild123",
    pid = system.get_process_id(),
  }), 2000, fd))
  local r = frame.reader()
  -- Read relay_ok
  local ok_frame
  while not ok_frame do
    local d = serverio.read(4096, fd)
    if d and #d > 0 then r:feed(d); ok_frame = r:next() end
  end
  H.eq(ok_frame.ev, "relay_ok")
  -- Now send hello
  assert(serverio.write_blocking(frame.encode({
    ev = "hello",
    proto_version = server.proto_version,
  }), 2000, fd))
  local hello_frame
  while not hello_frame do
    local d = serverio.read(4096, fd)
    if d and #d > 0 then r:feed(d); hello_frame = r:next() end
  end
  H.eq(hello_frame.ev, "hello")
  H.ok(hello_frame.session ~= nil)
  H.ok(hello_frame.session.version_skew and hello_frame.session.version_skew:find("testbuild123"),
    "version_skew should contain build_id: " .. tostring(hello_frame.session.version_skew))
  serverio.close(fd)
  shutdown(c1, rep1.session.daemon_pid)
end)

H.test("session: extended environment subset and --forward-env forwarded", function()
  -- a plugin that shows the daemon's view of the connection's environment
  local plugdir = U.tmpdir("envplug")
  U.write_file(plugdir .. "/envdump.lua", [[
local server = require "thither"
server.register("envdump", { env = function(_, req) return req.conn and req.conn.env or {} end })
]])
  local env = {
    DISPLAY = ":99",
    WAYLAND_DISPLAY = "wayland-9",
    COLORTERM = "truecolor",
    TERM = "xterm-test",
    LANG = "C.UTF-8",
    LC_MESSAGES = "C.UTF-8",
    SSH_CONNECTION = "1.2.3.4 5 6.7.8.9 22",
    MY_CUSTOM_VAR = "custom_value",
    PREFIX_FOO = "foo_val",
    PREFIXNOT = "not forwarded",
    MY_CUSTOM_VAR2 = "not forwarded",
    IGNORED_SECRET = "secret",
  }
  -- what the relay and the daemon need to find their directories
  for _, k in ipairs({ "PATH", "HOME", "USER", "LOGNAME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME" }) do
    env[k] = os.getenv(k)
  end
  local sname = sname_of("ext_env")
  local c, rep = Client.connect({
    args = { "--session", sname, "--plugins", plugdir, "--forward-env", "MY_CUSTOM_VAR, PREFIX_*" },
    env = env,
  })
  local got = c:request("call", { service = "envdump", method = "env" })
  H.ok(type(got) == "table", "envdump: " .. tostring(got))
  for _, k in ipairs({ "DISPLAY", "WAYLAND_DISPLAY", "COLORTERM", "TERM", "LANG", "LC_MESSAGES",
                       "SSH_CONNECTION", "MY_CUSTOM_VAR", "PREFIX_FOO" }) do
    H.eq(got[k], env[k], "forwarded: " .. k)
  end
  for _, k in ipairs({ "PREFIXNOT", "MY_CUSTOM_VAR2", "IGNORED_SECRET", "PATH", "HOME" }) do
    H.eq(got[k], nil, "not forwarded: " .. k)
  end
  shutdown(c, rep.session.daemon_pid)
end)

H.test("session: runtime and state dirs come from XDG_RUNTIME_DIR / XDG_STATE_HOME without HOME or USER", function()
  local base = U.tmpdir("xdgdirs")
  local sname = sname_of("xdg")
  local c, rep = Client.connect({ args = { "--session", sname }, env = {
    PATH = os.getenv("PATH") or "/usr/bin:/bin",
    XDG_RUNTIME_DIR = base .. "/run",
    XDG_STATE_HOME = base .. "/state",
  } })
  H.eq(c:request("ping", { data = "x" }), "x")
  local st = serverfs.stat(base .. "/run/thither-server/" .. sname .. ".sock", true)
  H.ok(st and st.type == "socket", "the socket is under $XDG_RUNTIME_DIR")
  H.eq(serverfs.stat(base .. "/run/thither-server", true).mode % 512, 448, "runtime dir is 0700")
  H.ok(U.exists(base .. "/state/thither-server/" .. sname .. "/daemon.log"), "the daemon log is under $XDG_STATE_HOME")
  shutdown(c, rep.session.daemon_pid)
end)

H.test("session: relay half-close completes within 1s after stdin EOF", function()
  local sname = sname_of("halfclose")
  local c0, rep = Client.connect({ args = { "--session", sname } })
  local c = Client.spawn({ args = { "--session", sname } })
  local hello = c:hello()
  H.ok(hello and hello.ev == "hello" and not hello.err, "hello")
  local t0 = system.get_time()
  c.proc:close_stream(process.STREAM_STDIN)
  local code = c:wait_exit(5)
  local elapsed = system.get_time() - t0
  H.eq(code, 0, "relay exit status")
  H.ok(elapsed <= 2.5, string.format("relay should exit within a bounded time after stdin EOF, took %.2f s", elapsed))
  H.eq(c0:request("session_info").connections, 1, "the daemon dropped the half-closed connection")
  shutdown(c0, rep.session.daemon_pid)
end)

H.test("session: accept error back-off on EMFILE pauses listener", function()
  local sname = sname_of("emfile")
  local c, rep = Client.connect({ args = { "--session", sname } })
  local pid = rep.session.daemon_pid
  local statedir = session.state_dir(sname)
  local logpath = session.daemon_log(statedir)

  -- Count current fds of daemon
  local fds, lscode = U.sh("ls -1 /proc/" .. pid .. "/fd | wc -l")
  local num_fds = lscode == 0 and tonumber(fds:match("%d+"))
  local _, pcode = U.sh("command -v prlimit")
  local orig = pcode == 0 and (U.sh("prlimit --pid " .. pid .. " --nofile --output=SOFT --noheadings")):match("%S+")
  if not num_fds or num_fds == 0 or not orig then
    shutdown(c, pid)
    print("     (skipped: needs /proc and prlimit)")
    return
  end
  -- lower only the soft limit: raising a hard limit back needs privileges
  local _, lcode = U.sh(string.format("prlimit --pid %d --nofile=%d:", pid, num_fds))
  H.eq(lcode, 0, "prlimit lowering the soft limit")
  local c2 = Client.spawn({ args = { "--session", sname } })
  system.sleep(0.3)
  local log = U.read_file(logpath)
  H.ok(log and log:find("accept failed"), "daemon should log accept failure: " .. tostring(log))
  H.eq(c:request("ping", { data = "busy" }, 5), "busy", "the open connection is still served")
  local _, rcode = U.sh(string.format("prlimit --pid %d --nofile=%s:", pid, orig))
  H.eq(rcode, 0, "prlimit restoring the soft limit")
  -- once descriptors are available again the waiting relay gets through
  local hello = c2:hello()
  H.ok(hello and hello.ev == "hello" and not hello.err, "the waiting relay is served after the back-off: " .. c2.stderr)
  c2:close()
  shutdown(c, pid)
end)

H.test("cleanup: session tests", function() U.cleanup() end)
