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

local reduce = util.reduce
local extend = util.extend

local ZZ_CORE_PACKAGE = "github.com/cellux/zz"

local quiet = false

local function log(msg, ...)
   if not quiet then
      pf(msg, ...)
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

zz checkout [-u] <package>

  1. If $ZZPATH/src/<package> does not exist yet:

     git clone <package> into $ZZPATH/src/<package>

     Otherwise run `git fetch' under $ZZPATH/src/<package>

  2. Run `git checkout master' under $ZZPATH/src/<package>

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

local function find_package_descriptor(dir)
   dir = dir or process.getcwd()
   local pd_path
   local found = false
   while not found do
      pd_path = fs.join(dir, 'package.lua')
      if fs.exists(pd_path) then
         found = true
      elseif dir == '/' then
         break
      else
         dir = fs.dirname(dir)
      end
   end
   return found and pd_path or nil
end

local function PackageDescriptor(package_name)
   local pd_path, pd
   if not package_name or package_name == '.' then
      pd_path = find_package_descriptor()
   elseif type(package_name) == "string" then
      pd_path = fs.join(ZZPATH, 'src', package_name, 'package.lua')
   else
      ef("invalid package name: %s", package_name)
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
      die("invalid package descriptor (no package field): %s", pd_path)
   end
   -- name of the static module library generated by this package
   pd.libname = pd.libname or fs.basename(pd.package)
   -- external packages used by this package
   pd.imports = pd.imports or {}
   -- ZZ_CORE_PACKAGE is imported by default into everything (except core)
   if pd.package ~= ZZ_CORE_PACKAGE and not util.contains(ZZ_CORE_PACKAGE, pd.imports) then
      table.insert(pd.imports, ZZ_CORE_PACKAGE)
   end
   -- native C libraries built by this package
   pd.native = pd.native or {}
   -- Lua/C modules exported by this package
   pd.exports = pd.exports or {}
   -- the package descriptor shall always be exported
   if not util.contains("package", pd.exports) then
      table.insert(pd.exports, "package")
   end
   -- compile-time module dependencies
   pd.depends = pd.depends or {}
   -- mounts
   pd.mounts = pd.mounts or {}
   -- apps (executables) generated by this package
   pd.apps = pd.apps or {}
   -- apps which shall be symlinked into $ZZPATH/bin
   pd.install = pd.install or {}
   return pd
end

-- generic build target abstraction

local Target = util.Class()

local function is_target(x)
   return type(x) == "table" and x.is_target
end

local function is_target_ref(x)
   return type(x) == "string"
end

local function flatmap(transform, targets)
   local rv = {}
   local function add(x)
      if is_target(x) or is_target_ref(x) then
         table.insert(rv, transform(x))
      elseif type(x) == "table" then
         for _,t in ipairs(x) do
            add(t)
         end
      end
   end
   add(targets)
   return rv
end

local function identity(x)
   return x
end

local function flatten(targets)
   return flatmap(identity, targets)
end

local function walk(root, process, get_children, transform_child)
   transform_child = transform_child or identity
   if type(get_children) == "string" then
      local key = get_children
      get_children = function(t) return t[key] end
   end
   local seen = {}
   local function walk(item)
      if not seen[item] then
         process(item)
         seen[item] = true
         for _,child in ipairs(get_children(item)) do
            walk(transform_child(child))
         end
      end
   end
   walk(root)
end

function Target:create(opts)
   assert(type(opts)=="table")
   assert(opts.ctx)
   opts.depends = flatten(opts.depends)
   if opts.dirname or opts.basename then
      if not opts.dirname then
         ef("Target:create(): no dirname (only basename)")
      end
      if not opts.basename then
         ef("Target:create(): no basename (only dirname)")
      end
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

function Target:collect(key)
   local rv = {}
   local function collect(t)
      if t[key] then
         table.insert(rv, t[key])
      end
   end
   walk(self, collect, "depends")
   return rv
end

function Target:make(force)
   local my_mtime = self:mtime()
   local changed = {} -- list of updated dependencies
   local max_mtime = 0
   self.depends = flatten(self.ctx:resolve_targets(self.depends))
   for _,t in ipairs(self.depends) do
      assert(is_target(t))
      t:make(force)
      local mtime = t:mtime()
      if mtime > my_mtime then
         table.insert(changed, t)
      end
      if mtime > max_mtime then
         max_mtime = mtime
      end
   end
   if (my_mtime < max_mtime or force) and self.build then
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

function Target:force_make()
   self:make(true)
end

local function maybe_a_file_path(x)
   return type(x) == "string"
end

local function target_path(x)
   if is_target(x) and x.path then
      return x.path
   elseif maybe_a_file_path(x) then
      return x
   else
      ef("target_path() not applicable for %s", inspect(x))
   end
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
      local pd_chunk, err = loadfile(pd_path)
      if type(pd_chunk) ~= "function" then
         die(err)
      end
      local pd = pd_chunk()
      if not pd then
         die("invalid package descriptor: %s (maybe does not return the package table?)", pd_path)
      end
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

function BuildContext:resolve_target_ref(name)
   local t = self:get(name)
   if not t then
      -- lookup in imported packages
      for _,pkgname in ipairs(self.pd.imports) do
         local ctx = get_build_context(pkgname)
         t = ctx:get(name)
         if t then break end
      end
   end
   if not t then
      ef("cannot resolve target ref: %s", name)
   end
   return t
end

function BuildContext:resolve_targets(targets)
   local function resolve(t)
      if is_target(t) then
         return t
      elseif is_target_ref(t) then
         return self:resolve_target_ref(t)
      else
         ef("cannot resolve target: %s", t)
      end
   end
   return util.map(resolve, targets)
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
                "-n", opts.sym,
                "-g",
                target_path(opts.src),
                target_path(opts.dst))
end

function BuildContext:ar(opts)
   with_cwd(opts.cwd, function()
      local status = system {
         "ar", "rsc",
         target_path(opts.dst),
         unpack(flatmap(target_path, opts.src))
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
      log("symlink: %s -> %s", src, dst)
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
   util.extend(args, flatmap(target_path, opts.src))
   table.insert(args, "-Wl,--no-whole-archive")
   util.extend(args, opts.ldflags)
   local status = system(args)
   if status ~= 0 then
      die("link failed")
   end
end

function BuildContext.Target(ctx, opts)
   assert(type(opts)=="table")
   opts.ctx = ctx
   return Target(opts)
end

function BuildContext.LuaModuleTarget(ctx, opts)
   local modname = opts.name
   if not modname then
      ef("LuaModuleTarget: missing name")
   end
   local m_dirname = fs.dirname(modname)
   local m_basename = fs.basename(modname)
   local m_srcdir, m_objdir
   if m_dirname == '.' then
      m_srcdir = ctx.srcdir
      m_objdir = ctx.objdir
   else
      m_srcdir = fs.join(ctx.srcdir, m_dirname)
      m_objdir = fs.join(ctx.objdir, m_dirname)
   end
   local m_src = ctx:Target {
      dirname = m_srcdir,
      basename = sf("%s.lua", m_basename)
   }
   if not fs.exists(m_src.path) then
      ef("missing source file: %s", m_src.path)
   end
   return ctx:Target {
      dirname = m_objdir,
      basename = sf("%s.lo", m_basename),
      depends = m_src,
      build = function(self)
         ctx:compile_lua {
            src = m_src,
            dst = self,
            sym = ctx:mangle(modname)
         }
      end
   }
end

function BuildContext.CModuleTarget(ctx, opts)
   local modname = opts.name
   if not modname then
      ef("CModuleTarget: missing name")
   end
   local m_dirname = fs.dirname(modname)
   local m_basename = fs.basename(modname)
   local m_srcdir, m_objdir
   if m_dirname == '.' then
      m_srcdir = ctx.srcdir
      m_objdir = ctx.objdir
   else
      m_srcdir = fs.join(ctx.srcdir, m_dirname)
      m_objdir = fs.join(ctx.objdir, m_dirname)
   end
   local c_src = ctx:Target {
      dirname = m_srcdir,
      basename = sf("%s.c", m_basename)
   }
   if not fs.exists(c_src.path) then
      -- it's a pure Lua module
      return nil
   end
   local c_h = ctx:Target {
      dirname = m_srcdir,
      basename = sf("%s.h", m_basename)
   }
   return ctx:Target {
      dirname = m_objdir,
      basename = sf("%s.o", m_basename),
      depends = util.extend({ c_src, c_h }, ctx.pd.depends[modname]),
      build = function(self)
         local cflags = {}
         local seen = {}
         local function collect(t)
            if not seen[t.ctx] then
               util.extend(cflags, { "-iquote", t.ctx.srcdir })
               seen[t.ctx] = true
            end
            util.extend(cflags, t.cflags)
         end
         walk(self, collect, "depends")
         ctx:compile_c {
            src = c_src,
            dst = self,
            cflags = cflags
         }
      end
   }
end

function BuildContext:prep_native_targets()
   if not self.native_targets then
      local targets = {}
      for libname, target_factory in pairs(self.pd.native) do
         local basename = sf("lib%s.a", libname)
         if type(target_factory) ~= "function" then
            ef("invalid target factory for native library %s: %s", libname, target_factory)
         end
         local target_opts = {
            name = libname
         }
         local t = target_factory(self, target_opts)
         self:set(basename, t)
         table.insert(targets, t)
      end
      self.native_targets = targets
   end
end

function BuildContext:module_targets(modname)
   local targets = {}
   local opts = { name = modname }
   local lua_target = self:LuaModuleTarget(opts)
   table.insert(targets, lua_target)
   local c_target = self:CModuleTarget(opts)
   if c_target then
      table.insert(targets, c_target)
   end
   return targets
end

function BuildContext:prep_exported_targets()
   if not self.exported_targets then
      local targets = {}
      for _,modname in ipairs(self.pd.exports) do
         local module_targets = self:module_targets(modname)
         self:set(modname, module_targets)
         util.extend(targets, module_targets)
      end
      self.exported_targets = targets
   end
end

function BuildContext:prep_library_target()
   if not self.library_target then
      self:prep_exported_targets()
      local basename = sf("lib%s.a", self.pd.libname)
      local ctx = self
      local t = ctx:Target {
         dirname = ctx.libdir,
         basename = basename,
         depends = ctx.exported_targets,
         build = function(self, changed)
            ctx:ar {
               dst = self,
               src = changed
            }
         end
      }
      ctx:set(basename, t)
      self.library_target = t
   end
end

function BuildContext:walk_imports(process)
   local function get_children(ctx)
      return ctx.pd.imports
   end
   local function transform_child(pkg)
      return get_build_context(pkg)
   end
   walk(self, process, get_children, transform_child)
end

function BuildContext:prep_link_targets()
   if not self.link_targets then
      local targets = {}
      self:walk_imports(function(ctx)
         ctx:prep_library_target()
         table.insert(targets, ctx.library_target)
         ctx:prep_native_targets()
         util.extend(targets, ctx.native_targets)
      end)
      self.link_targets = targets
   end
end

function BuildContext:ldflags()
   local ldflags = {}
   self:walk_imports(function(ctx)
      util.extend(ldflags, ctx.pd.ldflags)
   end)
   return ldflags
end

function BuildContext:main_targets(name, bootstrap_code)
   local ctx = self
   local zzctx = get_build_context(ZZ_CORE_PACKAGE)
   zzctx:prep_native_targets() -- for libluajit.a cflags
   local main_tpl_c = ctx:Target {
      dirname = zzctx.srcdir,
      basename = "_main.tpl.c"
   }
   local main_c = ctx:Target {
      dirname = ctx.tmpdir,
      basename = sf("%s.c", name),
      depends = main_tpl_c,
      build = function(self)
         ctx:cp {
            src = main_tpl_c,
            dst = self
         }
      end
   }
   local main_o = ctx:Target {
      dirname = ctx.objdir,
      basename = sf("%s.o", name),
      depends = main_c,
      build = function(self)
         ctx:compile_c {
            src = main_c,
            dst = self,
            cflags = zzctx:get("libluajit.a").cflags
         }
      end
   }
   local main_tpl_lua = ctx:Target {
      dirname = zzctx.srcdir,
      basename = "_main.tpl.lua"
   }
   local main_lua = ctx:Target {
      dirname = ctx.tmpdir,
      basename = sf("%s.lua", name),
      depends = main_tpl_lua,
      build = function(self)
         local f = fs.open(self.path, bit.bor(ffi.C.O_CREAT,
                                              ffi.C.O_WRONLY,
                                              ffi.C.O_TRUNC))
         f:write(sf("local ZZ_PACKAGE = '%s'\n", ctx.pd.package))
         f:write(sf("local ZZ_CORE_PACKAGE = '%s'\n", ZZ_CORE_PACKAGE))
         f:write(fs.readfile(main_tpl_lua.path))
         f:write(bootstrap_code)
         f:close()
      end
   }
   local main_lo = ctx:Target {
      dirname = ctx.objdir,
      basename = sf("%s.lo", name),
      depends = main_lua,
      build = function(self)
         ctx:compile_lua {
            src = main_lua,
            dst = self,
            sym = '_main'
         }
      end
   }
   return { main_o, main_lo }
end

function BuildContext:build_main(bootstrap_code)
   local main_targets = self:main_targets('_main', bootstrap_code)
   for _,t in ipairs(main_targets) do
      t:force_make()
   end
   return main_targets
end

function BuildContext:gen_vfs_mount()
   local code = ''
   if next(self.pd.mounts) then
      code = [[
         do
            local vfs = require('vfs')
            local pd = require('package')
            vfs.mount_all(pd.mounts, ']]..self.srcdir..[[')
         end
]]
   end
   return code
end

function BuildContext:gen_app_bootstrap(appname)
   return self:gen_vfs_mount()..sf("run_module('%s')\n", self:mangle(appname))
end

function BuildContext:gen_run_bootstrap()
   return self:gen_vfs_mount()..sf("run_script(table.remove(_G.arg,1))\n")
end

function BuildContext:gen_test_bootstrap()
   return self:gen_vfs_mount().."run_tests(_G.arg)\n"
end

function BuildContext:prep_app_targets()
   if not self.app_targets then
      self:prep_link_targets()
      local targets = {}
      for _,appname in ipairs(self.pd.apps) do
         local app_module_targets = {}
         if not util.contains(appname, self.pd.exports) then
            -- it's not included in the library as a module
            -- we shall build it separately
            app_module_targets = self:module_targets(appname)
         end
         local bootstrap = self:gen_app_bootstrap(appname)
         local main_targets = self:main_targets('_main', bootstrap)
         local ctx = self
         local app = self:Target {
            dirname = self.bindir,
            basename = appname,
            depends = {
               self.link_targets,
               app_module_targets,
               main_targets
            },
            build = function(self)
               ctx:link {
                  dst = self,
                  src = {
                     ctx.link_targets,
                     app_module_targets,
                     main_targets
                  },
                  ldflags = ctx:ldflags()
               }
            end
         }
         table.insert(targets, app)
      end
      self.app_targets = targets
   end
end

function BuildContext:build(opts)
   opts = opts or {}
   if opts.recursive then
      for _,pkg in ipairs(self.pd.imports) do
         get_build_context(pkg):build(opts)
      end
   end
   with_cwd(self.srcdir, function()
      self:prep_native_targets()
      for _,native_target in ipairs(self.native_targets) do
         native_target:make()
      end
      self:prep_library_target()
      self.library_target:make()
      if opts.apps then
         self:prep_app_targets()
         for _,app_target in ipairs(self.app_targets) do
            app_target:make()
         end
      end
   end)
end

function BuildContext:install()
   self:build {
      recursive = true,
      apps = true
   }
   self:prep_app_targets()
   for _,app_target in ipairs(self.app_targets) do
      self:symlink {
         src = app_target,
         dst = fs.join(self.gbindir, app_target.basename)
      }
   end
end

function BuildContext:run(path)
   if not fs.exists(path) then
      die("script not found: %s", path)
   end
   path = fs.realpath(path)
   if path:sub(1,#self.srcdir) ~= self.srcdir then
      die("this app belongs to another package: %s", path)
   end
   local bootstrap = self:gen_run_bootstrap(path)
   local main_targets = self:main_targets('_run', bootstrap)
   self:prep_link_targets()
   local ctx = self
   local runner = ctx:Target {
      dirname = ctx.tmpdir,
      basename = '_run',
      depends = { ctx.link_targets, main_targets },
      build = function(self)
         ctx:link {
            dst = self,
            src = { ctx.link_targets, main_targets },
            ldflags = ctx:ldflags()
         }
      end
   }
   runner:make()
   process.system { runner.path, unpack(_G.arg, 2) }
end

function BuildContext:find_tests()
   return fs.glob(fs.join(self.srcdir, "*_test.lua"))
end

function BuildContext:test(test_names)
   self:build {
      recursive = true,
      apps = false
   }
   local test_paths
   if not test_names or #test_names == 0 then
      test_paths = self:find_tests()
   else
      local function resolve(test_name)
         local test_path
         if test_name:sub(-4) == ".lua" then
            test_path = test_name
         else
            if test_name:sub(-5) ~= "_test" then
               test_name = test_name.."_test"
            end
            test_path = sf("%s/%s.lua", self.srcdir, test_name)
         end
         if not fs.exists(test_path) then
            die("cannot find test: %s", test_path)
         end
         return fs.realpath(test_path)
      end
      test_paths = util.map(resolve, test_names)
   end
   local bootstrap = self:gen_test_bootstrap()
   local main_targets = self:main_targets('_test', bootstrap)
   self:prep_link_targets()
   local ctx = self
   local testrunner = ctx:Target {
      dirname = ctx.tmpdir,
      basename = '_test',
      depends = { ctx.link_targets, main_targets },
      build = function(self)
         ctx:link {
            dst = self,
            src = { ctx.link_targets, main_targets },
            ldflags = ctx:ldflags()
         }
      end
   }
   testrunner:make()
   process.system { testrunner.path, unpack(test_paths) }
end

local function rmpath(path)
   log("rmpath: %s", path)
   fs.rmpath(path)
end

function BuildContext:clean()
   rmpath(self.objdir)
   rmpath(self.libdir)
   rmpath(self.tmpdir)
end

function BuildContext:distclean()
   self:clean()
   local installed_apps = util.filter(fs.is_lnk, fs.glob(fs.join(self.gbindir,"*")))
   for _,app in ipairs(installed_apps) do
      if fs.dirname(fs.realpath(app)) == self.bindir then
         log("unlink: %s", app)
         fs.unlink(app)
      end
   end
   rmpath(self.bindir)
   rmpath(self.nativedir)
end

local function parse_package_name(package_name)
   if not package_name or package_name == '.' then
      local pd_path = find_package_descriptor()
      if pd_path then
         local pd = loadfile(pd_path)()
         package_name = pd.package
      else
         die("no package")
      end
   end
   local pkgname, pkgurl
   local m = re.Matcher(package_name)
   if m:match("^(.+?)@(.+?):(.+?)(\\.git)?$") then
      -- user@host:path
      pkgname = sf("%s/%s", m[2], m[3])
      pkgurl = m[0]
   elseif m:match("^https?://(.+?)/(.+?)(\\.git)?$") then
      -- https://host/path
      pkgname = sf("%s/%s", m[1], m[2])
      pkgurl = m[0]
   elseif m:match("^(.+?)/(.+)$") then
      -- host/path
      pkgname = m[0]
      pkgurl = sf("https://%s", pkgname)
   end
   if pkgname and pkgurl then
      return pkgname, pkgurl
   else
      die("cannot parse package name: %s", package_name)
   end
end

local function init(package_name)
   local pkgname, pkgurl = parse_package_name(package_name)
   local srcdir = sf("%s/src/%s", ZZPATH, pkgname)
   if not fs.exists(srcdir) then
      log("mkpath: %s", srcdir)
      fs.mkpath(srcdir)
   end
   local pd_path = fs.join(srcdir, "package.lua")
   if not fs.exists(pd_path) then
      log("writing %s", pd_path)
      fs.writefile(pd_path, [[
local P = {}

P.package = "]]..pkgname..[["

-- external packages used by this package
P.imports = {}

-- native C libraries built by this package
P.native = {}

-- Lua/C modules exported by this package
P.exports = {}

-- compile-time module dependencies
P.depends = {}

-- mounts
P.mounts = {}

-- apps (executables) generated by this package
P.apps = {}

-- apps which shall be symlinked into $ZZPATH/bin
P.install = {}

return P
]])
      log("package successfully initialized at %s", srcdir)
   else
      log("%s already exists", pd_path)
   end
end

local function checkout(package_name, opts)
   opts = opts or {}
   local pkgname, pkgurl = parse_package_name(package_name)
   local srcdir = sf("%s/src/%s", ZZPATH, pkgname)
   if not fs.exists(srcdir) then
      log("mkpath: %s", srcdir)
      fs.mkpath(srcdir)
      with_cwd(srcdir, function()
         local status = system { "git", "clone", pkgurl, "." }
         if status ~= 0 then
            die("git clone failed")
         end
      end)
   else
      with_cwd(srcdir, function()
         local status = system { "git", "fetch" }
         if status ~= 0 then
            die("git fetch failed")
         end
      end)
   end
   with_cwd(srcdir, function()
      local status = process.system { "git", "checkout", "master" }
      if status ~= 0 then
         die("git checkout failed")
      end
      if opts.update then
         local status = system { "git", "pull" }
         if status ~= 0 then
            die("git pull failed")
         end
      end
   end)
   if opts.recursive then
      -- checkout dependencies
      local pd = PackageDescriptor(pkgname)
      for _,package_name in ipairs(pd.imports) do
         checkout(package_name, {
            update = false,
            recursive = true
         })
      end
   end
end

local handlers = {}

function handlers.init(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   if args.pkg then
      init(args.pkg)
   else
      die("Missing argument: pkg")
   end
end

function handlers.checkout(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   ap:add { name = "update", option = "-u|--update" }
   ap:add { name = "recursive", option = "-r|--recursive" }
   local args = ap:parse(args)
   if args.pkg then
      checkout(args.pkg, {
         update = args.update,
         recursive = args.recursive
      })
   else
      die("Missing argument: pkg")
   end
end

function handlers.build(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   ap:add { name = "recursive", option = "-r|--recursive" }
   local args = ap:parse(args)
   get_build_context(args.pkg):build {
      recursive = args.recursive,
      apps = true
   }
end

function handlers.install(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   get_build_context(args.pkg):install()
end

function handlers.get(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   ap:add { name = "update", option = "-u|--update" }
   local args = ap:parse(args)
   if args.pkg then
      checkout(args.pkg, {
         update = args.update,
         recursive = true
      })
      get_build_context(args.pkg):install()
   else
      die("Missing argument: pkg")
   end
end

function handlers.run(args)
   local ap = argparser()
   ap:add { name = "script_path", type = "string" }
   local args = ap:parse(args)
   if not args.script_path then
      die("missing argument: script path")
   end
   get_build_context():run(args.script_path)
end

function handlers.test(args)
   local ap = argparser()
   local args, test_names = ap:parse(args)
   get_build_context():test(test_names)
end

function handlers.clean(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   get_build_context(args.pkg):clean()
end

function handlers.distclean(args)
   local ap = argparser()
   ap:add { name = "pkg", type = "string" }
   local args = ap:parse(args)
   get_build_context(args.pkg):distclean()
end

function M.main()
   local ap = argparser("zz", "zz build system")
   ap:add { name = "command", type = "string" }
   ap:add { name = "quiet", option = "-q|--quiet" }
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
