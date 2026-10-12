-- Session paths and security validation for thither-server
local serverfs = require "serverfs"

local session = {}

-- after EOF on a daemon connection (a relay half-closes after its stdin EOF):
-- how long its requests in flight may still run and their replies drain. The
-- relay waits this long (plus a margin) for the daemon to close.
session.EOF_DRAIN_MS = 5000

function session.validate_name(name)
  name = name or "default"
  if type(name) ~= "string" or not name:match("^[%w._%-]+$") or #name < 1 or #name > 32 then
    return nil, "invalid session name: " .. tostring(name)
  end
  return name
end

--- Makes sure `dir` is a private directory: not a symlink (lstat), owned by
--- us, mode 0700. A missing directory is created (with its parents); only a
--- directory created here may be chmod'ed (the umask may have narrowed the
--- mode), an existing one with the wrong owner or mode is refused.
function session.verify_dir(dir)
  local uid = serverfs.ids().uid
  local st = serverfs.stat(dir, true)
  local created = false
  if not st then
    local ok, code, msg = serverfs.mkdir(dir, 448, true)
    if not ok and code ~= "EEXIST" then
      return nil, string.format("cannot create directory %s: %s", tostring(dir), tostring(msg or code))
    end
    created = ok and true or false
    st = serverfs.stat(dir, true)
    if not st then
      return nil, "cannot stat directory: " .. tostring(dir)
    end
  end
  if st.type ~= "dir" or st.is_link then
    return nil, "not a directory, or a symlink: " .. tostring(dir)
  end
  if st.uid ~= uid then
    return nil, string.format("directory not owned by current user (owner %s, expected %s): %s",
      tostring(st.uid), tostring(uid), tostring(dir))
  end
  if (st.mode % 512) ~= 448 then
    if created then
      serverfs.chmod(dir, 448)
      st = serverfs.stat(dir, true)
    end
    if not st or (st.mode % 512) ~= 448 then
      return nil, string.format("directory mode is %03o, not 0700 (fix with chmod 700): %s",
        st and (st.mode % 512) or 0, tostring(dir))
    end
  end
  return true
end

--- Checks the socket path before it is connected to or removed: nothing
--- there (true, "absent"), or a unix socket owned by us (true, "socket").
--- Anything else (a symlink, a regular file, someone else's socket) is
--- refused: nil, message. serverfs.stat reports sockets as "socket" or, in
--- builds that do not distinguish them, "other".
function session.check_socket(path)
  local st = serverfs.stat(path, true)
  if not st then return true, "absent" end
  if st.is_link or st.type ~= "socket" then
    return nil, "not a socket: " .. tostring(path)
  end
  if st.uid ~= serverfs.ids().uid then
    return nil, string.format("socket not owned by current user (owner %s): %s", tostring(st.uid), tostring(path))
  end
  return true, "socket"
end

function session.runtime_dir()
  local r = os.getenv("XDG_RUNTIME_DIR")
  local rundir
  if r and r ~= "" then
    rundir = r .. "/thither-server"
  else
    rundir = string.format("/tmp/thither-server-%d", serverfs.ids().uid)
  end
  local ok, err = session.verify_dir(rundir)
  if not ok then return nil, err end
  return rundir
end

function session.state_dir(name)
  local state_home = os.getenv("XDG_STATE_HOME")
  local base
  if state_home and state_home ~= "" then
    base = state_home .. "/thither-server"
  else
    base = (serverfs.home() or ".") .. "/.local/state/thither-server"
  end
  local ok, err = session.verify_dir(base)
  if not ok then return nil, err end
  local dir = base .. "/" .. name
  ok, err = session.verify_dir(dir)
  if not ok then return nil, err end
  return dir
end

function session.socket_path(rundir, name)
  local path = rundir .. "/" .. name .. ".sock"
  if #path > 103 then
    return nil, string.format("socket path exceeds sun_path limit (%d > 103): %s", #path, path)
  end
  return path
end

function session.lock_path(rundir, name)
  return rundir .. "/" .. name .. ".lock"
end

function session.agent_link(statedir)
  return statedir .. "/agent.sock"
end

function session.daemon_log(statedir)
  return statedir .. "/daemon.log"
end

--- First executable `name` in the colon-separated `path` (default $PATH),
--- or nil.
function session.find_in_path(name, path)
  path = path or os.getenv("PATH") or ""
  for dir in path:gmatch("[^:]+") do
    local f = dir .. "/" .. name
    local st = serverfs.stat(f)
    if st and st.type == "file" and serverfs.access(f, 1) then return f end
  end
  return nil
end

--- The argv a relay starts the daemon with: argv, warning | nil.
--- o: session (validated name), idle_exit, retain_exited, plugins,
--- systemd_scope; exefile and datadir as EXEFILE / DATADIR; path for the
--- systemd-run lookup (default $PATH). With systemd_scope and systemd-run on
--- the path the daemon runs in a transient user scope, so that logind's
--- KillUserProcesses does not end it with the login session.
function session.daemon_argv(o, exefile, datadir, path)
  local argv, warning = {}, nil
  if o.systemd_scope then
    local sr = session.find_in_path("systemd-run", path)
    if sr then
      for _, a in ipairs({ sr, "--user", "--scope", "--quiet", "--" }) do argv[#argv + 1] = a end
    else
      warning = "--systemd-scope: systemd-run is not on PATH, starting the daemon without a scope"
    end
  end
  for _, a in ipairs({
    exefile,
    "--daemon",
    "--session", o.session,
    "--idle-exit", tostring(o.idle_exit or 600),
    "--retain-exited", tostring(o.retain_exited or 3600),
  }) do argv[#argv + 1] = a end
  if datadir then
    argv[#argv + 1] = "--datadir"
    argv[#argv + 1] = datadir
  end
  -- --root and --log are per connection: they go in the preamble only.
  -- The daemon has no jail of its own and logs to <state>/daemon.log.
  for _, p in ipairs(o.plugins or {}) do
    argv[#argv + 1] = "--plugins"
    argv[#argv + 1] = p
  end
  return argv, warning
end

return session
