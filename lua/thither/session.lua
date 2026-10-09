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

function session.verify_dir(dir)
  serverfs.mkdir(dir, 448, true)
  local st = serverfs.stat(dir, true)
  if not st or st.type ~= "dir" or st.is_link then
    return nil, "directory is invalid or a symlink: " .. tostring(dir)
  end
  local uid = serverfs.ids().uid
  if st.uid ~= uid then
    return nil, string.format("directory not owned by current user (owner %s, expected %s): %s",
      tostring(st.uid), tostring(uid), tostring(dir))
  end
  if (st.mode % 512) ~= 448 then
    serverfs.chmod(dir, 448)
    st = serverfs.stat(dir, true)
    if (st.mode % 512) ~= 448 then
      return nil, "directory mode is not 0700: " .. tostring(dir)
    end
  end
  return true
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
