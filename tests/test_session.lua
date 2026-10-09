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
  U.write_file(sock1, "agent1")
  U.write_file(sock2, "agent2")

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

  c1:request("session_shutdown")
  c1:close()
  os.remove(sock1)
  os.remove(sock2)
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
  local c, rep = Client.connect({ args = { "--session", sname, "--idle-exit", "1" } })
  local daemon_pid = rep.session.daemon_pid

  H.eq(c:request("ping"), true)
  c:close()

  -- Wait for 1 second idle exit + small buffer
  local deadline = system.get_time() + 3
  local dead = false
  while system.get_time() < deadline do
    local _, kcode = U.sh("kill -0 " .. daemon_pid)
    if kcode ~= 0 then dead = true; break end
    system.sleep(0.1)
  end
  H.ok(dead, "daemon should exit after idle timeout expires")
end)
