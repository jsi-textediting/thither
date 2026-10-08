-- exec (streaming, stdin, kill, cancel, flow control) and watch tests.
local H = require "harness"
local U = require "util"
local Client = require "client"
local mp = require "thither.msgpack"

local function exit_of(c, sid, timeout)
  return c:wait_event(function(m) return m.ev == "exit" and m.stream == sid end, timeout or 10)
end

--- Collects stdout/stderr of a stream until it exits, acking as it goes.
local function collect(c, sid, timeout)
  local out, err = {}, {}
  local deadline = system.get_time() + (timeout or 20)
  while system.get_time() < deadline do
    local m = c:recv(0.5)
    if m then
      if m.stream == sid and m.ev == "stdout" then
        out[#out + 1] = m.data
        c:send({ op = "ack", args = { stream = sid, n = #m.data } })
      elseif m.stream == sid and m.ev == "stderr" then
        err[#err + 1] = m.data
        c:send({ op = "ack", args = { stream = sid, n = #m.data } })
      elseif m.stream == sid and m.ev == "exit" then
        return table.concat(out), table.concat(err), m
      else
        c.events[#c.events + 1] = m
      end
    end
  end
  error("timeout collecting stream " .. sid)
end

H.test("exec: stdout, stderr and exit code are streamed", function()
  local c = Client.connect()
  local r = c:request("exec", { argv = { "sh", "-c", "echo out; echo err >&2; exit 3" }, stdin = false })
  H.ok(r.stream and r.pid > 0)
  local out, err, ex = collect(c, r.stream)
  H.eq(out, "out\n"); H.eq(err, "err\n"); H.eq(ex.code, 3); H.eq(ex.killed, false)
  c:close()
end)

H.test("exec: cwd, env and merged stderr", function()
  local dir = U.tmpdir("exec")
  local c = Client.connect()
  local r = c:request("exec", { argv = { "sh", "-c", "pwd; echo $THITHER_FOO; echo e >&2" }, cwd = dir,
                                env = { THITHER_FOO = "bar baz" }, merge_stderr = true, stdin = false })
  local out, err, ex = collect(c, r.stream)
  H.eq(out, dir .. "\nbar baz\ne\n"); H.eq(err, ""); H.eq(ex.code, 0)
  c:close()
end)

H.test("exec: failures to start are reported", function()
  local c = Client.connect()
  local _, err = c:request("exec", { argv = { "/no/such/program" } })
  H.eq(err.code, "exec_failed")
  _, err = c:request("exec", { argv = {} })
  H.eq(err.code, "bad_request")
  _, err = c:request("exec", { argv = { "true" }, cwd = "/no/such/dir" })
  H.eq(err.code, "exec_failed")
  _, err = c:request("exec", { argv = { "true" }, env = { ["A=B"] = "x" } })
  H.eq(err.code, "bad_request")
  c:close()
end)

H.test("exec: stdin round trip with cat, byte exact", function()
  local c = Client.connect()
  local r = c:request("exec", { argv = { "cat" } })
  local all = {}
  for i = 0, 255 do all[#all + 1] = string.char(i) end
  local payload = table.concat(all):rep(4000)   -- ~1 MB incl. NUL and 0xff
  local pos, sent = 1, {}
  -- feed in 64 KiB pieces, collecting output as it arrives
  local got = {}
  local pending = 0
  local ids = {}
  while pos <= #payload do
    local piece = payload:sub(pos, pos + 65535)
    pos = pos + #piece
    ids[#ids + 1] = c:send_request("stdin", { stream = r.stream, data = mp.bin(piece), close = pos > #payload })
  end
  local deadline = system.get_time() + 30
  local exited
  while not exited and system.get_time() < deadline do
    local m = c:recv(0.5)
    if m then
      if m.ev == "stdout" and m.stream == r.stream then
        got[#got + 1] = m.data
        c:send({ op = "ack", args = { stream = r.stream, n = #m.data } })
      elseif m.ev == "exit" and m.stream == r.stream then
        exited = m
      end
    end
  end
  H.ok(exited, "cat did not exit")
  H.ok(table.concat(got) == payload, "echoed data differs (" .. #table.concat(got) .. " vs " .. #payload .. ")")
  H.eq(exited.code, 0)
  c:close()
end)

H.test("exec: kill terminates a child", function()
  local c = Client.connect()
  local r = c:request("exec", { argv = { "sleep", "60" } })
  local t0 = system.get_time()
  H.ok(c:request("kill", { stream = r.stream }))
  local ex = exit_of(c, r.stream, 5)
  H.ok(ex, "no exit event")
  H.eq(ex.killed, true)
  H.ok(system.get_time() - t0 < 3)
  local _, err = c:request("kill", { stream = r.stream })
  H.eq(err.code, "no_stream")
  -- SIGKILL for a child that ignores SIGTERM
  r = c:request("exec", { argv = { "sh", "-c", "trap '' TERM; while :; do sleep 1; done" } })
  system.sleep(0.3)
  c:request("kill", { stream = r.stream, signal = "term" })
  system.sleep(0.3)
  H.ok(c:request("stat", { path = "/" }), "server still responsive")
  c:request("kill", { stream = r.stream, signal = "kill" })
  H.ok(exit_of(c, r.stream, 5), "SIGKILL did not end the child")
  c:close()
end)

H.test("exec: cancelling the exec request terminates the child", function()
  local c = Client.connect()
  local id = c:send_request("exec", { argv = { "sleep", "60" } })
  local r = c:wait_response(id)
  c:send({ cancel = id })
  local ex = exit_of(c, r.stream, 5)
  H.ok(ex, "cancel did not end the child")
  H.eq(ex.killed, true)
  c:close()
end)

H.test("process: terminate reaches the process group after the leader exited", function()
  -- (the server ends an exec stream with its leader: this is the process API)
  -- the shell exits at once, its background job keeps the stdout pipe open
  local p = process.start({ "sh", "-c", "sleep 60 & echo $!" })
  local out, deadline = "", system.get_time() + 5
  while not out:find("\n", 1, true) and system.get_time() < deadline do
    out = out .. (p:read_stdout() or "")
    system.sleep(0.01)
  end
  local pid = H.ok(tonumber(out:match("%d+")), "no pid")
  while p:running() and system.get_time() < deadline do system.sleep(0.01) end
  H.ok(not p:running(), "the shell did not exit")
  p:terminate()
  deadline = system.get_time() + 3
  local _, alive = U.sh("kill -0 " .. pid)
  while alive == 0 and system.get_time() < deadline do
    system.sleep(0.05)
    _, alive = U.sh("kill -0 " .. pid)
  end
  if alive == 0 then U.sh("kill " .. pid) end
  H.ok(alive ~= 0, "the background job survived terminate()")
end)

H.test("exec: output is flow controlled by the window", function()
  local c = Client.connect()
  local r = c:request("exec", { argv = { "head", "-c", "3000000", "/dev/zero" }, window = 65536, stdin = false })
  system.sleep(0.5)
  c:pump()
  local received = 0
  for _, m in ipairs(c.inbox) do if m.ev == "stdout" then received = received + #m.data end end
  H.ok(received <= 65536, "sent more than the window: " .. received)
  H.ok(received > 0, "nothing sent")
  -- now consume everything
  local total = received
  for _, m in ipairs(c.inbox) do
    if m.ev == "stdout" then c:send({ op = "ack", args = { stream = r.stream, n = #m.data } }) end
  end
  c.inbox = {}
  local out, _, ex = collect(c, r.stream, 30)
  H.eq(total + #out, 3000000)
  H.eq(ex.code, 0)
  c:close()
end)

H.test("exec: many concurrent children", function()
  local c = Client.connect()
  local streams = {}
  for i = 1, 20 do
    streams[i] = c:request("exec", { argv = { "sh", "-c", "echo n" .. i }, stdin = false }).stream
  end
  local seen = {}
  local deadline = system.get_time() + 20
  local done = 0
  local function handle(m)
    if m and m.ev == "stdout" then seen[m.stream] = (seen[m.stream] or "") .. m.data end
    if m and m.ev == "exit" then done = done + 1 end
  end
  -- events that arrived while the exec responses were awaited
  for _, m in ipairs(c:take_events()) do handle(m) end
  while done < 20 and system.get_time() < deadline do
    handle(c:recv(0.5))
  end
  H.eq(done, 20)
  for i, sid in ipairs(streams) do H.eq(seen[sid], "n" .. i .. "\n") end
  c:close()
end)

H.test("exec: children die with the server connection", function()
  local dir = U.tmpdir("orphan")
  local c = Client.connect()
  local r = c:request("exec", { argv = { "sh", "-c", "echo $$ > " .. dir .. "/pid; exec sleep 120" }, stdin = false })
  local deadline = system.get_time() + 5
  -- wait for the whole line: the file exists before echo has written to it
  while not (U.read_file(dir .. "/pid") or ""):match("%d+\n") and system.get_time() < deadline do system.sleep(0.05) end
  local pid = U.read_file(dir .. "/pid"):gsub("%s+", "")
  H.ok(tonumber(pid))
  H.ok(U.exists("/proc/" .. pid), "child should be running")
  H.eq(c:close(), 0)
  deadline = system.get_time() + 5
  while system.get_time() < deadline do
    local stat = U.read_file("/proc/" .. pid .. "/stat")
    if not stat or stat:match("^%d+ %b() Z") then break end
    system.sleep(0.05)
  end
  local stat = U.read_file("/proc/" .. pid .. "/stat")
  H.ok(not stat or stat:match("^%d+ %b() Z"), "child survived the server")
end)

H.test("exec: SIGTERM to the server ends the session and kills the children", function()
  local dir = U.tmpdir("sigterm")
  local c, hello = Client.connect()
  c:request("exec", { argv = { "sh", "-c", "echo $$ > " .. dir .. "/pid; exec sleep 120" }, stdin = false })
  local deadline = system.get_time() + 5
  -- wait for the whole line: the file exists before echo has written to it
  while not (U.read_file(dir .. "/pid") or ""):match("%d+\n") and system.get_time() < deadline do system.sleep(0.05) end
  local pid = U.read_file(dir .. "/pid"):gsub("%s+", "")
  H.ok(tonumber(pid))
  H.ok(U.exists("/proc/" .. pid))
  U.sh("kill -TERM " .. hello.pid)
  H.eq(c:wait_exit(5), 0)
  deadline = system.get_time() + 5
  while system.get_time() < deadline do
    local stat = U.read_file("/proc/" .. pid .. "/stat")
    if not stat or stat:match("^%d+ %b() Z") then break end
    system.sleep(0.05)
  end
  local stat = U.read_file("/proc/" .. pid .. "/stat")
  H.ok(not stat or stat:match("^%d+ %b() Z"), "child survived SIGTERM of the server")
end)

H.test("exec: the protocol channel is not inherited by children", function()
  local c = Client.connect()
  -- a child that would write to fd 1 must not reach the protocol stream
  local r = c:request("exec", { argv = { "sh", "-c", "echo to-stdout; ls /proc/self/fd | wc -l" }, stdin = false })
  local out, _, ex = collect(c, r.stream)
  H.ok(out:find("to-stdout", 1, true))
  H.eq(ex.code, 0)
  H.eq(c:request("ping", { data = "alive" }), "alive")
  c:close()
end)

H.test("exec: a child does not inherit the pipes of another child", function()
  local c = Client.connect()
  local a = c:request("exec", { argv = { "cat" } })
  -- started second, b would hold a's stdin write end without close-on-exec
  local b = c:request("exec", { argv = { "sleep", "30" } })
  H.ok(c:request("stdin", { stream = a.stream, data = "x", close = true }))
  local out, _, ex = collect(c, a.stream, 5)
  H.eq(out, "x"); H.eq(ex.code, 0)
  c:request("kill", { stream = b.stream, signal = "kill" })
  H.ok(exit_of(c, b.stream, 5))
  c:close()
end)

H.test("exec: env is merged into the environment, PATH still works", function()
  local c = Client.connect()
  local r = c:request("exec", { argv = { "sh", "-c", "echo $THITHER_A-$THITHER_B; test -n \"$PATH\" && echo path" },
                                env = { THITHER_A = "1", THITHER_B = "x=y" }, stdin = false })
  local out, _, ex = collect(c, r.stream)
  H.eq(out, "1-x=y\npath\n"); H.eq(ex.code, 0)
  -- overriding an inherited variable replaces it
  r = c:request("exec", { argv = { "sh", "-c", "echo $HOME" }, env = { HOME = "/tmp/thither-home" }, stdin = false })
  out = collect(c, r.stream)
  H.eq(out, "/tmp/thither-home\n")
  c:close()
end)

H.test("exec: a child that closes its stdin keeps running", function()
  local c = Client.connect()
  local r = c:request("exec", { argv = { "sh", "-c", "exec 0<&-; sleep 0.5; echo done" } })
  system.sleep(0.2)
  -- the write fails with EPIPE; that must not terminate the child
  c:send({ op = "stdin", args = { stream = r.stream, data = "ignored" } })
  local out, _, ex = collect(c, r.stream, 10)
  H.eq(out, "done\n"); H.eq(ex.code, 0); H.eq(ex.killed, false)
  c:close()
end)

H.test("exec: cancel of a reused id does not hit an old exec", function()
  local c = Client.connect()
  local id = c:send_request("exec", { argv = { "sleep", "30" } })
  local r = c:wait_response(id)
  -- reuse the id (allowed once answered), then cancel it
  c:send({ id = id, op = "ping" })
  H.eq(c:wait_response(id), true)
  c:send({ cancel = id })
  system.sleep(0.3)
  c:pump()
  H.ok(not c:take_events(function(m) return m.ev == "exit" and m.stream == r.stream end)[1],
       "the old exec was cancelled")
  c:request("kill", { stream = r.stream, signal = "kill" })
  H.ok(exit_of(c, r.stream, 5))
  c:close()
end)

-- watch -------------------------------------------------------------------

local function watch_event(c, wid, timeout)
  return c:wait_event(function(m) return (m.ev == "watch" or m.ev == "overflow") and m.watch == wid end, timeout or 5)
end

H.test("watch: file creation, modification and deletion are reported", function()
  local dir = U.tmpdir("watch")
  local c = Client.connect()
  local w = c:request("watch", { path = dir, debounce_ms = 30 })
  H.ok(w.watch and w.dirs == 1)
  U.write_file(dir .. "/a.txt", "1")
  local ev = watch_event(c, w.watch)
  H.ok(ev, "no event for creation")
  H.eq(ev.ev, "watch"); H.eq(ev.paths, { dir })
  U.write_file(dir .. "/a.txt", "22")
  ev = watch_event(c, w.watch)
  H.ok(ev, "no event for modification"); H.eq(ev.paths, { dir })
  os.remove(dir .. "/a.txt")
  ev = watch_event(c, w.watch)
  H.ok(ev, "no event for deletion")
  -- bursts are coalesced into one event
  for i = 1, 50 do U.write_file(dir .. "/f" .. i, "x") end
  ev = watch_event(c, w.watch)
  H.ok(ev)
  system.sleep(0.2)
  c:pump()
  local extra = c:take_events(function(m) return m.ev == "watch" or m.ev == "overflow" end)
  H.ok(#extra <= 1, "burst split into too many events: " .. #extra)
  -- unwatch stops events
  H.ok(c:request("unwatch", { watch = w.watch }))
  U.write_file(dir .. "/after", "x")
  system.sleep(0.4)
  c:pump()
  H.eq(#c:take_events(function(m) return m.ev == "watch" or m.ev == "overflow" end), 0)
  H.ok(c:request("unwatch", { watch = w.watch }), "unwatch is idempotent")
  c:close()
end)

H.test("watch: recursive watches follow new subdirectories", function()
  local dir = U.tmpdir("rwatch")
  U.sh("mkdir -p " .. dir .. "/a/b")
  local c = Client.connect()
  local w = c:request("watch", { path = dir, recursive = true, debounce_ms = 30 })
  H.eq(w.dirs, 3); H.eq(w.truncated, false)
  U.write_file(dir .. "/a/b/deep.txt", "x")
  local ev = watch_event(c, w.watch)
  H.ok(ev); H.eq(ev.paths, { dir .. "/a/b" })
  U.sh("mkdir " .. dir .. "/newdir")
  ev = watch_event(c, w.watch)
  H.ok(ev); H.eq(ev.paths, { dir })
  system.sleep(0.1)
  c:pump()
  c:take_events(function(m) return m.ev == "watch" end)
  U.write_file(dir .. "/newdir/inside.txt", "x")
  ev = watch_event(c, w.watch)
  H.ok(ev, "the new directory is not watched"); H.eq(ev.paths, { dir .. "/newdir" })
  c:close()
end)

H.test("watch: re-created and renamed directories are watched again", function()
  local dir = U.tmpdir("rewatch")
  U.sh("mkdir -p " .. dir .. "/sub")
  local c = Client.connect()
  local w = c:request("watch", { path = dir, recursive = true, debounce_ms = 30 })
  H.eq(w.dirs, 2)
  local function settle()
    system.sleep(0.15)
    c:pump()
    c:take_events(function(m) return m.ev == "watch" or m.ev == "overflow" end)
  end
  -- remove and re-create with the same name: the new directory is a new inode
  U.sh("rmdir " .. dir .. "/sub")
  H.ok(watch_event(c, w.watch))
  U.sh("mkdir " .. dir .. "/sub")
  H.ok(watch_event(c, w.watch))
  settle()
  U.write_file(dir .. "/sub/f", "x")
  local ev = watch_event(c, w.watch)
  H.ok(ev, "the re-created directory is not watched"); H.eq(ev.paths, { dir .. "/sub" })
  settle()
  -- a rename keeps the inode: events are reported under the new name
  U.sh("mv " .. dir .. "/sub " .. dir .. "/moved")
  H.ok(watch_event(c, w.watch))
  settle()
  U.write_file(dir .. "/moved/g", "x")
  ev = watch_event(c, w.watch)
  H.ok(ev, "the renamed directory is not watched"); H.eq(ev.paths, { dir .. "/moved" })
  c:close()
end)

H.test("watch: deep trees are released and watched again, each watch keeps its own paths", function()
  local dir = U.tmpdir("deepwatch")
  U.sh("mkdir -p " .. dir .. "/t/a/b/c " .. dir .. "/t/x/y")
  local c = Client.connect()
  local function settle()
    system.sleep(0.15)
    c:pump()
    c:take_events(function(m) return m.ev == "watch" or m.ev == "overflow" end)
  end
  local w = c:request("watch", { path = dir, recursive = true, debounce_ms = 30 })
  H.eq(w.dirs, 7)
  -- a second watch on a subdirectory shares its inodes with the first one
  local w2 = c:request("watch", { path = dir .. "/t/x", recursive = true, debounce_ms = 30 })
  H.eq(w2.dirs, 2)
  U.sh("rm -rf " .. dir .. "/t/a")
  H.ok(watch_event(c, w.watch))
  settle()
  U.sh("mkdir -p " .. dir .. "/t/a/b/c")
  H.ok(watch_event(c, w.watch))
  settle()
  U.write_file(dir .. "/t/a/b/c/f", "x")
  local ev = watch_event(c, w.watch)
  H.ok(ev, "the re-created tree is not watched"); H.eq(ev.paths, { dir .. "/t/a/b/c" })
  settle()
  -- renamed in the first watch only: the second one still knows it as x/y
  U.sh("mkdir " .. dir .. "/moved && mv " .. dir .. "/t/x/y " .. dir .. "/moved/y && mkdir " .. dir .. "/t/x/y")
  settle()
  local _, err = c:request("unwatch", { watch = w2.watch })
  H.eq(err, nil)
  w2 = c:request("watch", { path = dir .. "/t/x", recursive = true, debounce_ms = 30 })
  settle()
  U.write_file(dir .. "/moved/y/g", "x")
  ev = watch_event(c, w.watch)
  H.ok(ev, "the moved directory is not watched"); H.eq(ev.paths, { dir .. "/moved/y" })
  U.write_file(dir .. "/t/x/y/h", "x")
  ev = watch_event(c, w2.watch)
  H.ok(ev, "no event for the second watch"); H.eq(ev.paths, { dir .. "/t/x/y" })
  c:close()
end)

H.test("watch: a renamed directory shared by two watches is reported under each one's path", function()
  local dir = U.tmpdir("sharedwatch")
  U.sh("mkdir -p " .. dir .. "/p/s")
  local c = Client.connect()
  local function settle()
    system.sleep(0.15)
    c:pump()
    c:take_events(function(m) return m.ev == "watch" or m.ev == "overflow" end)
  end
  -- w1 watches p/s itself (not recursive), w2 watches the whole tree
  local w1 = c:request("watch", { path = dir .. "/p/s", debounce_ms = 30 })
  local w2 = c:request("watch", { path = dir, recursive = true, debounce_ms = 30 })
  U.sh("mv " .. dir .. "/p/s " .. dir .. "/p/r")
  H.ok(watch_event(c, w2.watch))
  settle()
  U.write_file(dir .. "/p/r/f", "x")
  local ev2 = watch_event(c, w2.watch)
  H.ok(ev2); H.eq(ev2.paths, { dir .. "/p/r" })
  local ev1 = watch_event(c, w1.watch)
  H.ok(ev1); H.eq(ev1.paths, { dir .. "/p/s" })
  c:close()
end)

H.test("watch: too many changed directories produce an overflow event", function()
  local dir = U.tmpdir("overflow")
  for i = 1, 6 do U.sh("mkdir -p " .. dir .. "/d" .. i) end
  local c = Client.connect()
  local w = c:request("watch", { path = dir, recursive = true, debounce_ms = 100, max_pending = 3 })
  H.eq(w.dirs, 7)
  for i = 1, 6 do U.write_file(dir .. "/d" .. i .. "/f", "x") end
  local ev = watch_event(c, w.watch)
  H.ok(ev, "no event"); H.eq(ev.ev, "overflow")
  -- afterwards a small change is reported normally again
  system.sleep(0.2)
  c:pump()
  c:take_events(function(m) return m.ev == "watch" or m.ev == "overflow" end)
  U.write_file(dir .. "/d1/g", "x")
  ev = watch_event(c, w.watch)
  H.ok(ev); H.eq(ev.ev, "watch"); H.eq(ev.paths, { dir .. "/d1" })
  c:close()
end)

H.test("watch: errors", function()
  local c = Client.connect()
  local _, err = c:request("watch", { path = "/no/such/dir" })
  H.eq(err.code, "ENOENT")
  c:close()
end)

H.test("cleanup: exec/watch tests", function() U.cleanup() end)
