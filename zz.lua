local M = {}

local argparser = require('argparser')
local process = require('process')
local env = require('env')
local fs = require('fs')
local re = require('re')
local inspect = require('inspect')
local util = require('util')
local bcsave = require('jit.bcsave')
local sha1 = require('sha1')
local ffi = require('ffi')
local adt = require('adt')

local quiet = false

local function log(msg, ...)
   if not quiet then
      pf(sf(msg, ...))
   end
end

local function die(msg, ...)
   pf("ERROR: %s", sf(msg, ...))
   process.exit(1)
end

local ZZPATH = env['ZZPATH'] or sf("%s/zz", env['HOME'] or die("HOME unset"))

local function usage()
   pf [[
Usage: zz <command> [options] [args]

Available commands:

zz checkout [-u] <package> [<ref>]

  1. If $ZZPATH/src/<package> does not exist yet:

     git clone <package> into $ZZPATH/src/<package>

     Otherwise run `git fetch' under $ZZPATH/src/<package>

  2. Run `git checkout <ref>' under $ZZPATH/src/<package>

     <ref> defaults to `master'

  3. If -u has been given:

     Run `git pull` under $ZZPATH/src/<package>

zz build [<package>]

  Parse package descriptor P of the given <package> and build P
  according to the instructions inside the descriptor:

  1. For each native dependency N in P.native:

     a. download N
     b. extract N
     c. patch N (if needed)
     d. compile N
     e. copy the library to $ZZPATH/lib/<package>/libN.a

  2. For each module M in P.exports:

     a. compile M.lua into M.lo
     b. compile M.c into M.o (if it exists)
     c. add M.lo and M.o to $ZZPATH/lib/<package>/libP.a

  3. For each app A in P.apps:

     a. compile A.lua into A.lo
     b. compile A.c into A.o (if A.c exists)
     c. generate and compile _main.lua which:
        i.  requires A
        ii. invokes A.main() if it exists
     d. generate and compile _main.c which:
        i.  initalizes a LuaJIT VM
        ii. requires the _main module
     e. link _main.lo and _main.o with:
        i.   A.lo (and A.o if it exists)
        ii.  the library set of P
        iii. the library sets of all packages listed in P.imports
     f. save the resulting executable to $ZZPATH/bin/<package>/A

  The library set of package P consists of:

     a. $ZZPATH/lib/<package>/libP.a
     b. all native dependencies listed in P.native

  Without a <package> argument, attempt to determine which package
  contains the current directory (by looking for the package
  descriptor) and build that.

]]
   process.exit(0)
end

local function find_package_descriptor()
   local pd_path
   local found = false
   local cwd = process.getcwd()
   while not found do
      pd_path = fs.join(cwd, 'package.lua')
      if fs.exists(pd_path) then
         found = true
      elseif cwd == '/' then
         break
      else
         cwd = fs.dirname(cwd)
      end
   end
   return found and pd_path or nil
end

local function PackageDescriptor(package_name)
   local pd, pd_path
   if not package_name or package_name == '.' then
      pd_path = find_package_descriptor()
   elseif type(package_name) == "string" then
      pd_path = fs.join(ZZPATH, 'src', package_name, 'package.lua')
   end
   if fs.exists(pd_path) then
      pd = loadfile(pd_path)()
   end
   if not pd then
      if package_name then
         die("cannot find package: %s", package_name)
      else
         die("no package")
      end
   end
   if not pd.package then
      die("missing package field in package descriptor: %s", pd_path)
   end
   -- name of the static library (of modules) generated by this package
   pd.libname = pd.libname or fs.basename(pd.package)
   -- external zz packages used by this package
   pd.imports = pd.imports or {}
   -- native C libraries used by this package
   pd.native = pd.native or {}
   -- modules exported by this package (Lua/C)
   pd.exports = pd.exports or {}
   -- compile-time dependencies of modules
   pd.depends = pd.depends or {}
   -- apps (executables) generated by this package
   pd.apps = pd.apps or {}
   -- apps which shall be symlinked into $ZZPATH/bin
   pd.install = pd.install or {}
   return pd
end

local Target = util.Class()

local function is_target(x)
   return type(x)=="table" and x.is_target
end

local function flatten(targets)
   local rv = {}
   local function add(x)
      if is_target(x) then
         table.insert(rv, x)
      elseif type(x) == "table" then
         for _,t in ipairs(x) do
            add(t)
         end
      end
   end
   add(targets)
   return rv
end

function Target:create(opts)
   assert(type(opts)=="table")
   opts.depends = flatten(opts.depends)
   if opts.dirname and opts.basename then
      opts.path = fs.join(opts.dirname, opts.basename)
   end
   opts.is_target = true
   return opts
end

function Target:mtime()
   if self.path and fs.exists(self.path) then
      return fs.stat(self.path).mtime
   else
      return -1
   end
end

function Target:make()
   local my_mtime = self:mtime()
   local changed = {} -- list of dependencies which have been updated
   local max_mtime = 0
   for _,t in ipairs(self.depends) do
      assert(is_target(t))
      t:make()
      local mtime = t:mtime()
      if mtime > my_mtime then
         table.insert(changed, t)
      end
      if mtime > max_mtime then
         max_mtime = mtime
      end
   end
   if my_mtime < max_mtime and self.build then
      log("[BUILD] %s", self.basename)
      if self.dirname then
         fs.mkpath(self.dirname)
      end
      self:build(changed)
      if self.path then
         fs.touch(self.path)
      end
   end
end

local function target_path(x)
   if is_target(x) and x.path then
      return x.path
   elseif type(x) == "string" then
      return x
   else
      ef("target_path() not applicable for %s", inspect(x))
   end
end

local function target_paths(targets)
   return util.map(target_path, targets)
end

local function with_cwd(cwd, fn)
   local oldcwd = process.getcwd()
   process.chdir(cwd or '.')
   local ok, err = pcall(fn)
   process.chdir(oldcwd)
   if not ok then
      die(err)
   end
end

function system(args)
   local msg = args
   if type(msg) == "table" then
      msg = table.concat(args, " ")
   end
   log(msg)
   return process.system(args)
end

local BuildContext = util.Class()

local context_cache = {}

local function get_build_context(package_name)
   if not package_name or package_name == '.' then
      local pd_path = find_package_descriptor()
      if not pd_path then
         die("no package")
      end
      local pd = loadfile(pd_path)()
      package_name = pd.package
   end
   if not context_cache[package_name] then
      local pd = PackageDescriptor(package_name)
      context_cache[package_name] = BuildContext(pd)
   end
   return context_cache[package_name]
end

function BuildContext:create(pd)
   local ctx = {
      pd = pd,
      vars = {},
      gbindir = fs.join(ZZPATH, "bin"),
      bindir = fs.join(ZZPATH, "bin", pd.package),
      objdir = fs.join(ZZPATH, "obj", pd.package),
      libdir = fs.join(ZZPATH, "lib", pd.package),
      tmpdir = fs.join(ZZPATH, "tmp", pd.package),
      srcdir = fs.join(ZZPATH, "src", pd.package),
   }
   ctx.nativedir = fs.join(ctx.srcdir, "native")
   return ctx
end

function BuildContext:mangle(name)
   -- generate globally unique name for a zz package module
   return 'zz_'..sha1(sf("%s/%s", self.pd.package, name))
end

function BuildContext:set(key, value)
   self.vars[key] = value
end

function BuildContext:get(key)
   return self.vars[key]
end

-- this one still feels ugly
function BuildContext:collect(field, root_key)
   local rv = {}
   local collected = {}
   local function collect(key, field)
      if not collected[key] then
         local targets = self:get(key)
         for _,t in ipairs(targets) do
            util.extend(rv, t[field])
         end
         collected[key] = true
         local depends = self.pd.depends[key]
         if depends then
            for _,dkey in ipairs(depends) do
               collect(dkey, field)
            end
         end
      end
   end
   collect(root_key, field)
   return rv
end

function BuildContext:download(opts)
   with_cwd(opts.cwd, function()
      local status = system {
         "curl",
         "-L",
         "-o", target_path(opts.dst),
         opts.src
      }
      if status ~= 0 then
         die("download failed")
      end
   end)
end

function BuildContext:extract(opts)
   with_cwd(opts.cwd, function()
      local status = system {
         "tar", "xzf", target_path(opts.src)
      }
      if status ~= 0 then
         die("extract failed")
      end
   end)
end

function BuildContext:system(opts)
   with_cwd(opts.cwd, function()
      local status = system(opts.command)
      if status ~= 0 then
         die("command failed")
      end
   end)
end

function BuildContext:compile_c(opts)
   with_cwd(opts.cwd, function()
      local args = { "gcc", "-c", "-Wall" }
      util.extend(args, opts.cflags)
      table.insert(args, "-o")
      table.insert(args, target_path(opts.dst))
      table.insert(args, target_path(opts.src))
      local status = system(args)
      if status ~= 0 then
         die("compile_c failed")
      end
   end)
end

function BuildContext:compile_lua(opts)
   bcsave.start("-t", "o",
                "-n", opts.name,
                "-g",
                target_path(opts.src),
                target_path(opts.dst))
end

function BuildContext:ar(opts)
   with_cwd(opts.cwd, function()
      local status = system {
         "ar", "rsc",
         target_path(opts.dst),
         unpack(target_paths(flatten(opts.src)))
      }
      if status ~= 0 then
         die("ar failed")
      end
   end)
end

function BuildContext:cp(opts)
   with_cwd(opts.cwd, function()
      local status = system {
         "cp",
         target_path(opts.src),
         target_path(opts.dst)
      }
      if status ~= 0 then
         die("copy failed")
      end
   end)
end

function BuildContext:symlink(opts)
   with_cwd(opts.cwd, function()
      local src = target_path(opts.src)
      local dst = target_path(opts.dst)
      if fs.exists(dst) then
         fs.unlink(dst)
      end
      fs.symlink(src, dst)
   end)
end

function BuildContext:link(opts)
   local args = {
      "gcc",
      "-o", target_path(opts.dst),
      "-Wl,--export-dynamic",
   }
   table.insert(args, "-Wl,--whole-archive")
   util.extend(args, target_paths(flatten(opts.src)))
   table.insert(args, "-Wl,--no-whole-archive")
   util.extend(args, opts.ldflags)
   local status = system(args)
   if status ~= 0 then
      die("link failed")
   end
end

function BuildContext.Target(ctx, opts)
   return Target(opts)
end

function BuildContext.LuaModuleTarget(ctx, opts)
   local modname = opts.name
   if not modname then
      ef("LuaModuleTarget: missing name")
   end
   local m_src = ctx:Target {
      dirname = ctx.srcdir,
      basename = sf("%s.lua", modname)
   }
   if not fs.exists(m_src.path) then
      die("missing source file: %s", m_src.basename)
   end
   return ctx:Target {
      dirname = ctx.objdir,
      basename = sf("%s.lo", modname),
      depends = m_src,
      build = function(self)
         ctx:compile_lua {
            src = m_src,
            dst = self,
            name = ctx:mangle(modname)
         }
      end
   }
end

function BuildContext.CModuleTarget(ctx, opts)
   local modname = opts.name
   if not modname then
      ef("CModuleTarget: missing name")
   end
   local c_src = ctx:Target {
      dirname = ctx.srcdir,
      basename = sf("%s.c", modname)
   }
   if not fs.exists(c_src.path) then
      -- it's a pure Lua module
      return nil
   end
   local c_h = ctx:Target {
      dirname = ctx.srcdir,
      basename = sf("%s.h", modname)
   }
   return ctx:Target {
      dirname = ctx.objdir,
      basename = sf("%s.o", modname),
      depends = { c_src, c_h },
      build = function(self)
         local cflags = { "-iquote", ctx.srcdir }
         cflags = util.extend(cflags, ctx:collect("cflags", modname))
         ctx:compile_c {
            src = c_src,
            dst = self,
            cflags = cflags
         }
      end
   }
end

function BuildContext:native_targets()
   local targets = {}
   for libname, target_factory in pairs(self.pd.native) do
      local basename = sf("lib%s.a", libname)
      local libtargets = self:get(basename)
      if not libtargets then
         if type(target_factory) ~= "function" then
            ef("invalid target factory for native library %s: %s", libname, target_factory)
         end
         local target_opts = {
            name = libname
         }
         libtargets = flatten(target_factory(self, target_opts))
         self:set(basename, libtargets)
      end
      util.extend(targets, libtargets)
   end
   return targets
end

function BuildContext:module_targets(modname)
   local targets = self:get(modname)
   if not targets then
      targets = {}
      local opts = { name = modname }
      local lua_target = self:LuaModuleTarget(opts)
      table.insert(targets, lua_target)
      local c_target = self:CModuleTarget(opts)
      if c_target then
         table.insert(targets, c_target)
      end
      self:set(modname, targets)
   end
   return targets
end

function BuildContext:exported_targets()
   local targets = {}
   for _,modname in ipairs(self.pd.exports) do
      util.extend(targets, self:module_targets(modname))
   end
   util.extend(targets, self:module_targets("package"))
   return targets
end

function BuildContext:library_target()
   local ctx = self
   local basename = sf("lib%s.a", self.pd.libname)
   local libtarget = self:get(basename)
   if not libtarget then
      libtarget = ctx:Target {
         dirname = self.libdir,
         basename = basename,
         depends = self:exported_targets(),
         build = function(self, changed)
            ctx:ar {
               dst = self,
               src = changed
            }
         end
      }
      ctx:set(basename, libtarget)
   end
   return libtarget
end

function BuildContext:link_targets()
   local targets = { self:library_target() }
   util.extend(targets, self:native_targets())
   for _,pkg in ipairs(self.pd.imports) do
      util.extend(targets, get_build_context(pkg):link_targets())
   end
   return targets
end

function BuildContext:ldflags()
   local ldflags = {}
   util.extend(ldflags, self.pd.ldflags)
   for _,pkg in ipairs(self.pd.imports) do
      util.extend(ldflags, get_build_context(pkg):ldflags())
   end
   return ldflags
end

function BuildContext:build_main(appname)
   local main_tpl_c = self:Target {
      dirname = self.srcdir,
      basename = "_main.tpl.c"
   }
   local main_c = self:Target {
      dirname = self.tmpdir,
      basename = "_main.c"
   }
   self:cp {
      src = main_tpl_c,
      dst = main_c
   }
   local main_o = self:Target {
      dirname = self.objdir,
      basename = "_main.o"
   }
   self:compile_c {
      src = main_c,
      dst = main_o,
      cflags = self:collect("cflags", "libluajit.a")
   }
   local main_tpl_lua = self:Target {
      dirname = self.srcdir,
      basename = "_main.tpl.lua"
   }
   local main_lua = self:Target {
      dirname = self.tmpdir,
      basename = "_main.lua"
   }
   local f = fs.open(main_lua.path, bit.bor(ffi.C.O_WRONLY))
   f:write(sf("local PACKAGE = '%s'\n", self.pd.package))
   f:write(fs.readfile(main_tpl_lua.path))
   f:write([[
local app_module = require(']]..appname..[[')
if type(app_module)=='table' and app_module.main then
  app_module.main()
end
]])
   f:close()
   local main_lo = self:Target {
      dirname = self.objdir,
      basename = "_main.lo"
   }
   self:compile_lua {
      src = main_lua,
      dst = main_lo,
      name = '_main'
   }
   return { main_o, main_lo }
end

function BuildContext:is_exported_module(name)
   for _,modname in ipairs(self.pd.exports) do
      if modname == name then
         return true
      end
   end
   return false
end

function BuildContext:app_targets()
   local ctx = self
   local targets = {}
   for _,appname in ipairs(self.pd.apps) do
      local app_module_targets = {}
      if not self:is_exported_module(appname) then
         -- it's not included in the library
         -- so we shall build it separately
         app_module_targets = self:module_targets(appname)
      end
      local apptarget = self:Target {
         name = appname,
         dirname = self.bindir,
         basename = appname,
         depends = {
            self:library_target(),
            app_module_targets
         },
         build = function(self)
            local main_targets = ctx:build_main(appname)
            ctx:link {
               dst = self,
               src = {
                  ctx:link_targets(),
                  app_module_targets,
                  main_targets
               },
               ldflags = ctx:ldflags()
            }
         end
      }
      table.insert(targets, apptarget)
   end
   return targets
end

function BuildContext:build()
   for _,pkg in ipairs(self.pd.imports) do
      get_build_context(pkg):build()
   end
   process.chdir(self.srcdir)
   for _,native_target in ipairs(self:native_targets()) do
      native_target:make()
   end
   local library_target = self:library_target()
   library_target:make()
   for _,app_target in ipairs(self:app_targets()) do
      app_target:make()
   end
end

function BuildContext:install()
   self:build()
   for _,app_target in ipairs(self:app_targets()) do
      self:symlink {
         src = app_target,
         dst = fs.join(self.gbindir, app_target.name)
      }
   end
end

function BuildContext:clean()
   --system { "rm", "-rf", self.bindir }
   system { "rm", "-rf", self.objdir }
   system { "rm", "-rf", self.libdir }
end

local function parse_package_name(name)
   if not name or name == '.' then
      local pd_path = find_package_descriptor()
      if pd_path then
         local pd = loadfile(pd_path)()
         name = pd.package
      else
         die("no package")
      end
   end
   local pkgname, pkgurl
   -- user@host:path
   local m = re.match("^(.+)@(.+):(.+?)(\\.git)?$", name)
   if m then
      pkgname = sf("%s/%s", m[2], m[3])
      pkgurl = m[0]
   end
   -- https://host/path
   local m = re.match("^https?://(.+?)/(.+?)(\\.git)?$", name)
   if m then
      pkgname = sf("%s/%s", m[1], m[2])
      pkgurl = m[0]
   end
   -- host/path
   local m = re.match("^(.+?)/(.+)$", name)
   if m then
      pkgname = m[0]
      pkgurl = sf("https://%s", pkgname)
   end
   if pkgname and pkgurl then
      return pkgname, pkgurl
   else
      die("cannot parse package name: %s", name)
   end
end

local function checkout(package_name, git_ref, update)
   local pkgname, pkgurl = parse_package_name(package_name)
   local srcdir = sf("%s/src/%s", ZZPATH, pkgname)
   if not fs.exists(srcdir) then
      fs.mkpath(srcdir)
      process.chdir(srcdir)
      local status = system { "git", "clone", pkgurl, "." }
      if status ~= 0 then
         die("git clone failed")
      end
   else
      process.chdir(srcdir)
      local status = system { "git", "fetch" }
      if status ~= 0 then
         die("git fetch failed")
      end
   end
   local status = process.system { "git", "checkout", git_ref or "master" }
   if status ~= 0 then
      die("git checkout failed")
   end
   if update then
      local status = system { "git", "pull" }
      if status ~= 0 then
         die("git pull failed")
      end
   end
   -- checkout dependencies
   local pd = PackageDescriptor(pkgname)
   for _,package_name in ipairs(pd.imports) do
      checkout(package_name)
   end
end

local handlers = {}

function handlers.checkout(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   ap:add { name = "ref", type = "string" }
   ap:add { name = "update", option = "-u|--update" }
   local args = ap:parse(args)
   if args.pkg then
      checkout(args.pkg, args.ref, args.update)
   else
      die("Missing argument: pkg")
   end
end

function handlers.build(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   get_build_context(args.pkg):build()
end

function handlers.install(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   get_build_context(args.pkg):install()
end

function handlers.clean(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   get_build_context(args.pkg):clean()
end

function M.main()
   local ap = argparser("zz", "zz build tool")
   ap:add { name = "command", type = "string" }
   ap:add { name = "verbose", option = "-v|--verbose" }
   local args, rest_args = ap:parse()
   if not args.command then
      usage()
   end
   quiet = args.quiet
   local handler = handlers[args.command]
   if not handler then
      die("Invalid command: %s", args.command)
   else
      handler(rest_args)
   end
end

return M
