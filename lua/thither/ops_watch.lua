-- watch ops: watch, unwatch.
--
-- watch { path, recursive = false, debounce_ms = 50, max_pending = 1024 }
--   -> { watch = <id>, dirs = <number of directories watched>, truncated = <bool> }
-- Events (coalesced over `debounce_ms`):
--   { ev = "watch",    watch = id, paths = { <changed directory>, ... } }
--   { ev = "overflow", watch = id }
-- The inotify/kqueue backends report which watched directory changed, not
-- which entry, so `paths` lists directories the client should re-scan (or
-- re-stat). "overflow" means events were lost or too many directories changed
-- within one window (> max_pending): rescan the whole watched tree.
local serverfs = require "serverfs"

return function(server)
  local ops = server.ops
  local raise = server.raise

  local MAX_DIRS = 8192

  local monitor
  -- backend id -> { watches = { [watch id] = { n = <dirs of that watch using it>, path = <dir reported in its events> } } }
  -- (inotify returns the same id for every path of one inode, e.g. after a
  -- rename; each watch reports the path it knows the directory by)
  local wds = {}
  local watches = {}  -- watch id -> state
  local nwatches, next_id = 0, 1

  local function parent_of(dir)
    local p = dir:match("^(.*)/[^/]+$")
    return p and (p == "" and "/" or p)
  end

  local function add_dir(w, dir, ino)
    if w.dirs[dir] then return true end
    if w.ndirs >= MAX_DIRS then w.truncated = true return false end
    local wd = monitor:watch(dir)
    if type(wd) ~= "number" or wd < 0 then
      w.truncated = true
      return false
    end
    local info = wds[wd]
    if not info then info = { watches = {} }; wds[wd] = info end
    local use = info.watches[w.id]
    if not use then use = { n = 0 }; info.watches[w.id] = use end
    use.n, use.path = use.n + 1, dir
    w.ndirs = w.ndirs + 1
    w.dirs[dir] = wd
    w.inos[dir] = ino
    local parent = parent_of(dir)
    if parent then
      w.kids[parent] = w.kids[parent] or {}
      w.kids[parent][dir] = true
    end
    return true
  end

  local function release_dir(w, dir)
    local wd = w.dirs[dir]
    if not wd then return end
    w.dirs[dir], w.inos[dir] = nil, nil
    w.ndirs = w.ndirs - 1
    local parent = parent_of(dir)
    local siblings = parent and w.kids[parent]
    if siblings then
      siblings[dir] = nil
      if next(siblings) == nil then w.kids[parent] = nil end
    end
    local info = wds[wd]
    if not info then return end
    local use = info.watches[w.id]
    if use then
      use.n = use.n - 1
      if use.n <= 0 then
        info.watches[w.id] = nil
      elseif use.path == dir then
        -- report the other path of this watch that still uses the inode
        for d, dwd in pairs(w.dirs) do
          if dwd == wd then use.path = d break end
        end
      end
    end
    if next(info.watches) == nil then
      monitor:unwatch(wd)
      wds[wd] = nil
    end
  end

  -- forgets `dir` and everything below it (deleted, renamed or replaced)
  local function release_tree(w, dir)
    local gone, i = { dir }, 1
    while gone[i] do
      for k in pairs(w.kids[gone[i]] or {}) do gone[#gone + 1] = k end
      i = i + 1
    end
    for j = #gone, 1, -1 do release_dir(w, gone[j]) end
  end

  local function add_tree(w, dir, ino)
    local queue, qi = { { dir, ino } }, 1
    while queue[qi] do
      local d, dino = queue[qi][1], queue[qi][2]
      qi = qi + 1
      add_dir(w, d, dino)
      if w.dirs[d] then
        local entries = serverfs.readdir(d, 0, 100000)
        for _, e in ipairs(entries or {}) do
          if e.type == "dir" and not e.is_link then
            queue[#queue + 1] = { (d == "/" and "" or d) .. "/" .. e.name, e.ino }
          end
        end
      end
    end
  end

  ops.watch = function(a)
    local path = server.path(a.path)
    local st = server.unwrap(serverfs.stat(path))
    if not monitor then monitor = dirmonitor.new() end
    local id = next_id
    next_id = next_id + 1
    local w = {
      id = id, root = path, recursive = a.recursive and true or false,
      debounce = (tonumber(a.debounce_ms) or 50) / 1000,
      max_pending = math.max(1, math.tointeger(a.max_pending) or 1024),
      dirs = {}, inos = {}, kids = {}, ndirs = 0, pending = {}, npending = 0, overflow = false, truncated = false,
    }
    watches[id] = w
    nwatches = nwatches + 1
    if w.recursive and st.type == "dir" then add_tree(w, path, st.ino) else add_dir(w, path, st.ino) end
    if w.ndirs == 0 then
      watches[id] = nil
      nwatches = nwatches - 1
      raise("watch_failed", "cannot watch " .. path .. " (is the inotify watch limit reached?)")
    end
    return { watch = id, dirs = w.ndirs, truncated = w.truncated }
  end

  ops.unwatch = function(a)
    local w = watches[a.watch]
    if not w then return true end
    local all = {}
    for d in pairs(w.dirs) do all[#all + 1] = d end
    for _, d in ipairs(all) do release_dir(w, d) end
    watches[w.id] = nil
    nwatches = nwatches - 1
    return true
  end

  -- brings the watched subdirectories of `dir` in line with its entries:
  -- new (or re-created) directories are watched, vanished ones forgotten
  local function reconcile(w, dir)
    local entries = serverfs.readdir(dir, 0, 100000)
    if not entries then return end
    local prefix = (dir == "/" and "" or dir) .. "/"
    local present = {}
    for _, e in ipairs(entries) do
      if e.type == "dir" and not e.is_link then
        local sub = prefix .. e.name
        present[sub] = true
        if w.dirs[sub] and w.inos[sub] ~= e.ino then release_tree(w, sub) end
        if not w.dirs[sub] then add_tree(w, sub, e.ino) end
      end
    end
    local gone = {}
    for d in pairs(w.kids[dir] or {}) do
      if not present[d] then gone[#gone + 1] = d end
    end
    for _, d in ipairs(gone) do release_tree(w, d) end
  end

  local function note(w, dir, now)
    if w.recursive then reconcile(w, dir) end
    if w.overflow then return end
    if not w.pending[dir] then
      w.pending[dir] = true
      w.npending = w.npending + 1
      if w.npending > w.max_pending then
        w.overflow = true
        w.pending, w.npending = {}, 0
      end
    end
    w.first_at = w.first_at or now
  end

  local function note_path(w, path, now)
    -- "single" mode backends (fsevents) report paths
    local root = w.root
    if path == root or path:sub(1, #root + 1) == root .. "/" then note(w, path, now) end
  end

  table.insert(server.tickers, function()
    if nwatches == 0 then return nil end
    -- (a burst of events on one directory is handled once)
    local changed, seen = {}, {}
    monitor:check(function(id)
      if not seen[id] then
        seen[id] = true
        changed[#changed + 1] = id
      end
      return true
    end, function(err) server.log("dirmonitor error: %s", tostring(err)) end)
    local now = system.get_time()
    for _, id in ipairs(changed) do
      if type(id) == "number" and id < 0 then
        for _, w in pairs(watches) do
          w.overflow = true
          w.pending, w.npending = {}, 0
          w.first_at = w.first_at or now
        end
      elseif type(id) == "number" then
        local info = wds[id]
        if info then
          -- note() may add or release directories, i.e. edit info.watches
          local uses = {}
          for wid, use in pairs(info.watches) do uses[#uses + 1] = { wid, use.path } end
          for _, u in ipairs(uses) do
            local w = watches[u[1]]
            if w then note(w, u[2], now) end
          end
        end
      elseif type(id) == "string" then
        for _, w in pairs(watches) do note_path(w, id, now) end
      end
    end
    local hint = 20
    for _, w in pairs(watches) do
      if w.first_at then
        local due = w.first_at + w.debounce
        if now >= due then
          if w.overflow then
            server.send({ ev = "overflow", watch = w.id })
          else
            local paths = {}
            for p in pairs(w.pending) do paths[#paths + 1] = p end
            table.sort(paths)
            server.send({ ev = "watch", watch = w.id, paths = paths })
          end
          w.pending, w.npending, w.overflow, w.first_at = {}, 0, false, nil
        else
          hint = math.min(hint, math.max(1, math.ceil((due - now) * 1000)))
        end
      end
    end
    return hint
  end)
end
