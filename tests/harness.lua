-- Minimal test harness for tests/remote. Works under plain Lua 5.4+ and under
-- `thither-server --run`.
local H = { tests = {} }

function H.test(name, fn)
  H.tests[#H.tests + 1] = { name = name, fn = fn }
end

local function deep_eq(a, b, seen)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then
    return a ~= a and b ~= b  -- NaN
  end
  if type(a) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do
    if not deep_eq(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function show(v, depth)
  depth = depth or 0
  if type(v) == "string" then
    if #v > 60 then return string.format("%q...(%d bytes)", v:sub(1, 60), #v) end
    return string.format("%q", v)
  elseif type(v) == "table" and depth < 3 then
    local parts = {}
    for k, x in pairs(v) do
      parts[#parts + 1] = "[" .. show(k, depth + 1) .. "]=" .. show(x, depth + 1)
      if #parts >= 12 then parts[#parts + 1] = "..." break end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

function H.eq(a, b, msg)
  if not deep_eq(a, b) then
    error((msg and (msg .. ": ") or "") .. "expected " .. show(b) .. ", got " .. show(a), 2)
  end
end

function H.ok(v, msg)
  if not v then error(msg or "assertion failed", 2) end
  return v
end

--- Asserts that fn raises an error whose message contains `pattern` (plain).
function H.raises(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then error((msg or "expected an error") .. ": none raised", 2) end
  if pattern and not tostring(err):find(pattern, 1, true) then
    error((msg or "wrong error") .. ": expected '" .. pattern .. "' in '" .. tostring(err) .. "'", 2)
  end
  return err
end

function H.hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function H.unhex(h)
  return (h:gsub("%s", ""):gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

--- Runs every registered test whose name contains `filter` (plain).
--- Returns passed, failed.
function H.run(filter, quiet)
  local passed, failed = 0, 0
  for _, t in ipairs(H.tests) do
    if not filter or t.name:find(filter, 1, true) then
      local t0 = os.clock()
      local ok, err = xpcall(t.fn, function(e)
        if type(e) == "string" then return e .. "\n" .. debug.traceback("", 2) end
        return e
      end)
      if ok then
        passed = passed + 1
        if not quiet then print(string.format("ok   %-64s %.2fs", t.name, os.clock() - t0)) end
      else
        failed = failed + 1
        print(string.format("FAIL %-64s\n     %s", t.name, (tostring(err):gsub("\n", "\n     "))))
      end
    end
  end
  return passed, failed
end

--- True when the calling file is the script run from the command line (and
--- not loaded by tests/run.lua).
function H.standalone(name)
  return arg and arg[0] and arg[0]:find(name, 1, true) ~= nil and not RUN_ALL
end

return H
