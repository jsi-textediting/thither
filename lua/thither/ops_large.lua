-- Large-file ops: lineindex, read_range, apply_edit, search.
--
-- The heavy lifting runs in C jobs (src/fsops.c) that are stepped from
-- the request coroutine, so other requests (reads of other ranges, pings,
-- cancels) are served while a multi-GB file is being indexed or copied.
local msgpack = require "thither.msgpack"
local serverfs = require "serverfs"

return function(server)
  local ops = server.ops
  local raise, unwrap = server.raise, server.unwrap

  local DEFAULT_CHUNK = 64 * 1024
  local MIN_CHUNK = 4096
  local MAX_CHUNK = 64 * 1024 * 1024
  local STEP_BYTES = 32 * 1024 * 1024
  local MAX_CACHE = 4
  local MAX_READ = 8 * 1024 * 1024
  local MAX_HASH = 64 * 1024 * 1024
  -- a chunk pair costs at most 11 bytes on the wire; stay well below max_frame
  local WIRE_BYTES_PER_CHUNK = 12
  local WIRE_BUDGET = 15 * 1024 * 1024

  -- index cache: realpath -> { etag, chunk_size, size, mtime, mtime_ns, chunks, ends_with_nl }
  local cache, cache_order = {}, {}

  local function touch(key)
    for i, k in ipairs(cache_order) do
      if k == key then table.remove(cache_order, i) break end
    end
    table.insert(cache_order, key)
    while #cache_order > MAX_CACHE do
      cache[table.remove(cache_order, 1)] = nil
    end
  end

  --- Runs a C job to completion, yielding to the event loop between steps.
  local function run_job(req, job)
    while true do
      local r, code, msg = job:step(STEP_BYTES)
      if r == nil then return nil, code, msg end
      if r ~= false then return r end
      req:yield()
    end
  end

  local function chunk_arg(v)
    if v == nil then return DEFAULT_CHUNK end
    if math.type(v) ~= "integer" or v < MIN_CHUNK or v > MAX_CHUNK then
      raise("bad_request", string.format("chunk_size must be an integer in [%d, %d]", MIN_CHUNK, MAX_CHUNK))
    end
    return v
  end

  local function regular_file(path)
    local st = unwrap(serverfs.stat(path))
    if st.type == "dir" then raise("EISDIR", "is a directory") end
    if st.type ~= "file" then raise("EINVAL", "not a regular file") end
    return st
  end

  --- Returns the line index entry for the current version of `path`
  --- (computed on demand, cached by etag). chunk_size nil accepts any cached
  --- granularity.
  local function index_for(req, path, chunk_size)
    local st = regular_file(path)
    local key = serverfs.realpath(path) or path
    local e = cache[key]
    if e and e.etag == st.etag and (chunk_size == nil or e.chunk_size == chunk_size) then
      touch(key)
      return e
    end
    chunk_size = chunk_size or (e and e.chunk_size) or DEFAULT_CHUNK
    for _ = 1, 3 do
      local job = unwrap(serverfs.lineindex_job(path, chunk_size))
      local res, code, msg = run_job(req, job)
      if res then
        e = {
          etag = res.etag, chunk_size = chunk_size, size = res.size, mtime = res.mtime,
          mtime_ns = res.mtime_ns, chunks = res.chunks, ends_with_nl = res.ends_with_nl, key = key,
        }
        cache[key] = e
        touch(key)
        return e
      end
      if code ~= "changed" then unwrap(nil, code, msg) end
      req:check()
    end
    raise("changed", "file keeps changing while it is being indexed")
  end

  -- args: path, chunk_size
  -- result: { size, mtime, mtime_ns, etag, chunks = {{len, lf}, ...}, ends_with_nl }
  ops.lineindex = function(a, req)
    local path = server.path(a.path)
    local chunk_size = chunk_arg(a.chunk_size)
    local e = index_for(req, path, chunk_size)
    if #e.chunks * WIRE_BYTES_PER_CHUNK > WIRE_BUDGET then
      raise("too_large", "chunk table does not fit in one frame; use a larger chunk_size", {
        min_chunk_size = math.max(MIN_CHUNK, math.ceil(e.size / (WIRE_BUDGET // WIRE_BYTES_PER_CHUNK))),
      })
    end
    return { size = e.size, mtime = e.mtime, mtime_ns = e.mtime_ns, etag = e.etag,
             chunks = e.chunks, ends_with_nl = e.ends_with_nl }
  end

  -- args: path, off, len (<= 8 MiB), etag   result: <bin> | err "stale"
  ops.read_range = function(a)
    local path = server.path(a.path)
    local off, len = a.off, a.len
    if math.type(off) ~= "integer" or off < 0 or math.type(len) ~= "integer" or len < 0 then
      raise("bad_request", "off and len must be non-negative integers")
    end
    if len > MAX_READ then raise("too_large", "read_range length exceeds 8 MiB") end
    local data = unwrap(serverfs.read(path, off, len, a.etag))
    return msgpack.bin(data)
  end

  -- args: path, etag, ranges = { {off, len}, ... } (at most MAX_HASH bytes in all)
  -- result: { <64-bit FNV-1a of each range>, ... }
  ops.hash_ranges = function(a)
    local path = server.path(a.path)
    if type(a.ranges) ~= "table" then raise("bad_request", "ranges required") end
    local total = 0
    for _, r in ipairs(a.ranges) do
      local len = type(r) == "table" and r[2]
      if math.type(len) ~= "integer" or len < 0 then
        raise("bad_request", "a range must be { off, len } with non-negative integers")
      end
      total = total + len
    end
    -- the hashing blocks the server: keep one request short
    if total > MAX_HASH then raise("too_large", "hash_ranges covers more than 64 MiB") end
    return (unwrap(serverfs.hash_ranges(path, a.ranges, a.etag)))
  end

  -- args: path, etag, script, inserts, chunk_size (only used when the index
  --   has to be built first), dest, dest_if_match
  --   script  = list of {keep=true, off=, len=} (ranges of the ORIGINAL file)
  --             and {ins=<1-based index into inserts>}
  --   inserts = list of strings, or {blob=<id>} references to blob_put data
  --   dest    = write the result to this path instead (save as); path is only read
  --   dest_if_match = etag dest must have, "-" = must not exist (EEXIST otherwise)
  -- result: { etag, size, mtime, mtime_ns, chunks, ends_with_nl } | err "conflict"
  ops.apply_edit = function(a, req)
    local path = server.path(a.path)
    local dest = a.dest ~= nil and server.path(a.dest) or nil
    if a.dest_if_match ~= nil and type(a.dest_if_match) ~= "string" then
      raise("bad_request", "dest_if_match must be a string")
    end
    if type(a.etag) ~= "string" then raise("bad_request", "etag required") end
    if type(a.script) ~= "table" then raise("bad_request", "script required") end
    local inserts = {}
    local given = a.inserts or {}
    if type(given) ~= "table" then raise("bad_request", "inserts must be a list") end
    for i = 1, #given do
      local v = given[i]
      if type(v) == "string" then
        inserts[i] = v
      elseif type(v) == "table" and v.blob ~= nil then
        inserts[i] = server.blob_get(v.blob)
      else
        raise("bad_request", "insert " .. i .. " must be a string or {blob=id}")
      end
    end
    local e = index_for(req, path, a.chunk_size and chunk_arg(a.chunk_size) or nil)
    if e.etag ~= a.etag then
      raise("conflict", "etag mismatch", { etag = e.etag })
    end
    local job = unwrap(serverfs.edit_job(path, a.etag, a.script, inserts, e.chunk_size, e.chunks,
                                         dest, a.dest_if_match))
    local res, code, msg = run_job(req, job)
    if not res then
      if not dest then cache[e.key] = nil end
      unwrap(nil, code, msg)
    end
    local key = dest and (serverfs.realpath(dest) or dest) or e.key
    local ne = {
      etag = res.etag, chunk_size = e.chunk_size, size = res.size, mtime = res.mtime,
      mtime_ns = res.mtime_ns, chunks = res.chunks, ends_with_nl = res.ends_with_nl, key = key,
    }
    cache[key] = ne
    touch(key)
    return { etag = ne.etag, size = ne.size, mtime = ne.mtime, mtime_ns = ne.mtime_ns,
             chunks = ne.chunks, ends_with_nl = ne.ends_with_nl }
  end

  -- args: path, pattern, opts = {regex=false, case=true, limit=1000}, from_off, etag
  -- result: list of {off, line, col, len}   (see docs/protocol.md)
  ops.search = function(a, req)
    local path = server.path(a.path)
    if type(a.pattern) ~= "string" or a.pattern == "" then raise("bad_request", "pattern required") end
    local o = a.opts or {}
    if type(o) ~= "table" then raise("bad_request", "opts must be a map") end
    local from_off = a.from_off or 0
    if math.type(from_off) ~= "integer" or from_off < 0 then raise("bad_request", "from_off must be >= 0") end
    local chunks = {}
    if from_off > 0 then chunks = index_for(req, path, nil).chunks end
    local job = unwrap(serverfs.search_job(path, a.pattern, o, from_off, chunks, a.etag))
    return unwrap(run_job(req, job))
  end
end
