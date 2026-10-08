-- Sample thither-server plugin. Copy it to ~/.config/thither/plugins/
-- (or point --plugins at this directory) and call it from the client with
--   call { service = "echo", method = "echo", args = { ... } }
local server = require "thither"

local started_at

server.on_start(function(ctx)
  started_at = os.time()
  server.log("echo plugin ready (server %s)", ctx.version)
end)

server.on_root(function(path)
  server.log("echo plugin: project root is %s", path)
end)

server.register("echo", {
  -- returns its arguments unchanged
  echo = function(args)
    return args
  end,

  -- returns the uppercased text; errors are reported as protocol errors
  upper = function(args)
    if type(args) ~= "table" or type(args.text) ~= "string" then
      server.raise("bad_request", "args.text must be a string")
    end
    return args.text:upper()
  end,

  -- streams `n` events before answering, honouring cancellation
  count = function(args, req)
    for i = 1, args.n or 3 do
      req:emit({ i = i })
      req:sleep(args.delay_ms or 10)
    end
    return args.n or 3
  end,

  -- uses the real filesystem of the server
  stat = function(args)
    return server.unwrap(require("serverfs").stat(server.path(args.path)))
  end,

  -- string.rep as a service (handy to test response size limits)
  rep = function(args)
    return string.rep(args.text, args.n)
  end,

  uptime = function()
    return os.time() - started_at
  end,
})
