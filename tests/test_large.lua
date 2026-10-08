-- Large-file ops: lineindex, read_range, apply_edit, blob, search.
-- Small and randomized cases are checked against a pure-Lua reference model;
-- the multi-hundred-MB cases against independent tools (wc, dd, cmp, tr).
local H = require "harness"
local U = require "util"
local Client = require "client"
local mp = require "thither.msgpack"

local MB = 1024 * 1024

local function connect() return Client.connect() end

local function timed(label, fn)
  local t0 = system.get_time()
  local a, b, c = fn()
  local dt = system.get_time() - t0
  print(string.format("     [time] %-48s %.3f s", label, dt))
  return dt, a, b, c
end

-- reference: uniform chunk table of `data`
local function ref_chunks(data, cs)
  local chunks = {}
  for pos = 1, #data, cs do
    local piece = data:sub(pos, pos + cs - 1)
    chunks[#chunks + 1] = { #piece, U.count_lf(piece) }
  end
  return chunks
end

-- checks that `chunks` describes `data` exactly (lengths and newline counts)
local function check_chunks(chunks, data, max_chunk)
  local pos = 1
  for i, c in ipairs(chunks) do
    H.ok(c[1] > 0, "empty chunk " .. i)
    if max_chunk then H.ok(c[1] <= max_chunk, "chunk " .. i .. " longer than chunk_size: " .. c[1]) end
    local piece = data:sub(pos, pos + c[1] - 1)
    if U.count_lf(piece) ~= c[2] then
      error(string.format("chunk %d [%d, %d): expected %d newlines, table says %d", i, pos - 1, pos - 1 + c[1],
        U.count_lf(piece), c[2]))
    end
    pos = pos + c[1]
  end
  H.eq(pos - 1, #data, "chunk lengths must add up to the file size")
end

local function ref_apply(data, script, inserts)
  local out = {}
  for _, it in ipairs(script) do
    if it.keep then out[#out + 1] = data:sub(it.off + 1, it.off + it.len)
    else out[#out + 1] = inserts[it.ins] end
  end
  return table.concat(out)
end

local function random_text(n, binary)
  local parts, len = {}, 0
  while len < n do
    local line
    if binary and math.random() < 0.1 then
      local t = {}
      for i = 1, math.random(0, 50) do t[i] = string.char(math.random(0, 255)) end
      line = table.concat(t)
    else
      local t = {}
      for i = 1, math.random(0, 120) do t[i] = string.char(math.random(32, 126)) end
      line = table.concat(t) .. (math.random() < 0.05 and "\r" or "")
    end
    if math.random() < 0.95 then line = line .. "\n" end
    parts[#parts + 1] = line
    len = len + #line
  end
  return table.concat(parts)
end

-- lineindex -------------------------------------------------------------

H.test("lineindex: matches a reference for varied small files", function()
  local dir = U.tmpdir("li")
  local c = connect()
  math.randomseed(1)
  local cases = {
    { "empty", "" }, { "single newline", "\n" }, { "no newline", "abc" }, { "trailing newline", "abc\ndef\n" },
    { "no trailing newline", "abc\ndef" }, { "crlf", "a\r\nb\r\nc\r\n" },
    { "exact chunk", string.rep("x", 4095) .. "\n" }, { "chunk plus one", string.rep("x", 4096) .. "\n" },
    { "random text", random_text(100000, true) }, { "random lf heavy", string.rep("\n", 9000) },
  }
  for _, case in ipairs(cases) do
    local path = dir .. "/f"
    U.write_file(path, case[2])
    for _, cs in ipairs({ 4096, 5000, 65536 }) do
      local r = c:request("lineindex", { path = path, chunk_size = cs })
      H.eq(r.size, #case[2], case[1])
      H.eq(r.chunks, ref_chunks(case[2], cs), case[1] .. " cs=" .. cs)
      H.eq(r.ends_with_nl, #case[2] > 0 and case[2]:sub(-1) == "\n", case[1] .. " ends_with_nl")
      H.ok(r.etag:match("^%d+%-%d+%-%d+$"))
      H.eq(r.etag, r.mtime_ns .. "-" .. r.size .. "-" .. c:request("stat", { path = path }).ino)
    end
    os.remove(path)
  end
  c:close()
end)

H.test("lineindex: errors and argument validation", function()
  local dir = U.tmpdir("lierr")
  local c = connect()
  local _, err = c:request("lineindex", { path = dir })
  H.eq(err.code, "EISDIR")
  _, err = c:request("lineindex", { path = dir .. "/missing" })
  H.eq(err.code, "ENOENT")
  U.write_file(dir .. "/f", "x")
  _, err = c:request("lineindex", { path = dir .. "/f", chunk_size = 10 })
  H.eq(err.code, "bad_request")
  _, err = c:request("lineindex", { path = dir .. "/f", chunk_size = "big" })
  H.eq(err.code, "bad_request")
  H.eq(c:request("lineindex", { path = dir .. "/f" }).chunks, { { 1, 0 } }, "default chunk size")
  c:close()
end)

H.test("lineindex: cache is keyed by etag and refreshed after external edits", function()
  local dir = U.tmpdir("licache")
  local c = connect()
  U.write_file(dir .. "/f", "a\nb\n")
  local r1 = c:request("lineindex", { path = dir .. "/f", chunk_size = 4096 })
  local r1b = c:request("lineindex", { path = dir .. "/f", chunk_size = 4096 })
  H.eq(r1.etag, r1b.etag)
  U.sh("sleep 0.05")
  U.write_file(dir .. "/f", "a\nb\nc\n")
  local r2 = c:request("lineindex", { path = dir .. "/f", chunk_size = 4096 })
  H.ok(r2.etag ~= r1.etag)
  H.eq(r2.chunks, { { 6, 3 } })
  c:close()
end)

H.test("hash_ranges: FNV-1a of each range, stale detection and limits", function()
  local function fnv(str)
    local h = -3750763034362895579 -- 14695981039346656037 as a signed integer
    for k = 1, #str do h = (h ~ str:byte(k)) * 1099511628211 end
    return h
  end
  local dir = U.tmpdir("hr")
  math.randomseed(3)
  local data = random_text(200000, true)
  U.write_file(dir .. "/f", data)
  local c = connect()
  local li = c:request("lineindex", { path = dir .. "/f", chunk_size = 4096 })
  local ranges, want, pos = {}, {}, 0
  for i = 1, #li.chunks do
    local len = li.chunks[i][1]
    ranges[i], want[i] = { pos, len }, fnv(data:sub(pos + 1, pos + len))
    pos = pos + len
  end
  -- cut at the end of the file, empty range
  ranges[#ranges + 1], want[#want + 1] = { #data - 3, 100 }, fnv(data:sub(-3))
  ranges[#ranges + 1], want[#want + 1] = { 10, 0 }, fnv("")
  H.eq(c:request("hash_ranges", { path = dir .. "/f", ranges = ranges, etag = li.etag }), want)
  local _, err = c:request("hash_ranges", { path = dir .. "/f", ranges = { { 0, 65 * MB } } })
  H.eq(err.code, "too_large")
  _, err = c:request("hash_ranges", { path = dir .. "/f", ranges = { { -1, 5 } } })
  H.ok(err.code == "EINVAL" or err.code == "bad_request", err.code)
  U.sh("sleep 0.05; printf X >> " .. dir .. "/f")
  _, err = c:request("hash_ranges", { path = dir .. "/f", ranges = { { 0, 10 } }, etag = li.etag })
  H.eq(err.code, "stale")
  c:close()
end)

H.test("read_range: exact bytes, stale detection and limits", function()
  local dir = U.tmpdir("rr")
  math.randomseed(2)
  local data = random_text(300000, true)
  U.write_file(dir .. "/f", data)
  local c = connect()
  local li = c:request("lineindex", { path = dir .. "/f", chunk_size = 4096 })
  local pos = 0
  for i = 1, #li.chunks do
    local len = li.chunks[i][1]
    local got = c:request("read_range", { path = dir .. "/f", off = pos, len = len, etag = li.etag })
    if got ~= data:sub(pos + 1, pos + len) then error("chunk " .. i .. " differs") end
    pos = pos + len
  end
  H.eq(c:request("read_range", { path = dir .. "/f", off = #data - 5, len = 100, etag = li.etag }), data:sub(-5))
  H.eq(c:request("read_range", { path = dir .. "/f", off = #data + 5, len = 100, etag = li.etag }), "")
  local _, err = c:request("read_range", { path = dir .. "/f", off = 0, len = 9 * MB })
  H.eq(err.code, "too_large")
  _, err = c:request("read_range", { path = dir .. "/f", off = -1, len = 5 })
  H.eq(err.code, "bad_request")
  U.sh("sleep 0.05; printf X >> " .. dir .. "/f")
  _, err = c:request("read_range", { path = dir .. "/f", off = 0, len = 10, etag = li.etag })
  H.eq(err.code, "stale")
  c:close()
end)

-- apply_edit ------------------------------------------------------------

local function random_script(len, cs)
  local script, inserts = {}, {}
  local pos = 0
  while pos < len do
    local s
    local r = math.random()
    if r < 0.3 then s = math.min(len, math.max(pos, (math.random(0, len // cs) * cs) + math.random(-1, 1)))
    else s = math.random(pos, len) end
    if s > pos then script[#script + 1] = { keep = true, off = pos, len = s - pos } end
    local d = math.random() < 0.6 and math.random(0, math.min(len - s, 3 * cs)) or 0
    pos = s + d
    if math.random() < 0.7 then
      local ins
      local k = math.random()
      if k < 0.1 then ins = ""
      elseif k < 0.2 then ins = random_text(math.random(100000, 150000), true)
      else ins = random_text(math.random(0, 600), true) end
      inserts[#inserts + 1] = ins
      script[#script + 1] = { ins = #inserts }
    end
    if math.random() < 0.15 then break end
  end
  if pos < len and math.random() < 0.8 then script[#script + 1] = { keep = true, off = pos, len = len - pos } end
  return script, inserts
end

H.test("apply_edit: randomized edits match a reference model and chain through the cache", function()
  local dir = U.tmpdir("edit")
  math.randomseed(42)
  local path = dir .. "/f"
  local cs = 4096
  local content = random_text(400000, true)
  U.write_file(path, content)
  U.sh("chmod 640 " .. path)
  local c = connect()
  local li = c:request("lineindex", { path = path, chunk_size = cs })
  local etag = li.etag
  for iter = 1, 60 do
    local script, inserts = random_script(#content, cs)
    local expected = ref_apply(content, script, inserts)
    local r, err = c:request("apply_edit", { path = path, etag = etag, script = script, inserts = inserts })
    if not r then error("iteration " .. iter .. ": " .. tostring(err and err.code) .. " " .. tostring(err and err.msg)) end
    local actual = U.read_file(path)
    if actual ~= expected then error("iteration " .. iter .. ": file content differs from the reference") end
    H.eq(r.size, #expected)
    check_chunks(r.chunks, expected, cs)
    H.eq(r.ends_with_nl, #expected > 0 and expected:sub(-1) == "\n", "ends_with_nl iteration " .. iter)
    local st = c:request("stat", { path = path })
    H.eq(r.etag, st.etag); H.eq(st.mode, tonumber("640", 8), "mode preserved")
    H.eq(U.ls(dir), { "f" }, "no temp files left")
    content, etag = expected, r.etag
    if #content == 0 then
      U.write_file(path, random_text(200000, true))
      content = U.read_file(path)
      etag = c:request("lineindex", { path = path, chunk_size = cs }).etag
    end
    if iter % 15 == 0 then
      -- a cold index of the edited file is uniform and agrees with the incremental one
      -- (touch changes the etag, so the server cannot answer from its cache)
      U.sh("sleep 0.02; touch " .. path)
      local fresh = c:request("lineindex", { path = path, chunk_size = cs })
      H.eq(fresh.chunks, ref_chunks(content, cs))
      etag = fresh.etag
    end
  end
  c:close()
end)

H.test("apply_edit: edge scripts", function()
  local dir = U.tmpdir("edge")
  local path = dir .. "/f"
  local content = "line1\nline2\nline3\n"
  U.write_file(path, content)
  local c = connect()
  local etag = c:request("lineindex", { path = path, chunk_size = 4096 }).etag
  local function apply(script, inserts)
    local r, err = c:request("apply_edit", { path = path, etag = etag, script = script, inserts = inserts })
    if r then etag = r.etag end
    return r, err
  end
  -- identity
  local r = apply({ { keep = true, off = 0, len = #content } }, {})
  H.eq(U.read_file(path), content); H.eq(r.chunks, { { 18, 3 } })
  -- insert at start and at end, no trailing newline
  r = apply({ { ins = 1 }, { keep = true, off = 0, len = #content }, { ins = 2 } }, { "head\n", "tail" })
  H.eq(U.read_file(path), "head\n" .. content .. "tail"); H.eq(r.ends_with_nl, false); H.eq(r.chunks, { { 27, 4 } })
  content = U.read_file(path)
  -- reordered, duplicated and overlapping ranges are legal
  r = apply({ { keep = true, off = 5, len = 7 }, { keep = true, off = 0, len = 5 }, { keep = true, off = 0, len = 5 } }, {})
  H.eq(U.read_file(path), content:sub(6, 12) .. content:sub(1, 5) .. content:sub(1, 5))
  -- zero-length items are ignored
  content = U.read_file(path)
  r = apply({ { keep = true, off = 3, len = 0 }, { ins = 1 }, { keep = true, off = 0, len = 4 } }, { "" })
  H.eq(U.read_file(path), content:sub(1, 4))
  -- empty result
  r = apply({}, {})
  H.eq(U.read_file(path), ""); H.eq(r.size, 0); H.eq(r.chunks, {}); H.eq(r.ends_with_nl, false)
  -- growing an empty file
  r = apply({ { ins = 1 } }, { "new\n" })
  H.eq(U.read_file(path), "new\n"); H.eq(r.ends_with_nl, true)
  c:close()
end)

H.test("apply_edit: conflicts, bad scripts and cleanup", function()
  local dir = U.tmpdir("conf")
  local path = dir .. "/f"
  U.write_file(path, "0123456789\n")
  local c = connect()
  local li = c:request("lineindex", { path = path, chunk_size = 4096 })
  local script = { { keep = true, off = 0, len = 5 }, { ins = 1 } }
  -- wrong etag
  local _, err = c:request("apply_edit", { path = path, etag = "1-2-3", script = script, inserts = { "X" } })
  H.eq(err.code, "conflict"); H.eq(err.etag, li.etag)
  H.eq(U.read_file(path), "0123456789\n")
  -- file changed externally after indexing
  U.sh("sleep 0.05; printf 'abcdefghij\\n' > " .. path)
  _, err = c:request("apply_edit", { path = path, etag = li.etag, script = script, inserts = { "X" } })
  H.eq(err.code, "conflict")
  H.eq(U.read_file(path), "abcdefghij\n")
  local fresh = c:request("lineindex", { path = path, chunk_size = 4096 })
  -- out-of-range and malformed scripts
  for i, bad in ipairs({
    { { keep = true, off = 0, len = 100 } }, { { keep = true, off = -1, len = 2 } },
    { { keep = true, off = 5, len = -1 } }, { { ins = 5 } }, { { ins = 0 } }, { { keep = true, len = 3 } }, { "x" },
  }) do
    local _, e = c:request("apply_edit", { path = path, etag = fresh.etag, script = bad, inserts = { "X" } })
    H.eq(e.code, "bad_request", "bad script #" .. i)
  end
  _, err = c:request("apply_edit", { path = path, etag = fresh.etag, script = {}, inserts = { 5 } })
  H.eq(err.code, "bad_request")
  _, err = c:request("apply_edit", { path = dir .. "/missing", etag = "x", script = {}, inserts = {} })
  H.eq(err.code, "ENOENT")
  H.eq(U.read_file(path), "abcdefghij\n")
  H.eq(U.ls(dir), { "f" }, "no temp files after failed edits")
  c:close()
end)

H.test("apply_edit: dest writes the edit to another file (save as)", function()
  local dir = U.tmpdir("dest")
  math.randomseed(7)
  local path, out = dir .. "/src", dir .. "/out"
  local cs = 4096
  local content = random_text(300000, true)
  U.write_file(path, content)
  U.sh("chmod 640 " .. path)
  local c = connect()
  local li = c:request("lineindex", { path = path, chunk_size = cs })
  local script, inserts = random_script(#content, cs)
  local expected = ref_apply(content, script, inserts)
  local r, err = c:request("apply_edit", { path = path, etag = li.etag, script = script, inserts = inserts,
                                           dest = out, dest_if_match = "-" })
  H.ok(r, err and (err.code .. " " .. tostring(err.msg)))
  H.eq(U.read_file(path), content, "the source is untouched")
  H.eq(c:request("stat", { path = path }).etag, li.etag)
  H.eq(U.read_file(out), expected)
  check_chunks(r.chunks, expected, cs)
  local st = c:request("stat", { path = out })
  H.eq(r.etag, st.etag); H.eq(st.mode, tonumber("640", 8), "a new dest gets the source permissions")
  -- the returned index is cached for dest: a lineindex of it agrees and edits chain
  H.eq(c:request("lineindex", { path = out, chunk_size = cs }).chunks, r.chunks)
  local r2 = c:request("apply_edit", { path = out, etag = r.etag, script = { { keep = true, off = 0, len = 10 } } })
  H.eq(U.read_file(out), expected:sub(1, 10)); H.eq(r2.size, 10)
  -- dest exists: "-" refuses, the right etag overwrites (keeping dest's permissions), a wrong one conflicts
  U.sh("chmod 600 " .. out)
  _, err = c:request("apply_edit", { path = path, etag = li.etag, script = script, inserts = inserts,
                                     dest = out, dest_if_match = "-" })
  H.eq(err.code, "EEXIST")
  _, err = c:request("apply_edit", { path = path, etag = li.etag, script = script, inserts = inserts,
                                     dest = out, dest_if_match = "1-2-3" })
  H.eq(err.code, "conflict")
  H.eq(U.read_file(out), expected:sub(1, 10), "dest untouched after refusals")
  local cur = c:request("stat", { path = out }).etag
  H.ok(c:request("apply_edit", { path = path, etag = li.etag, script = script, inserts = inserts,
                                 dest = out, dest_if_match = cur }))
  H.eq(U.read_file(out), expected)
  H.eq(U.sh("stat -c %a " .. out), "600\n")
  -- without dest_if_match dest is replaced unconditionally; a wrong source etag still conflicts
  H.ok(c:request("apply_edit", { path = path, etag = li.etag, script = { { keep = true, off = 0, len = 3 } },
                                 dest = out }))
  H.eq(U.read_file(out), content:sub(1, 3))
  _, err = c:request("apply_edit", { path = path, etag = "1-2-3", script = {}, dest = out })
  H.eq(err.code, "conflict")
  H.eq(U.ls(dir), { "out", "src" }, "no temp files left")
  c:close()
end)

H.test("apply_edit: blob inserts larger than one frame", function()
  local dir = U.tmpdir("blob")
  local path = dir .. "/f"
  U.write_file(path, "head\ntail\n")
  local c = connect()
  local li = c:request("lineindex", { path = path, chunk_size = 65536 })
  math.randomseed(9)
  local big = random_text(5 * MB, true)
  for off = 1, #big, MB do
    c:request("blob_put", { id = "paste1", data = mp.bin(big:sub(off, off + MB - 1)) })
  end
  H.eq(c:request("blob_put", { id = "paste1", data = "" }), #big)
  local r = c:request("apply_edit", { path = path, etag = li.etag,
    script = { { keep = true, off = 0, len = 5 }, { ins = 1 }, { keep = true, off = 5, len = 5 }, { ins = 2 } },
    inserts = { { blob = "paste1" }, "end\n" } })
  local expected = "head\n" .. big .. "tail\n" .. "end\n"
  H.ok(U.read_file(path) == expected, "content differs")
  H.eq(r.size, #expected)
  check_chunks(r.chunks, expected, 65536)
  local _, err = c:request("apply_edit", { path = path, etag = r.etag, script = { { ins = 1 } }, inserts = { { blob = "nope" } } })
  H.eq(err.code, "no_blob")
  H.ok(c:request("blob_drop", { id = "paste1" }))
  c:close()
end)

-- search ----------------------------------------------------------------

local line_starts_of = setmetatable({}, { __index = function(t, data)
  local starts, pos = { 0 }, 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then break end
    starts[#starts + 1] = nl
    pos = nl + 1
  end
  t[data] = starts
  return starts
end })

-- reference positions of non-overlapping literal matches
local function ref_search(data, needle, from, limit, ignore_case)
  local hay, nd = data, needle
  if ignore_case then hay, nd = data:lower(), needle:lower() end
  local out, init = {}, from + 1
  local line_starts = line_starts_of[data]
  while #out < limit do
    local s = hay:find(nd, init, true)
    if not s then break end
    -- line number by binary search over line starts
    local lo, hi = 1, #line_starts
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if line_starts[mid] <= s - 1 then lo = mid else hi = mid - 1 end
    end
    out[#out + 1] = { off = s - 1, line = lo, col = (s - 1) - line_starts[lo] + 1, len = #needle }
    init = s + #needle
  end
  return out
end
local function build_search_file(size)
  math.randomseed(5)
  local parts, len = {}, 0
  while len < size do
    local t = {}
    for i = 1, math.random(10, 90) do t[i] = string.char(math.random(97, 122)) end
    local line = table.concat(t) .. "\n"
    parts[#parts + 1] = line
    len = len + #line
  end
  local data = table.concat(parts)
  -- plant needles, some straddling the 1 MiB read-block boundaries
  local needles = {}
  local function plant(off, text)
    data = data:sub(1, off) .. text .. data:sub(off + #text + 1)
  end
  plant(10, "NeedleXYZ")
  for k = 1, 8 do plant(k * MB - 4, "NeedleXYZ") end
  plant(4 * MB + 100, "needlexyz")
  plant(#data - 20, "NeedleXYZ")
  plant(MB + 300, "NeedleXYZ\nNeedleXYZ")
  return data
end

H.test("search: literal, case-insensitive and regex match a reference across block boundaries", function()
  local dir = U.tmpdir("search")
  local data = build_search_file(9 * MB)
  U.write_file(dir .. "/f", data)
  local c = connect()
  local path = dir .. "/f"
  local want = ref_search(data, "NeedleXYZ", 0, 1000)
  H.ok(#want >= 12, "test data has needles: " .. #want)
  local got = c:request("search", { path = path, pattern = "NeedleXYZ" })
  H.eq(got, want, "literal")
  want = ref_search(data, "NeedleXYZ", 0, 1000, true)
  got = c:request("search", { path = path, pattern = "NEEDLExyz", opts = { case = false } })
  H.eq(got, want, "case-insensitive")
  H.eq(#want, #ref_search(data, "NeedleXYZ", 0, 1000) + 1)
  -- the regex engine works on lines, so the planted two-line needle is two matches there as well
  got = c:request("search", { path = path, pattern = "Needle[XYZ]{3}", opts = { regex = true } })
  local lit = ref_search(data, "NeedleXYZ", 0, 1000)
  H.eq(#got, #lit)
  for i, m in ipairs(got) do H.eq(m, lit[i], "regex match " .. i) end
  -- limit and from_off continuation reproduce the full list, incl. line numbers mid-file
  for _, mode in ipairs({ "literal", "regex", "nocase" }) do
    local opts = ({ literal = {}, regex = { regex = true }, nocase = { case = false } })[mode]
    local pat = mode == "regex" and "Needle[X]YZ" or "NeedleXYZ"
    local full = mode == "nocase" and ref_search(data, "NeedleXYZ", 0, 1000, true) or lit
    local all, from = {}, 0
    while true do
      opts.limit = 3
      local part = c:request("search", { path = path, pattern = pat, opts = opts, from_off = from })
      if #part == 0 then break end
      for _, m in ipairs(part) do all[#all + 1] = m end
      from = part[#part].off + part[#part].len
      H.ok(#all < 100, "runaway continuation")
    end
    H.eq(all, full, "continued " .. mode)
  end
  -- from_off in the middle of a line still gives correct line/col
  local mid = lit[3].off + 3
  got = c:request("search", { path = path, pattern = "XYZ", from_off = mid, opts = { limit = 1 } })
  local ref = ref_search(data, "XYZ", mid, 1)
  H.eq(got, ref, "from_off inside a match line")
  -- stale etag and bad patterns
  local _, err = c:request("search", { path = path, pattern = "x", etag = "1-2-3" })
  H.eq(err.code, "stale")
  _, err = c:request("search", { path = path, pattern = "(", opts = { regex = true } })
  H.eq(err.code, "bad_pattern")
  _, err = c:request("search", { path = path, pattern = "" })
  H.eq(err.code, "bad_request")
  H.eq(c:request("search", { path = path, pattern = "no such text anywhere" }), {})
  H.eq(c:request("search", { path = path, pattern = "NeedleXYZ", from_off = #data + 10 }), {})
  c:close()
end)

H.test("search: small file edge cases and limits", function()
  local dir = U.tmpdir("search2")
  local c = connect()
  local path = dir .. "/f"
  U.write_file(path, "aaaa\nbaaab\n\naa")
  local r = c:request("search", { path = path, pattern = "aa" })
  -- non-overlapping: "aa","aa" on line 1, "aa" on line 2, "aa" on line 4
  H.eq(r, { { off = 0, line = 1, col = 1, len = 2 }, { off = 2, line = 1, col = 3, len = 2 },
            { off = 6, line = 2, col = 2, len = 2 }, { off = 12, line = 4, col = 1, len = 2 } })
  H.eq(#c:request("search", { path = path, pattern = "a", opts = { limit = 5 } }), 5)
  r = c:request("search", { path = path, pattern = "^b", opts = { regex = true } })
  H.eq(r, { { off = 5, line = 2, col = 1, len = 1 } })
  r = c:request("search", { path = path, pattern = "a$", opts = { regex = true } })
  H.eq(#r, 2)
  r = c:request("search", { path = path, pattern = "b.*b", opts = { regex = true } })
  H.eq(r, { { off = 5, line = 2, col = 1, len = 5 } })
  -- unicode in case-insensitive mode
  U.write_file(path, "h\xc3\xa9llo H\xc3\x89LLO\n")
  r = c:request("search", { path = path, pattern = "h\xc3\xa9llo", opts = { case = false } })
  H.eq(#r, 2, "case-insensitive match of non-ASCII")
  H.eq(r[2].col, 8)
  -- empty file
  U.write_file(path, "")
  H.eq(c:request("search", { path = path, pattern = "a" }), {})
  c:close()
end)

H.test("search: regex columns stay right in a line longer than the scan window", function()
  local dir = U.tmpdir("search3")
  local c = connect()
  local path = dir .. "/long"
  local pad = 5 * 1024 * 1024   -- the regex scanner cuts lines at 4 MiB
  U.write_file(path, "x\n" .. string.rep("a", pad) .. "XYZ\nXYZ\n")
  local want = { { off = 2 + pad, line = 2, col = pad + 1, len = 3 }, { off = 2 + pad + 4, line = 3, col = 1, len = 3 } }
  H.eq(c:request("search", { path = path, pattern = "X.Z", opts = { regex = true } }), want)
  H.eq(c:request("search", { path = path, pattern = "xyz", opts = { case = false } }), want)
  c:close()
end)

-- multi hundred MB files -----------------------------------------------

local function make_sparse(path, size, pieces)
  local f = assert(io.open(path, "wb"))
  for _, p in ipairs(pieces) do
    f:seek("set", p.off < 0 and size + p.off or p.off)
    f:write(p.data)
  end
  f:seek("set", size - 1)
  local cur = f:seek("cur")
  f:close()
  -- make sure the file really has the requested size
  os.execute("truncate -s " .. size .. " " .. U.shq(path))
end

local function numbered_lines(prefix, n)
  local t = {}
  for i = 1, n do t[i] = string.format("%s line %07d\n", prefix, i) end
  return table.concat(t)
end

local SPARSE_SIZE = 400 * MB

local function sparse_fixture()
  local dir = U.tmpdir("sparse")
  local path = dir .. "/big"
  local head = numbered_lines("head", 3000)
  local mid = numbered_lines("mid", 20000)
  local tail = numbered_lines("tail", 50) .. "the-end-needle\n"
  make_sparse(path, SPARSE_SIZE, {
    { off = 0, data = head }, { off = 150 * MB + 17, data = mid }, { off = -#tail, data = tail },
  })
  return dir, path, { head = head, mid = mid, tail = tail }
end

H.test("large: lineindex of a 400 MB sparse file is fast and exact", function()
  local dir, path, parts = sparse_fixture()
  local c = connect()
  local cs = 65536
  local dt, li = timed("lineindex 400 MB sparse (cold)", function()
    return c:request("lineindex", { path = path, chunk_size = cs }, 120)
  end)
  H.ok(dt < 5, "lineindex too slow: " .. dt)
  H.eq(li.size, SPARSE_SIZE)
  H.eq(#li.chunks, (SPARSE_SIZE + cs - 1) // cs)
  H.eq(li.ends_with_nl, true)
  local total, sum = 0, 0
  for _, ch in ipairs(li.chunks) do total = total + ch[2]; sum = sum + ch[1] end
  H.eq(sum, SPARSE_SIZE)
  local wc = tonumber(U.sh("wc -l < " .. U.shq(path)):match("%d+"))
  H.eq(total, wc, "total newlines vs wc -l")
  H.eq(total, 3000 + 20000 + 51)
  -- every chunk's newline count, verified against the file contents
  local f = assert(io.open(path, "rb"))
  local bad = 0
  for i, ch in ipairs(li.chunks) do
    local piece = f:read(ch[1])
    if #piece ~= ch[1] or (ch[2] > 0 and U.count_lf(piece) ~= ch[2]) or (ch[2] == 0 and piece:find("\n", 1, true)) then
      bad = bad + 1
    end
  end
  f:close()
  H.eq(bad, 0, "chunks with a wrong length or newline count")
  local dt2 = timed("lineindex 400 MB sparse (cached)", function()
    return c:request("lineindex", { path = path, chunk_size = cs })
  end)
  H.ok(dt2 < 0.5, "cached lineindex too slow")
  -- reading across holes and data
  local got = c:request("read_range", { path = path, off = 0, len = 100, etag = li.etag })
  H.eq(got, parts.head:sub(1, 100))
  got = c:request("read_range", { path = path, off = 150 * MB + 17 - 10, len = 30, etag = li.etag })
  H.eq(got, string.rep("\0", 10) .. parts.mid:sub(1, 20))
  got = c:request("read_range", { path = path, off = SPARSE_SIZE - #parts.tail, len = #parts.tail })
  H.eq(got, parts.tail)
  c:close()
end)

H.test("large: server stays responsive while a big file is indexed, and cancel works", function()
  local dir = U.tmpdir("dense")
  local path = dir .. "/dense"
  -- 256 MB of dense text lines: real I/O and newline counting
  U.sh("yes 'dense text line for the throughput test of lineindex' | head -c " .. (256 * MB) .. " > " .. U.shq(path))
  local c = connect()
  local sz = c:request("stat", { path = path }).size
  H.eq(sz, 256 * MB)
  local lid = c:send_request("lineindex", { path = path, chunk_size = 65536 })
  local pid = c:send_request("ping", { data = "quick" })
  local first = c:recv(30)
  H.eq(first.id, pid, "ping must be answered while lineindex runs")
  H.eq(first.ok, "quick")
  local r = c:wait_response(lid, 120)
  local wc = tonumber(U.sh("wc -l < " .. U.shq(path)):match("%d+"))
  local total = 0
  for _, ch in ipairs(r.chunks) do total = total + ch[2] end
  H.eq(total, wc)
  -- throughput of a cold index of a dense file
  U.sh("sleep 0.05; touch " .. U.shq(path))
  local dt = timed("lineindex 256 MB dense text (cold)", function()
    return c:request("lineindex", { path = path, chunk_size = 65536 }, 120)
  end)
  H.ok(dt < 20, "dense lineindex too slow: " .. dt)
  -- cancel an index in flight
  U.sh("sleep 0.05; touch " .. U.shq(path))
  local t0 = system.get_time()
  lid = c:send_request("lineindex", { path = path, chunk_size = 65536 })
  c:send({ cancel = lid })
  local _, err = c:wait_response(lid, 30)
  H.ok(err == nil or err.code == "cancelled")
  H.ok(system.get_time() - t0 < 30)
  H.eq(c:request("ping", { data = 1 }), 1)
  c:close()
end)

H.test("large: apply_edit on a 400 MB file is byte-exact against an independent dd-built copy", function()
  local dir, path, parts = sparse_fixture()
  local c = connect()
  local cs = 65536
  local li = c:request("lineindex", { path = path, chunk_size = cs }, 120)
  local a, b = 12345, 150 * MB + 100
  local d1, d2 = 777, 3 * MB + 5
  local ins1, ins2, ins3 = "INSERTED line one\nINSERTED line two\n", "no newline here", "\nlast\n"
  local script = {
    { keep = true, off = 0, len = a }, { ins = 1 },
    { keep = true, off = a + d1, len = b - a - d1 }, { ins = 2 },
    { keep = true, off = b + d2, len = SPARSE_SIZE - b - d2 }, { ins = 3 },
  }
  local inserts = { ins1, ins2, ins3 }
  -- independent construction with dd/printf
  local exp = dir .. "/expected"
  local function dd(off, len)
    local out, code = U.sh(string.format("dd if=%s of=%s bs=4M iflag=skip_bytes,count_bytes skip=%d count=%d oflag=append conv=notrunc status=none",
      U.shq(path), U.shq(exp), off, len))
    H.eq(code, 0, out)
  end
  local function append(s) U.write_file(dir .. "/ins.tmp", s); U.sh("cat " .. U.shq(dir .. "/ins.tmp") .. " >> " .. U.shq(exp)) end
  U.sh("rm -f " .. U.shq(exp))
  dd(0, a); append(ins1)
  dd(a + d1, b - a - d1); append(ins2)
  dd(b + d2, SPARSE_SIZE - b - d2); append(ins3)
  local expected_size = tonumber(U.sh("stat -c %s " .. U.shq(exp)):match("%d+"))
  local dt, r, err = timed("apply_edit 400 MB (3 edits)", function()
    return c:request("apply_edit", { path = path, etag = li.etag, script = script, inserts = inserts }, 300)
  end)
  H.ok(r, "apply_edit failed: " .. tostring(err and err.code) .. " " .. tostring(err and err.msg))
  H.eq(r.size, expected_size)
  local out, code = U.sh("cmp " .. U.shq(path) .. " " .. U.shq(exp))
  H.eq(code, 0, "cmp: " .. out)
  H.eq(r.ends_with_nl, true)
  -- the incrementally computed chunk table is exact
  local f = assert(io.open(path, "rb"))
  local pos, bad, total = 0, 0, 0
  for i, ch in ipairs(r.chunks) do
    H.ok(ch[1] <= cs and ch[1] > 0, "chunk length bounds")
    local piece = f:read(ch[1])
    if #piece ~= ch[1] or U.count_lf(piece) ~= ch[2] then bad = bad + 1 end
    pos = pos + ch[1]; total = total + ch[2]
  end
  f:close()
  H.eq(pos, expected_size); H.eq(bad, 0, "chunks with a wrong newline count")
  H.eq(total, tonumber(U.sh("wc -l < " .. U.shq(exp)):match("%d+")))
  H.ok(#r.chunks < (expected_size // cs) * 1.05 + 10, "chunk table is not fragmented: " .. #r.chunks)
  -- a second edit chained on the returned etag (no re-index), then a fresh index agrees
  local r2 = c:request("apply_edit", { path = path, etag = r.etag,
    script = { { keep = true, off = 0, len = 100 }, { ins = 1 }, { keep = true, off = 100, len = r.size - 100 } },
    inserts = { "chained\n" } }, 300)
  H.eq(r2.size, r.size + 8)
  local fresh = c:request("lineindex", { path = path, chunk_size = cs }, 120)
  H.eq(fresh.etag, r2.etag)
  local t1, t2 = 0, 0
  for _, ch in ipairs(fresh.chunks) do t1 = t1 + ch[2] end
  for _, ch in ipairs(r2.chunks) do t2 = t2 + ch[2] end
  H.eq(t1, t2)
  H.eq(t1, total + 1)
  H.eq(U.ls(dir), { "big", "expected", "ins.tmp" }, "no temp files left")
  c:close()
end)

H.test("large: search on a 400 MB file finds a needle at the end with the right line number", function()
  local dir, path, parts = sparse_fixture()
  local c = connect()
  local dt, r = timed("search 400 MB sparse (literal, cold index)", function()
    return c:request("search", { path = path, pattern = "the-end-needle" }, 120)
  end)
  H.eq(#r, 1)
  H.eq(r[1].off, SPARSE_SIZE - 15); H.eq(r[1].col, 1); H.eq(r[1].len, 14)
  H.eq(r[1].line, 3000 + 20000 + 50 + 1)
  dt, r = timed("search 400 MB sparse (from_off near the end)", function()
    return c:request("search", { path = path, pattern = "tail line 0000042", from_off = SPARSE_SIZE - 3000 }, 120)
  end)
  H.eq(#r, 1); H.eq(r[1].line, 3000 + 20000 + 42)
  dt, r = timed("search 400 MB sparse (regex)", function()
    return c:request("search", { path = path, pattern = "mid line 0+19999$", opts = { regex = true } }, 120)
  end)
  H.eq(#r, 1); H.eq(r[1].line, 3000 + 19999)
  H.eq(r[1].off, 150 * MB + 17 + 19998 * #string.format("mid line %07d\n", 1))
  c:close()
end)

H.test("large: a multi-GB sparse file is indexed instantly; oversized chunk tables are refused", function()
  local dir = U.tmpdir("huge")
  local path = dir .. "/huge"
  local size = 6 * 1024 * MB
  make_sparse(path, size, { { off = 0, data = "first\n" }, { off = -7, data = "last 7\n" } })
  local c = connect()
  local dt, r = timed("lineindex 6 GiB sparse (64 KiB chunks)", function()
    return c:request("lineindex", { path = path, chunk_size = 65536 }, 120)
  end)
  H.eq(r.size, size); H.eq(#r.chunks, size // 65536); H.eq(r.ends_with_nl, true)
  local total = 0
  for _, ch in ipairs(r.chunks) do total = total + ch[2] end
  H.eq(total, 2)
  H.ok(dt < 10, "too slow: " .. dt)
  local _, err = c:request("lineindex", { path = path, chunk_size = 4096 }, 120)
  H.eq(err.code, "too_large")
  H.ok(err.min_chunk_size >= 4096 and err.min_chunk_size < 65536, "min_chunk_size hint: " .. tostring(err.min_chunk_size))
  c:close()
end)

H.test("cleanup: large tests", function() U.cleanup() end)
