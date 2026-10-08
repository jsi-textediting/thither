-- exec ops: exec, stdin, stdin_close, kill, ack.
--
-- exec starts a child and returns { stream = <id>, pid = <n> } at once; output
-- and the exit status arrive as events:
--   { ev = "stdout", stream = id, data = <bin> }
--   { ev = "stderr", stream = id, data = <bin> }
--   { ev = "exit",   stream = id, code = <int>, killed = <bool> }
-- Output is flow controlled: the server sends at most `window` unacknowledged
-- bytes per stream (default 1 MiB, 0 = unlimited); the client replies with
-- `ack {stream, n}` as it consumes data. A pending exec request that is
-- cancelled ({cancel = id}) terminates its child.
local msgpack = require "thither.msgpack"

return function(server)
  local ops = server.ops
  local raise = server.raise

  local DEFAULT_WINDOW = 1024 * 1024
  local READ_SIZE = 65536
  local STDIN_HIGH_WATER = 1024 * 1024

  local streams, nstreams, next_sid = {}, 0, 1

  local function build_env(env)
    if env == nil then return nil end
    if type(env) ~= "table" then raise("bad_request", "env must be a map of strings") end
    local parts = {}
    for k, v in pairs(env) do
      if type(k) ~= "string" or type(v) ~= "string" or k == "" or k:find("[=%z]") or v:find("%z") then
        raise("bad_request", "invalid environment entry")
      end
      parts[#parts + 1] = k .. "=" .. v .. "\0"
    end
    local blob = table.concat(parts)
    return function() return blob end
  end

  -- args: argv, cwd, env, stdin (default true), merge_stderr, window
  ops.exec = function(a, req)
    local argv = a.argv
    if type(argv) ~= "table" or #argv == 0 then raise("bad_request", "argv must be a non-empty list") end
    local cmd = {}
    for i = 1, #argv do
      if type(argv[i]) ~= "string" or argv[i]:find("%z") then raise("bad_request", "argv entries must be strings") end
      cmd[i] = argv[i]
    end
    if a.cwd ~= nil and (type(a.cwd) ~= "string" or a.cwd:find("%z")) then raise("bad_request", "bad cwd") end
    local options = { cwd = a.cwd, env = build_env(a.env) }
    if a.stdin == false then options.stdin = process.REDIRECT_DISCARD end
    if a.merge_stderr then options.stderr = process.REDIRECT_STDOUT end
    local window = a.window
    if window == nil then window = DEFAULT_WINDOW end
    if math.type(window) ~= "integer" or window < 0 then raise("bad_request", "window must be an integer >= 0") end

    local ok, proc = pcall(process.start, cmd, options)
    if not ok then
      raise("exec_failed", (tostring(proc):gsub("^[^:]*:%d+: ", "")))
    end
    local sid = next_sid
    next_sid = next_sid + 1
    streams[sid] = {
      id = sid, proc = proc, req_id = req.id,
      credit = window == 0 and math.huge or window, window = window,
      inq = {}, inq_bytes = 0, close_stdin = false, stdin_closed = a.stdin == false,
      killed = false, idle = 0,
    }
    nstreams = nstreams + 1
    return { stream = sid, pid = proc:pid() }
  end

  local function get_stream(a)
    local st = streams[a.stream]
    if not st then raise("no_stream", "unknown or finished stream: " .. tostring(a.stream)) end
    return st
  end

  -- args: stream, data, close   (replies once the data is written to the child)
  ops.stdin = function(a, req)
    local st = get_stream(a)
    if st.stdin_closed or st.close_stdin then raise("stdin_closed", "stdin is closed") end
    local data = a.data
    if data ~= nil then
      if type(data) ~= "string" then raise("bad_request", "data must be a string") end
      if #data > 0 then
        st.inq[#st.inq + 1] = data
        st.inq_bytes = st.inq_bytes + #data
      end
    end
    if a.close then st.close_stdin = true end
    while st.inq_bytes > STDIN_HIGH_WATER and streams[st.id] and not st.stdin_closed do
      req:yield()
    end
    return true
  end

  ops.stdin_close = function(a)
    local st = get_stream(a)
    st.close_stdin = true
    return true
  end

  local signals = { term = "terminate", kill = "kill", int = "interrupt" }

  -- args: stream, signal ("term" (default) | "kill" | "int")
  ops.kill = function(a)
    local st = get_stream(a)
    local method = signals[a.signal or "term"]
    if not method then raise("bad_request", "signal must be term, kill or int") end
    st.killed = true
    st.proc[method](st.proc)
    return true
  end

  -- args: stream, n   (bytes consumed by the client)
  ops.ack = function(a)
    local st = streams[a.stream]
    if st and st.credit ~= math.huge then
      if math.type(a.n) ~= "integer" or a.n < 0 then raise("bad_request", "n must be a non-negative integer") end
      st.credit = math.min(st.credit + a.n, st.window)
    end
    return true
  end

  table.insert(server.cancel_hooks, function(id)
    for _, st in pairs(streams) do
      if st.req_id == id and st.req_id ~= nil then
        st.killed = true
        st.proc:terminate()
      end
    end
  end)

  -- once the client reuses the id of an exec request for a new request, a
  -- cancel of that id refers to the new request, not to the child
  table.insert(server.start_hooks, function(id)
    for _, st in pairs(streams) do
      if st.req_id == id then st.req_id = nil end
    end
  end)

  local function pump_stdin(st)
    if st.stdin_closed then return false end
    local activity = false
    while #st.inq > 0 do
      local chunk = st.inq[1]
      local ok, n = pcall(st.proc.write, st.proc, chunk)
      if not ok then
        -- the child closed its stdin (or went away): drop pending input,
        -- the child itself keeps running
        st.inq, st.inq_bytes, st.stdin_closed = {}, 0, true
        pcall(st.proc.close_stream, st.proc, process.STREAM_STDIN)
        return true
      end
      if n == nil or n == 0 then break end
      activity = true
      st.inq_bytes = st.inq_bytes - n
      if n < #chunk then
        st.inq[1] = chunk:sub(n + 1)
        break
      end
      table.remove(st.inq, 1)
    end
    if st.close_stdin and #st.inq == 0 and not st.stdin_closed then
      pcall(st.proc.close_stream, st.proc, process.STREAM_STDIN)
      st.stdin_closed = true
      activity = true
    end
    return activity
  end

  local function pump_output(st, which, stream_id)
    local got = false
    for _ = 1, 4 do
      if st.credit <= 0 then break end
      local n = math.min(READ_SIZE, st.credit)
      local data = st.proc:read(stream_id, n)
      if not data or data == "" then break end
      st.credit = st.credit - #data
      server.send({ ev = which, stream = st.id, data = msgpack.bin(data) })
      got = true
    end
    return got
  end

  local function finished(st)
    streams[st.id] = nil
    nstreams = nstreams - 1
    local code = st.proc:returncode()
    server.send({ ev = "exit", stream = st.id, code = code or -1, killed = st.killed })
  end

  table.insert(server.tickers, function()
    if nstreams == 0 then return nil end
    local hint = 50
    for _, st in pairs(streams) do
      local active = pump_stdin(st)
      active = pump_output(st, "stdout", process.STREAM_STDOUT) or active
      active = pump_output(st, "stderr", process.STREAM_STDERR) or active
      if not st.proc:running() then
        -- drain what is left; wait for acks if the window is exhausted
        local more = pump_output(st, "stdout", process.STREAM_STDOUT)
        more = pump_output(st, "stderr", process.STREAM_STDERR) or more
        if not more and st.credit > 0 then finished(st) end
        active = true
      end
      if active then st.idle = 0 else st.idle = math.min(st.idle + 1, 20) end
      local h = active and 0 or (1 + st.idle)
      if h < hint then hint = h end
    end
    return hint
  end)

  table.insert(server.hooks.on_shutdown, function()
    for _, st in pairs(streams) do
      pcall(st.proc.kill, st.proc)
    end
  end)
end
