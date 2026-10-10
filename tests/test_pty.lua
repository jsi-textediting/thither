-- Unit tests for serverpty: PTY spawning, IO, resize, signals, reaping
local H = require "harness"
local U = require "util"
local serverpty = require "serverpty"
local serverio = require "serverio"

H.test("serverpty: open, read output, and reap exit", function()
  local res, err = serverpty.open({
    argv = { "sh", "-c", "echo pty_test_ok" },
    cols = 80,
    rows = 24,
  })
  H.ok(res, "serverpty.open failed: " .. tostring(err))
  H.ok(res.master > 0)
  H.ok(res.pid > 0)

  -- Wait for readable output via serverio.poll
  local out = ""
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    local p = serverio.poll({ [res.master] = "r" }, 100)
    if p[res.master] and p[res.master]:find("r") then
      local data = serverio.read(1024, res.master)
      if data and #data > 0 then
        out = out .. data
        if out:find("pty_test_ok") then break end
      end
    end
  end

  H.ok(out:find("pty_test_ok"), "expected pty output, got: " .. out)

  -- Reap child process
  local code, killed
  deadline = system.get_time() + 5
  while system.get_time() < deadline do
    code, killed = serverpty.reap(res.pid)
    if code ~= nil then break end
    system.sleep(0.01)
  end

  H.eq(code, 0)
  H.eq(killed, false)
  serverio.close(res.master)
end)

H.test("serverpty: resize and signal", function()
  local res, err = serverpty.open({
    argv = { "sh", "-c", "sleep 30" },
    cols = 80,
    rows = 24,
  })
  H.ok(res, "serverpty.open failed: " .. tostring(err))

  -- Resize window
  local ok = serverpty.resize(res.master, 120, 40)
  H.ok(ok)

  -- Proc comm: wait for child to exec
  local comm, deadline = nil, system.get_time() + 2
  while system.get_time() < deadline do
    comm = serverpty.proc_name(res.pid)
    if comm and comm ~= "thither-server" then break end
    system.sleep(0.01)
  end
  H.ok(comm == "sh" or comm == "sleep", "proc name should be sh or sleep, got: " .. tostring(comm))

  -- Send kill signal
  local sok = serverpty.signal(res.pid, "kill")
  H.ok(sok)

  local code, killed
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    code, killed = serverpty.reap(res.pid)
    if code ~= nil then break end
    system.sleep(0.01)
  end

  H.ok(killed == true or code == 137 or code == 9, "child should be killed")
  serverio.close(res.master)
end)

-- Reads the pty until `pat` shows up or the child closes it.
local function read_pty(master, pat)
  local out = ""
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    local p = serverio.poll({ [master] = "r" }, 100)
    if p[master] then
      local data = serverio.read(4096, master)
      if data == nil then break end
      out = out .. data
      if pat and out:find(pat) then break end
    end
  end
  return out
end

local function wait_exit(pid)
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    local code, killed = serverpty.reap(pid)
    if code ~= nil then return code, killed end
    system.sleep(0.01)
  end
end

H.test("serverpty: open of a missing program reports the exec failure", function()
  local res, err, code = serverpty.open({ argv = { "/nonexistent/thither-no-such-prog" } })
  H.eq(res, nil)
  H.eq(code, "ENOENT")
  H.ok(type(err) == "string" and #err > 0)

  res, err, code = serverpty.open({ argv = { "thither-no-such-prog-in-path" } })
  H.eq(res, nil)
  H.eq(code, "ENOENT")

  res, err, code = serverpty.open({ argv = { "sh", "-c", "true" }, cwd = "/nonexistent/dir" })
  H.eq(res, nil)
  H.eq(code, "ENOENT")
end)

local function sig_mask(status, field)
  return status:match(field .. ":%s*(%x+)")
end

H.test("serverpty: child gets default signal dispositions and an empty mask", function()
  -- the server itself ignores SIGPIPE: that must not leak into the child
  local own = U.read_file("/proc/self/status")
  local own_ign = own and sig_mask(own, "SigIgn")
  H.ok(own_ign and own_ign:find("[1-9a-f]"), "test process ignores SIGPIPE: " .. tostring(own_ign))

  local res, err = serverpty.open({ argv = { "cat", "/proc/self/status" } })
  H.ok(res, "serverpty.open failed: " .. tostring(err))
  local out = read_pty(res.master, "SigCgt:%s*%x+")
  local ign, blk = sig_mask(out, "SigIgn"), sig_mask(out, "SigBlk")
  H.ok(ign and not ign:find("[1-9a-f]"), "child SigIgn must be empty, got: " .. tostring(ign))
  H.ok(blk and not blk:find("[1-9a-f]"), "child SigBlk must be empty, got: " .. tostring(blk))
  wait_exit(res.pid)
  serverio.close(res.master)
end)

H.test("serverpty: env accepts array-style entries and skips odd keys", function()
  local res, err = serverpty.open({
    argv = { "sh", "-c", 'echo "<$FOO_ARR|$BAR_KEY|$NUM_VAL|$TERM|$HOME>"' },
    term = "dumb",
    env = {
      "FOO_ARR=arr_val",
      "noequals",
      [2.5] = "ODD=1",
      [true] = "x",
      BAR_KEY = "kv",
      NUM_VAL = 42,
      BAD = {},
    },
  })
  H.ok(res, "serverpty.open failed: " .. tostring(err))
  local out = read_pty(res.master, "<[^>]*>")
  local want = "<arr_val|kv|42|dumb|" .. (os.getenv("HOME") or "") .. ">"
  H.ok(out:find(want, 1, true), "expected " .. want .. ", got: " .. out)
  H.eq(wait_exit(res.pid), 0)
  serverio.close(res.master)

  -- an env TERM wins over opts.term
  res = serverpty.open({ argv = { "sh", "-c", 'echo "<$TERM>"' }, term = "dumb", env = { TERM = "vt100" } })
  H.ok(res)
  out = read_pty(res.master, "<[^>]*>")
  H.ok(out:find("<vt100>", 1, true), "env TERM: " .. out)
  wait_exit(res.pid)
  serverio.close(res.master)
end)

H.test("serverpty: pipe mode (tty=false) merges stdout and stderr", function()
  local res, err = serverpty.open({
    argv = { "sh", "-c", 'echo from_stdout; echo from_stderr >&2' },
    tty = false,
  })
  H.ok(res, "serverpty.open with tty=false failed: " .. tostring(err))
  H.eq(res.tty, false)
  H.ok(res.master > 0)
  H.ok(res.fd == res.master)

  local out = read_pty(res.master, "from_stderr")
  H.ok(out:find("from_stdout"), "should contain stdout: " .. tostring(out))
  H.ok(out:find("from_stderr"), "should contain stderr: " .. tostring(out))

  -- Resize on a pipe descriptor fails
  local r_ok, r_err = serverpty.resize(res.master, 100, 30)
  H.eq(r_ok, nil, "resize on pipe should fail")
  H.ok(r_err ~= nil)

  H.eq(wait_exit(res.pid), 0)
  serverio.close(res.master)
end)

H.test("serverpty: pipe mode process group receives signal", function()
  local res, err = serverpty.open({
    argv = { "sh", "-c", 'sleep 30' },
    tty = false,
  })
  H.ok(res)
  H.ok(serverpty.signal(res.pid, "term"))
  local code, killed = wait_exit(res.pid)
  H.ok(code == 143 or killed == true, "child should be terminated by signal")
  serverio.close(res.master)
end)

