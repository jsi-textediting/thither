-- Unit tests for serverpty: PTY spawning, IO, resize, signals, reaping
local H = require "harness"
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
