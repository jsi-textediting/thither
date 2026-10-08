-- Filesystem ops: stat, readdir, read, write (+ streamed write), mkdir,
-- remove, rename, realpath.
local msgpack = require "thither.msgpack"
local serverfs = require "serverfs"

return function(server)
  local ops = server.ops
  local raise, unwrap = server.raise, server.unwrap

  local MAX_WRITERS = 64
  local MAX_BLOB_TOTAL = 1024 * 1024 * 1024

  local function int_arg(v, name, default, min)
    if v == nil then v = default end
    if math.type(v) ~= "integer" or (min and v < min) then
      raise("bad_request", name .. " must be an integer" .. (min and (" >= " .. min) or ""))
    end
    return v
  end

  ops.stat = function(a)
    return unwrap(serverfs.stat(server.path(a.path), a.nofollow))
  end

  -- args: path, offset (default 0), limit (default 20000, max 50000)
  -- result: { entries = {...sorted by name...}, total = <entries in dir>, offset = <n>, more = <bool> }
  ops.readdir = function(a)
    local path = server.path(a.path)
    local offset = int_arg(a.offset, "offset", 0, 0)
    local limit = math.min(int_arg(a.limit, "limit", 20000, 0), 50000)
    local entries, total = unwrap(serverfs.readdir(path, offset, limit))
    return { entries = entries, total = total, offset = offset, more = offset + #entries < total }
  end

  -- args: path, offset, len (<= 8 MiB), etag (optional)
  -- result: { data = <bin>, etag = <string>, eof = <bool> }
  ops.read = function(a)
    local path = server.path(a.path)
    local off = int_arg(a.offset, "offset", 0, 0)
    local len = int_arg(a.len, "len", nil, 0)
    local data, etag, eof = unwrap(serverfs.read(path, off, len, a.etag))
    return { data = msgpack.bin(data), etag = etag, eof = eof }
  end

  local function check_data(data)
    if data == nil then return "" end
    if type(data) ~= "string" then raise("bad_request", "data must be a string") end
    return data
  end

  -- args: path, data, if_match, mode, create_dirs  -> stat table of the new file
  ops.write = function(a)
    local path = server.path(a.path)
    local data = check_data(a.data)
    local mode = a.mode ~= nil and int_arg(a.mode, "mode") or nil
    local w = unwrap(serverfs.writer(path, mode, a.create_dirs and true or false))
    unwrap(w:write(data))
    return unwrap(w:commit(a.if_match))
  end

  -- Streamed write for payloads above one frame: write_begin / write_chunk /
  -- write_commit | write_abort. Nothing becomes visible until write_commit.
  local writers, nwriters, next_wid = {}, 0, 1

  ops.write_begin = function(a)
    if nwriters >= MAX_WRITERS then raise("too_many", "too many open write sessions") end
    local path = server.path(a.path)
    local mode = a.mode ~= nil and int_arg(a.mode, "mode") or nil
    local w = unwrap(serverfs.writer(path, mode, a.create_dirs and true or false))
    local wid = next_wid
    next_wid = next_wid + 1
    writers[wid] = { w = w, if_match = a.if_match }
    nwriters = nwriters + 1
    return { wid = wid }
  end

  local function get_writer(a)
    local s = writers[a.wid]
    if not s then raise("no_stream", "unknown write session") end
    return s
  end

  local function drop_writer(wid)
    if writers[wid] then
      writers[wid] = nil
      nwriters = nwriters - 1
    end
  end

  ops.write_chunk = function(a)
    local s = get_writer(a)
    local ok, code, msg = s.w:write(check_data(a.data))
    if not ok then
      s.w:abort()
      drop_writer(a.wid)
      unwrap(nil, code, msg)
    end
    return s.w:size()
  end

  ops.write_commit = function(a)
    local s = get_writer(a)
    drop_writer(a.wid)
    return unwrap(s.w:commit(s.if_match))
  end

  ops.write_abort = function(a)
    local s = get_writer(a)
    s.w:abort()
    drop_writer(a.wid)
    return true
  end

  ops.mkdir = function(a)
    local mode = a.mode ~= nil and int_arg(a.mode, "mode") or nil
    unwrap(serverfs.mkdir(server.path(a.path), mode, a.parents and true or false))
    return true
  end

  ops.remove = function(a)
    local path = server.path(a.path)
    if server.root and path == server.root then raise("jail", "cannot remove the server root") end
    unwrap(serverfs.remove(path, a.recursive and true or false))
    return true
  end

  -- args: from, to, overwrite (default true)
  ops.rename = function(a)
    local from, to = server.path(a.from), server.path(a.to)
    unwrap(serverfs.rename(from, to, a.overwrite == false))
    return true
  end

  ops.chmod = function(a)
    unwrap(serverfs.chmod(server.path(a.path), int_arg(a.mode, "mode", nil, 0)))
    return true
  end

  -- args: path, mtime_ns (absent: now)
  ops.utime = function(a)
    local ns = a.mtime_ns ~= nil and int_arg(a.mtime_ns, "mtime_ns") or nil
    unwrap(serverfs.utime(server.path(a.path), ns))
    return true
  end

  -- args: target (the link's content, not a path the server resolves), path, overwrite
  ops.symlink = function(a)
    if type(a.target) ~= "string" or a.target == "" then raise("bad_request", "target required") end
    unwrap(serverfs.symlink(a.target, server.path(a.path), a.overwrite and true or false))
    return true
  end

  -- args: from, to, overwrite (hard link)
  ops.link = function(a)
    local from, to = server.path(a.from), server.path(a.to)
    unwrap(serverfs.link(from, to, a.overwrite and true or false))
    return true
  end

  -- args: path, mode (4 read | 2 write | 1 execute, 0 exists) -> true | false
  ops.access = function(a)
    local ok = unwrap(serverfs.access(server.path(a.path), int_arg(a.mode, "mode", 0, 0)))
    return ok
  end

  local COPY_STEP = 32 * 1024 * 1024

  -- args: from, to, overwrite (default true), keep_time -> stat table of the copy
  -- Atomic like write: the copy appears complete or not at all.
  ops.copy = function(a, req)
    local from, to = server.path(a.from), server.path(a.to)
    local st = unwrap(serverfs.stat(from))
    if st.type == "dir" then raise("EISDIR", "is a directory") end
    if st.type ~= "file" then raise("EINVAL", "not a regular file") end
    if a.overwrite == false and serverfs.stat(to, true) then raise("EEXIST", "file exists") end
    local w = unwrap(serverfs.writer(to, st.mode, false))
    local off = 0
    while true do
      local n, code, msg = w:copy(from, off, COPY_STEP, st.etag)
      if not n then
        w:abort()
        if code == "stale" then raise("changed", "file changed while being copied") end
        unwrap(nil, code, msg)
      end
      if n == 0 then break end
      off = off + n
      local ok, e = pcall(req.yield, req)   -- raises "cancelled"
      if not ok then w:abort(); error(e, 0) end
    end
    local res, code, msg = w:commit(a.overwrite == false and "-" or nil)
    if not res and code == "conflict" then raise("EEXIST", "file exists") end
    unwrap(res, code, msg)
    if a.keep_time then
      unwrap(serverfs.utime(to, st.mtime_ns))
      res = unwrap(serverfs.stat(to))
    end
    return res
  end

  ops.realpath = function(a)
    local rp = unwrap(serverfs.realpath(server.path(a.path)))
    server.path(rp)  -- the resolved path must still be inside the jail
    return rp
  end

  -- Blobs hold large inserts for apply_edit that do not fit in one frame:
  -- blob_put appends data to blob <id>, apply_edit references it as {blob=id}.
  local blobs, blob_total = {}, 0

  ops.blob_put = function(a)
    local id = a.id
    if id == nil then raise("bad_request", "blob id required") end
    local data = check_data(a.data)
    if blob_total + #data > MAX_BLOB_TOTAL then raise("too_large", "blob storage limit reached") end
    local b = blobs[id]
    if not b then b = { n = 0, size = 0 }; blobs[id] = b end
    b.n = b.n + 1
    b[b.n] = data
    b.size = b.size + #data
    blob_total = blob_total + #data
    return b.size
  end

  ops.blob_drop = function(a)
    local b = blobs[a.id]
    if b then
      blob_total = blob_total - b.size
      blobs[a.id] = nil
    end
    return true
  end

  --- Returns the contents of blob `id` (for apply_edit).
  function server.blob_get(id)
    local b = blobs[id]
    if not b then raise("no_blob", "unknown blob: " .. tostring(id)) end
    if b.n > 1 then
      local all = table.concat(b, "", 1, b.n)
      for i = 2, b.n do b[i] = nil end
      b[1], b.n = all, 1
    end
    return b[1] or ""
  end
end
