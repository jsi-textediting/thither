-- Session paths and security validation for thither-server
local serverfs = require "serverfs"

local session = {}

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

return session
