-- Phase-0 spike (a): do the remote mount-root path forms survive the path
-- helpers of data/core/common.lua and data/core/project.lua?
--   POSIX client:   /.lxl-remote/<host>/<abs path>
--   Windows client: \\lxl-remote\<host>\<abs path with \>
-- Both forms are exercised on any OS by switching PATHSEP, using the real
-- common.lua and project.lua (with minimal stubs for core/config).
-- Findings and the proposed patches are in docs/protocol.md ("Path forms").
-- Runs under plain Lua 5.4+:  lua thither/tests/test_paths.lua
-- This is a test of the Lite XL client's path handling: it needs the editor's
-- data/ directory next to thither/ and is skipped without it.
local dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/../../data/?.lua;" .. package.path
local H = require "harness"
local probe = io.open(dir .. "/../../data/core/common.lua", "rb")
if not probe then return end
probe:close()

local saved = {}
local function with_env(pathsep, fn)
  local g_saved = { PATHSEP = PATHSEP, PLATFORM = PLATFORM, HOME = HOME }
  local m_saved = { core = package.loaded["core"], config = package.loaded["core.config"],
                    common = package.loaded["core.common"], project = package.loaded["core.project"] }
  PATHSEP = pathsep
  PLATFORM = pathsep == "\\" and "Windows" or "Linux"
  HOME = pathsep == "\\" and "C:\\Users\\u" or "/home/u"
  package.loaded["core"] = {}
  package.loaded["core.config"] = { ignore_files = {} }
  package.loaded["core.common"] = nil
  package.loaded["core.project"] = nil
  local ok, err = pcall(function()
    local common = require "core.common"
    local Project = require "core.project"
    fn(common, Project)
  end)
  PATHSEP, PLATFORM, HOME = g_saved.PATHSEP, g_saved.PLATFORM, g_saved.HOME
  package.loaded["core"], package.loaded["core.config"] = m_saved.core, m_saved.config
  package.loaded["core.common"], package.loaded["core.project"] = m_saved.common, m_saved.project
  if not ok then error(err, 0) end
end

local function try(f, ...)
  local ok, a = pcall(f, ...)
  return ok and a or ("ERR: " .. tostring(a))
end

H.test("paths: POSIX form /.lxl-remote/<host>/<abs> survives common.lua and Project", function()
  with_env("/", function(common, Project)
    local root = "/.lxl-remote/my host/home/u/proj"
    local file = root .. "/src/a.lua"
    H.eq(common.normalize_path(root), root)
    H.eq(common.normalize_path("/.lxl-remote/h/a/../b/./c//d"), "/.lxl-remote/h/b/c/d")
    H.eq(common.normalize_volume(root), root)
    H.ok(common.is_absolute_path(root))
    H.eq(common.basename(root), "proj")
    H.eq(common.dirname(root), "/.lxl-remote/my host/home/u")
    H.eq(common.dirname("/.lxl-remote/h"), "/.lxl-remote")
    H.eq(common.dirname("/.lxl-remote"), nil, "walking up stops below '/'")
    H.ok(common.path_belongs_to(file, root))
    H.ok(not common.path_belongs_to("/.lxl-remote/h2/home/u/proj/x", "/.lxl-remote/h/home/u/proj"), "other host")
    H.ok(not common.path_belongs_to(root .. "2/f", root), "sibling with the same prefix")
    H.ok(not common.path_belongs_to("/home/u/proj/x", root), "local path vs remote root")
    H.eq(common.relative_path(root, file), "src/a.lua")
    local p = Project(common.normalize_volume(root))
    H.eq(p.name, "proj"); H.eq(p.path, root)
    H.eq(p:normalize_path(file), "src/a.lua")
    H.eq(p:normalize_path("/.lxl-remote/h2/x"), "/.lxl-remote/h2/x", "other host stays absolute")
    H.eq(p:absolute_path("src/a.lua"), root .. "/src/a.lua")
    H.eq(p:absolute_path(file), file)
    -- project rooted at the remote filesystem root
    local top = Project("/.lxl-remote/h")
    H.eq(top.name, "h")
    H.eq(top:normalize_path("/.lxl-remote/h/etc/passwd"), "etc/passwd")
    H.eq(top:absolute_path("etc"), "/.lxl-remote/h/etc")
    -- ".." out of the host directory lands in the (virtual) mount directory
    H.eq(common.normalize_path("/.lxl-remote/h/../x/y"), "/.lxl-remote/x/y")
  end)
end)

H.test("paths: Windows form \\\\lxl-remote\\<host>\\<abs with \\> survives for paths below the host", function()
  with_env("\\", function(common, Project)
    local root = "\\\\lxl-remote\\my host\\home\\u\\proj"
    local file = root .. "\\src\\a.lua"
    H.eq(common.normalize_path(root), root)
    H.eq(common.normalize_path("//lxl-remote/my host/home/u/proj/src/a.lua"), file, "forward slashes are converted")
    H.eq(common.normalize_path("\\\\lxl-remote\\h\\a\\..\\b\\.\\c"), "\\\\lxl-remote\\h\\b\\c")
    H.eq(common.normalize_volume(root), root)
    H.ok(common.is_absolute_path(root))
    H.eq(common.basename(root), "proj")
    H.eq(common.dirname(root), "\\\\lxl-remote\\my host\\home\\u")
    H.ok(common.path_belongs_to(file, root))
    H.ok(not common.path_belongs_to("\\\\lxl-remote\\h2\\home\\u\\proj\\x", "\\\\lxl-remote\\h\\home\\u\\proj"), "other host")
    H.ok(not common.path_belongs_to(root .. "2\\f", root), "sibling with the same prefix")
    H.eq(common.relative_path(root, file), "src\\a.lua")
    local p = Project(common.normalize_volume(root))
    H.eq(p.name, "proj"); H.eq(p.path, root)
    H.eq(p:normalize_path(file), "src\\a.lua")
    H.eq(p:normalize_path("\\\\lxl-remote\\h2\\x\\y"), "\\\\lxl-remote\\h2\\x\\y", "other host stays absolute")
    H.eq(p:absolute_path("src\\a.lua"), root .. "\\src\\a.lua")
    H.eq(p:absolute_path(file), file)
    -- the same host-root behaviour as a drive root
    H.eq(common.normalize_path("\\\\lxl-remote\\h\\home"), "\\\\lxl-remote\\h\\home")
    H.eq(p:normalize_path("\\\\lxl-remote\\my host\\home\\u\\proj"), "\\\\lxl-remote\\my host\\home\\u\\proj",
      "the root itself is not 'belonging' to itself")
  end)
end)

H.test("paths: Windows form edge cases at the host root", function()
  with_env("\\", function(common, Project)
    -- the shipped common.lua includes the patches below: a share root is a volume
    H.eq(common.normalize_path("\\\\lxl-remote\\h"), "\\\\lxl-remote\\h\\", "host root without trailing \\")
    H.eq(common.normalize_path("\\\\lxl-remote\\h\\"), "\\\\lxl-remote\\h\\", "host root with trailing \\")
    H.eq(common.normalize_path("C:\\"), "C:\\\\", "LIMITATION: upstream quirk, a drive root gains a second \\")
    -- '..' above the share root raises, like it does above C:\
    H.ok(tostring(try(common.normalize_path, "\\\\lxl-remote\\h\\..")):find("invalid path", 1, true))
    -- a forward-slash spelling is not "absolute" until normalized
    H.ok(not common.is_absolute_path("//lxl-remote/h/a"))
    -- basename of the bare host root is the whole path (cosmetic: Project.name)
    H.eq(common.basename("\\\\lxl-remote\\h\\"), "\\\\lxl-remote\\h\\")
    H.eq(common.dirname("\\\\lxl-remote\\h\\home"), "\\\\lxl-remote\\h")
    H.eq(common.dirname("\\\\lxl-remote\\h"), "\\\\lxl-remote")
    -- a UNC remote root and a local drive are different volumes
    H.eq(common.relative_path("\\\\lxl-remote\\h\\home\\u", "C:\\Windows"), "C:\\Windows")
  end)
end)

-- the proposed patches (see docs/protocol.md), applied to the loaded module
local function patched(common)
  -- Patch A (common.normalize_path): a UNC share root without trailing separator
  -- is a volume too, and a path that is only a volume is returned as is
  -- (instead of gaining a second separator).
  function common.normalize_path(filename)
    if not filename then return end
    local volume
    if PATHSEP == '\\' then
      filename = filename:gsub('[/\\]', '\\')
      local drive, rem = filename:match('^([a-zA-Z]:\\)(.*)')
      if drive then
        volume, filename = drive:upper(), rem
      else
        drive, rem = filename:match('^(\\\\[^\\]+\\[^\\]+\\)(.*)')
        if not drive then
          local share = filename:match('^(\\\\[^\\]+\\[^\\]+)$')
          if share then drive, rem = share .. '\\', '' end
        end
        if drive then
          volume, filename = drive, rem
        end
      end
    else
      local relpath = filename:match('^/(.+)')
      if relpath then
        volume, filename = "/", relpath
      end
    end
    local parts = {}
    if filename:match("^[" .. PATHSEP .. "]") then parts[#parts + 1] = "" end
    for fragment in string.gmatch(filename, "([^" .. PATHSEP .. "]+)") do parts[#parts + 1] = fragment end
    local accu = {}
    for _, part in ipairs(parts) do
      if part == '..' then
        if #accu > 0 and accu[#accu] ~= ".." then
          table.remove(accu)
        elseif volume then
          error("invalid path " .. volume .. filename)
        else
          table.insert(accu, part)
        end
      elseif part ~= '.' then
        table.insert(accu, part)
      end
    end
    local npath = table.concat(accu, PATHSEP)
    if npath == "" then return volume or PATHSEP end
    return (volume or "") .. npath
  end

  -- Patch B (common.relative_path): a UNC share is a volume like a drive letter.
  local orig_relative = common.relative_path
  function common.relative_path(ref_dir, dir)
    local function volume_of(p) return p:match("^(%a):\\") or p:match("^(\\\\[^\\]+\\[^\\]+)") end
    local v1, v2 = volume_of(dir), volume_of(ref_dir)
    if v1 and v2 and v1 ~= v2 then return dir end
    return orig_relative(ref_dir, dir)
  end
end

H.test("paths: the proposed common.lua patches fix the host-root edge cases", function()
  with_env("\\", function(common)
    patched(common)
    H.eq(common.normalize_path("\\\\lxl-remote\\h"), "\\\\lxl-remote\\h\\")
    H.eq(common.normalize_path("//lxl-remote/h"), "\\\\lxl-remote\\h\\")
    H.eq(common.normalize_path("\\\\lxl-remote\\h\\"), "\\\\lxl-remote\\h\\")
    H.eq(common.normalize_path("\\\\lxl-remote\\h\\home\\u"), "\\\\lxl-remote\\h\\home\\u", "unchanged below the root")
    H.eq(common.normalize_path("C:\\foo\\..\\bar"), "C:\\bar", "local paths unchanged")
    H.eq(common.relative_path("\\\\lxl-remote\\h\\home\\u", "C:\\Windows"), "C:\\Windows")
    H.eq(common.relative_path("\\\\lxl-remote\\h\\home\\u", "\\\\lxl-remote\\h2\\x"), "\\\\lxl-remote\\h2\\x")
    H.eq(common.relative_path("\\\\lxl-remote\\h\\home\\u", "\\\\lxl-remote\\h\\home\\u\\a\\b"), "a\\b")
    H.eq(common.relative_path("C:\\a", "C:\\a\\b"), "b")
    H.eq(common.relative_path("C:\\a", "D:\\b"), "D:\\b")
  end)
end)

if H.standalone("test_paths.lua") then
  local p, f = H.run()
  print(string.format("%d passed, %d failed", p, f))
  os.exit(f == 0 and 0 or 1)
end
