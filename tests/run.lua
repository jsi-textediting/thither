-- Test runner for the remote protocol suite. Run it with the server binary,
-- which provides the process/system libraries the loopback tests need:
--
--   thither-server --run tests/run.lua [--datadir <dir>] [filter]
--
-- (--datadir is a server option and goes before --run when needed:
--  thither-server --datadir lua --run tests/run.lua)
--
-- `filter` restricts the run to tests whose name contains it. The pure-Lua
-- msgpack/frame tests can also be run with a plain interpreter:
--   lua tests/test_msgpack.lua; lua tests/test_frame.lua
RUN_ALL = true
local dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local H = require "harness"

local filter = arg and arg[1]
for _, name in ipairs({ "test_msgpack", "test_frame", "test_paths", "test_server", "test_fs", "test_exec_watch", "test_large", "test_embed", "test_copies" }) do
  dofile(dir .. "/" .. name .. ".lua")
end

local t0 = os.time()
local passed, failed = H.run(filter)
print(string.format("\n%d passed, %d failed (%ds)", passed, failed, os.time() - t0))
return failed == 0 and 0 or 1
