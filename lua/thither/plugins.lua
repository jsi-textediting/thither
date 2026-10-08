-- Server plugin loader.
--
-- Plugins are Lua files (or directories with an init.lua) found in the
-- directories given with --plugins, or in <USERDIR>/plugins when none is given
-- (USERDIR is $THITHER_USERDIR or ~/.config/thither). They run in
-- the server process with the real system/process/io/serverfs libraries and
-- talk to the framework through the `server` module:
--
--   local server = require "thither"
--   server.register("greeter", { hello = function(args, req) return "hi " .. args.name end })
--   server.on_start(function(ctx) end)        -- ctx: root, home, userdir, version
--   server.on_root(function(path) end)        -- the client declared its project root
--   server.on_shutdown(function() end)
--   server.notify("progress", { done = 3 })   -- pushes { ev = "notify", name, data }
--
-- A method receives (args, req). It may return a value (the response), return
-- nil, code, message (an error response) or raise server.raise(code, msg).
-- req:emit(data) streams events, req:sleep(ms) / req:yield() cooperate with
-- the loop and req.cancelled / req:check() observe client cancellation.
local serverfs = require "serverfs"

return function(server)
  local function load_one(path, label)
    local chunk, err = loadfile(path)
    if not chunk then
      server.log("plugin %s: %s", label, tostring(err))
      io.stderr:write("thither-server: plugin ", label, ": ", tostring(err), "\n")
      return
    end
    local ok, perr = xpcall(chunk, debug.traceback, server)
    if not ok then
      server.log("plugin %s failed: %s", label, tostring(perr))
      io.stderr:write("thither-server: plugin ", label, " failed: ", tostring(perr), "\n")
    else
      server.log("loaded plugin %s", label)
    end
  end

  local function load_dir(dir)
    local entries = serverfs.readdir(dir, 0, 10000)
    if not entries then return end
    for _, e in ipairs(entries) do
      if e.type == "file" and e.name:match("%.lua$") then
        load_one(dir .. "/" .. e.name, e.name)
      elseif e.type == "dir" and serverfs.stat(dir .. "/" .. e.name .. "/init.lua") then
        local saved = package.path
        package.path = dir .. "/" .. e.name .. "/?.lua;" .. package.path
        load_one(dir .. "/" .. e.name .. "/init.lua", e.name)
        package.path = saved
      end
    end
  end

  local dirs = server.opts.plugins
  if not dirs or #dirs == 0 then dirs = { server.userdir .. "/plugins" } end
  for _, d in ipairs(dirs) do load_dir(d) end
end
