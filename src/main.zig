//! eb-local: install and build software on top of EESSI into a directory you
//! own. Configuration is layered TOML (see config.zig); secrets come from the
//! environment, owner-only files or nimvault (see secrets.zig).
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const cli = common.cli;
pub const toml = @import("toml.zig");
pub const config = @import("config.zig");
pub const secrets = @import("secrets.zig");
pub const storage = @import("storage.zig");
const Allocator = std.mem.Allocator;

const tool = "eb-local";
pub const version = "2.0.0";

const usage_text =
    \\eb-local: install and build software on top of EESSI 2026.06, into a
    \\directory you own. The 2026 replacement for eblocalinstall.
    \\
    \\  eb-local <easyconfig> [eb options]   build and install with EasyBuild
    \\  eb-local env                         lines that make your installed modules visible
    \\  eb-local dev [MODULE...]             the same, plus MODULEs and a build environment,
    \\                                       so gcc, make, cmake and meson just work
    \\  eb-local clean [--logs-older-than DAYS] [--sources] [--workspaces] [--dry-run] [--delete]
    \\                                       remove what eb-local left behind
    \\  eb-local config [--check]            the settings in force and where each came from;
    \\                                       --check also reads every secret (values not shown)
    \\  eb-local profiles                    the profiles the configuration defines
    \\  eb-local help | --version
    \\
    \\Every command takes --profile NAME, --project DIR (a shared project directory
    \\instead of $HOME/.local/eessi) and --config FILE. Use env and dev with eval:
    \\
    \\  eval "$(eb-local env)"
    \\  eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
    \\
    \\Configuration: the site file (/etc/eb-local/config.toml, or config.toml or
    \\eb-local.conf beside this program), then ~/.config/eb-local/config.toml,
    \\then EB_LOCAL_* variables, then options. Builds use the allocation's own
    \\node-local mount; a successful build removes its workspace. Secrets reach
    \\eb's environment only, and logs written during a build are cleaned of them.
    \\
;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn oom() noreturn {
    die("out of memory", .{});
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    cli.out(fmt ++ "\n", args);
}

const Ctx = struct {
    a: Allocator,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    cwd: []const u8,
};

// ---- shell output ---------------------------------------------------------

/// A word the shell reads back as exactly `s`: as it is when it holds only
/// safe characters, single-quoted otherwise.
fn shellQuote(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var safe = s.len > 0;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_./:@%+,=-", ch) != null)) {
            safe = false;
            break;
        }
    }
    if (safe) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.items;
}

fn q(a: Allocator, s: []const u8) []const u8 {
    return shellQuote(a, s) catch oom();
}

fn str(a: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, f, args) catch oom();
}

const install_vars = [_][]const u8{
    "EESSI_CVMFS_INSTALL",               "EESSI_SITE_INSTALL",            "EESSI_USER_INSTALL",
    "EESSI_PROJECT_INSTALL",             "EESSI_SITE_SOFTWARE_PREFIX",    "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
    "EESSI_ACCELERATOR_TARGET_OVERRIDE", "EESSI_OVERRIDE_GPU_CHECK",      "EASYBUILD_INSTALLPATH",
    "EASYBUILD_INSTALLPATH_SOFTWARE",    "EASYBUILD_INSTALLPATH_MODULES", "EASYBUILD_PREFIX",
};

const Place = struct {
    prefix: []const u8,
    project: bool,
};

fn environmentLines(c: Ctx, s: config.Settings, p: Place) []const u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    add(a, &out, str(a, "module unload {s} >/dev/null 2>&1 || true\n", .{q(a, s.extend_module.value)}));
    add(a, &out,
        \\unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL
        \\unset EESSI_SITE_SOFTWARE_PREFIX
        \\unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK
        \\unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX
        \\
    );
    add(a, &out, str(a, "export {s}={s}\n", .{ if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", q(a, p.prefix) }));
    // EESSI-extend refuses an install directory that does not exist, and
    // Lmod then undoes the whole load; before the first install there are
    // no modules of yours to show, so the stack is loaded alone.
    const exists_dir = if (fsx.statAt(fsx.cwd, p.prefix, true)) |st| st.isDir() else |_| false;
    if (exists_dir) {
        add(a, &out, str(a, "module load {s} {s}\n", .{ q(a, s.stack_module.value), q(a, s.extend_module.value) }));
    } else {
        add(a, &out, str(a, "module load {s}\n", .{q(a, s.stack_module.value)}));
    }
    return out.items;
}

fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn isTerminal(fd: sys.fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) == .SUCCESS;
}

fn evalHint(words: []const u8) void {
    if (isTerminal(1)) {
        warn("these lines change nothing until the shell runs them:", .{});
        cli.err("  eval \"$(eb-local {s})\"\n", .{words});
    }
}

// ---- configuration files --------------------------------------------------

fn selfExe(buf: *[sys.path_max]u8) ?[]const u8 {
    const n = linux.readlinkat(linux.AT.FDCWD, "/proc/self/exe", buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0 or n >= buf.len) return null;
    return buf[0..n];
}

fn selfDir(a: Allocator) []const u8 {
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse return "/";
    return a.dupe(u8, std.fs.path.dirname(exe) orelse "/") catch oom();
}

fn selfOwner() linux.uid_t {
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse return 0;
    const st = fsx.statAt(fsx.cwd, exe, true) catch return 0;
    return st.uid;
}

const Trust = enum { site, user };

/// Read a configuration file that may steer builds: a regular file, not a
/// symbolic link, not writable by group or others, owned by root, this
/// program's owner or the caller (a site file) or by the caller (a user
/// file). A file that fails is an error, never skipped.
fn readTrusted(c: Ctx, path: []const u8, kind: Trust) []const u8 {
    const lst = fsx.statAt(fsx.cwd, path, false) catch |e| die("cannot open {s} ({s})", .{ path, @errorName(e) });
    if (lst.isLink()) die("{s} is a symbolic link; a configuration file must be a regular file", .{path});
    const opened = fsx.openRegular(fsx.cwd, path, false) catch |e| die("cannot open {s} ({s})", .{ path, @errorName(e) });
    defer sys.close(opened.fd);
    const st = opened.stat;
    if (st.mode & 0o022 != 0) die("{s} is writable by group or others and is not used; chmod go-w it", .{path});
    const uid = linux.getuid();
    const ok = switch (kind) {
        .site => st.uid == 0 or st.uid == selfOwner() or st.uid == uid,
        .user => st.uid == uid,
    };
    if (!ok) die("{s} is owned by uid {d} and is not used", .{ path, st.uid });
    return fsx.readAll(c.a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ path, @errorName(e) });
}

fn exists(path: []const u8) bool {
    _ = fsx.statAt(fsx.cwd, path, false) catch return false;
    return true;
}

fn sourceFrom(c: Ctx, path: []const u8, kind: Trust) config.Source {
    const raw = readTrusted(c, path, kind);
    const layer: config.Layer = if (kind == .site) .site else .user;
    if (std.mem.endsWith(u8, path, ".toml")) return .{ .path = path, .text = raw, .layer = layer };
    var d: config.Diagnostic = .{};
    const text = config.legacyToToml(c.a, raw, &d) catch |e| switch (e) {
        error.Invalid => die("{s}: {s}", .{ path, d.message }),
        error.OutOfMemory => oom(),
    };
    return .{ .path = path, .text = text, .layer = layer };
}

const Global = struct {
    profile: ?[]const u8 = null,
    project: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    buildenv: ?[]const u8 = null,
};

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const x = v orelse return null;
    return if (x.len > 0) x else null;
}

/// The configuration files in force, site first.
fn configSources(c: Ctx, g: Global) []const config.Source {
    var sources: std.ArrayList(config.Source) = .empty;
    if (g.config_file orelse nonEmpty(c.env.get("EB_LOCAL_CONFIG"))) |path| {
        // As in 1.x: the named file is the site configuration.
        if (!exists(path)) die("the configuration file {s} does not exist", .{path});
        sources.append(c.a, sourceFrom(c, path, .site)) catch oom();
        return sources.items;
    }
    const dir = selfDir(c.a);
    const candidates = [_][]const u8{
        std.fs.path.join(c.a, &.{ dir, "config.toml" }) catch oom(),
        "/etc/eb-local/config.toml",
        std.fs.path.join(c.a, &.{ dir, "eb-local.conf" }) catch oom(),
        "/etc/eb-local.conf",
    };
    for (candidates) |p| if (exists(p)) {
        sources.append(c.a, sourceFrom(c, p, .site)) catch oom();
        break;
    };
    const user_file: ?[]const u8 = if (nonEmpty(c.env.get("XDG_CONFIG_HOME"))) |x|
        std.fs.path.join(c.a, &.{ x, "eb-local", "config.toml" }) catch oom()
    else if (nonEmpty(c.env.get("HOME"))) |h|
        std.fs.path.join(c.a, &.{ h, ".config", "eb-local", "config.toml" }) catch oom()
    else
        null;
    if (user_file) |p| if (exists(p)) sources.append(c.a, sourceFrom(c, p, .user)) catch oom();
    return sources.items;
}

fn loadSettings(c: Ctx, g: Global) config.Settings {
    var d: config.Diagnostic = .{};
    return config.load(c.a, configSources(c, g), c.env, .{ .profile = g.profile, .project = g.project, .buildenv = g.buildenv }, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
}

/// The installation directory, absolute even before it exists.
fn place(c: Ctx, s: config.Settings) Place {
    if (s.project.value) |p| {
        const st = fsx.statAt(fsx.cwd, p, true) catch {
            cli.err("eb-local: project directory {s} does not exist.\n", .{p});
            cli.err("  The project owner creates it once, with the project group and g+s:\n", .{});
            cli.err("  mkdir -p {s} && chgrp <group> {s} && chmod 2770 {s}\n", .{ p, p, p });
            std.process.exit(2);
        };
        if (!st.isDir()) die("project directory {s} is not a directory", .{p});
        return .{ .prefix = storage.canonical(c.a, p, c.cwd) catch oom(), .project = true };
    }
    var raw = s.prefix.value;
    if (std.mem.startsWith(u8, raw, "~/") or std.mem.eql(u8, raw, "~")) {
        const home = nonEmpty(c.env.get("HOME")) orelse die("prefix {s} needs HOME", .{raw});
        raw = std.mem.concat(c.a, u8, &.{ home, raw[1..] }) catch oom();
    }
    return .{ .prefix = storage.canonical(c.a, raw, c.cwd) catch oom(), .project = false };
}

// ---- env, dev, config, profiles -------------------------------------------

fn cmdEnv(c: Ctx, s: config.Settings) u8 {
    evalHint("env");
    cli.put(1, environmentLines(c, s, place(c, s)));
    return 0;
}

fn cmdDev(c: Ctx, s: config.Settings, extra: []const []const u8) u8 {
    const a = c.a;
    var mods: std.ArrayList([]const u8) = .empty;
    mods.appendSlice(a, s.dev_modules.value) catch oom();
    mods.appendSlice(a, extra) catch oom();
    evalHint(str(a, "dev{s}{s}", .{ if (extra.len > 0) " " else "", std.mem.join(a, " ", extra) catch oom() }));
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, environmentLines(c, s, place(c, s))) catch oom();
    // The modules the program uses first, the build environment last: its
    // compiler wrappers then come first on PATH and record a run path for
    // the library directory of every loaded module, so the program runs
    // without LD_LIBRARY_PATH.
    if (mods.items.len > 0) {
        out.appendSlice(a, "module load") catch oom();
        for (mods.items) |m| out.appendSlice(a, str(a, " {s}", .{q(a, m)})) catch oom();
        out.append(a, '\n') catch oom();
    }
    out.appendSlice(a, str(a, "module load {s}\n", .{q(a, s.dev_buildenv.value)})) catch oom();
    cli.put(1, out.items);
    if (nonEmpty(c.env.get("LD_LIBRARY_PATH")) != null) {
        warn("LD_LIBRARY_PATH is set in this shell; programs built here do not need it,", .{});
        cli.err("  and it can mix host libraries into EESSI's. Unset it unless you know you need it.\n", .{});
    }
    return 0;
}

fn cmdConfig(c: Ctx, s: config.Settings, check: bool) u8 {
    const a = c.a;
    const p = place(c, s);
    const row = struct {
        fn f(key: []const u8, value: []const u8, from: []const u8) void {
            say("{s: <28} {s}   [{s}]", .{ key, value, from });
        }
    }.f;
    say("{s: <28} {s}", .{ "profile", s.profile orelse "(none)" });
    if (p.project) row("project", p.prefix, s.project.from) else row("prefix", p.prefix, s.prefix.from);
    row("stack.module", s.stack_module.value, s.stack_module.from);
    row("stack.extend", s.extend_module.value, s.extend_module.from);
    row("dev.buildenv", s.dev_buildenv.value, s.dev_buildenv.from);
    const mods = std.mem.join(a, " ", s.dev_modules.value) catch oom();
    row("dev.modules", if (mods.len == 0) "(none)" else mods, s.dev_modules.from);
    row("build.allocation_hint", if (s.allocation_hint.value.len == 0) "(none)" else s.allocation_hint.value, s.allocation_hint.from);
    row("clean.trash", @tagName(s.trash.value), s.trash.from);
    row("clean.logs_older_than_days", str(a, "{d}", .{s.logs_older_than_days.value}), s.logs_older_than_days.from);
    row("storage.node_local_root", if (s.node_local_root.value.len == 0) "(not set)" else s.node_local_root.value, s.node_local_root.from);
    row("storage.node_local_fstype", s.node_local_fstype.value, s.node_local_fstype.from);
    const scratch = std.mem.join(a, " ", s.shared_scratch.value) catch oom();
    row("storage.shared_scratch", if (scratch.len == 0) "(none)" else scratch, s.shared_scratch.from);
    if (s.secrets.items.len == 0) {
        say("{s: <28} (none)", .{"secrets"});
        return 0;
    }
    say("secrets (values are never shown)", .{});
    var failed = false;
    for (s.secrets.items) |sec| {
        if (!check) {
            say("  {s: <26} {s}   [{s}]", .{ sec.name, sec.source, sec.from });
            continue;
        }
        var f: secrets.Failure = .{};
        if (secrets.resolve(a, &.{sec}, c.env, c.envp, &f)) |_| {
            say("  {s: <26} {s}   ok", .{ sec.name, sec.source });
        } else |e| switch (e) {
            error.Unavailable => {
                say("  {s: <26} {s}   FAILED: {s}", .{ sec.name, sec.source, f.message });
                failed = true;
            },
            error.OutOfMemory => oom(),
        }
    }
    return if (failed) 1 else 0;
}

fn cmdProfiles(c: Ctx, g: Global) u8 {
    const sources = configSources(c, g);
    // Loading checks every profile in every file.
    var d: config.Diagnostic = .{};
    _ = config.load(c.a, sources, c.env, .{}, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
    var shown = false;
    for (sources) |src| {
        var td: toml.Diagnostic = .{};
        const t = toml.parse(c.a, src.text, &td) catch continue;
        for (config.profileNames(c.a, t) catch oom()) |name| {
            say("{s: <20} {s} {s}", .{ name, @tagName(src.layer), src.path });
            shown = true;
        }
    }
    if (!shown) say("no profiles are defined", .{});
    return 0;
}

// ---- running programs -----------------------------------------------------

/// Run a program on this terminal and wait for it. An interrupt reaches the
/// child (it shares the process group) while this process ignores it, so
/// that it can still report and clean up.
fn runAttached(a: Allocator, argv: []const []const u8, envp: proc.Envp) u8 {
    const zargv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch oom();
    for (argv, 0..) |x, i| zargv[i] = (a.dupeSentinel(u8, x, 0) catch oom()).ptr;
    const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    const sigs = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT };
    var old: [sigs.len]linux.Sigaction = undefined;
    for (sigs, 0..) |sg, i| _ = linux.sigaction(sg, &ign, &old[i]);
    defer for (sigs, 0..) |sg, i| {
        _ = linux.sigaction(sg, &old[i], null);
    };
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) die("cannot start {s}", .{argv[0]});
    if (pid == 0) {
        for (sigs) |sg| _ = linux.sigaction(sg, &dfl, null);
        const rc = linux.execve(zargv[0].?, zargv.ptr, envp);
        cli.err("eb-local: cannot run {s} ({s})\n", .{ argv[0], sys.describeErrno(linux.errno(rc)) });
        linux.exit_group(127);
    }
    var raw: i32 = 0;
    while (true) {
        const rc = linux.wait4(@intCast(pid), &raw, 0, null);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return 1,
        }
    }
    const status: u32 = @bitCast(raw);
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    if (linux.W.IFSIGNALED(status)) return @intCast(@min(255, 128 + @as(u32, @backingInt(linux.W.TERMSIG(status)))));
    return 1;
}

fn envpOf(a: Allocator, map: *const std.process.Environ.Map) proc.Envp {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| {
        const line = std.fmt.allocPrintSentinel(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0) catch oom();
        list.append(a, line.ptr) catch oom();
    }
    list.append(a, null) catch oom();
    return @ptrCast(list.items.ptr);
}

fn userName(c: Ctx) []const u8 {
    // A static binary has no NSS; id(1) asks the system's.
    const id = (proc.which(c.a, "id", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/usr/bin/id";
    const r = proc.run(c.a, id, &.{ id, "-un" }, c.envp, .{ .stdout_limit = 4096, .timeout_ms = 10_000 }) catch
        die("cannot determine the allocation user.", .{});
    if (r.term.code() != 0) die("cannot determine the allocation user.", .{});
    return std.mem.trim(u8, r.stdout, " \n");
}

fn mountinfoText(c: Ctx) []const u8 {
    var path: []const u8 = "/proc/self/mountinfo";
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_MOUNTINFO"))) |p| path = p;
    }
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch die("cannot read {s}", .{path});
    defer sys.close(fd);
    return fsx.readAll(c.a, fd, 8 << 20) catch die("cannot read {s}", .{path});
}

/// The caller's uid. Only the test artifact lets EB_LOCAL_TEST_UID stand in,
/// so that a test can make its own directory look like another user's.
fn callerUid(c: Ctx) linux.uid_t {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_UID"))) |v| return std.fmt.parseInt(linux.uid_t, v, 10) catch linux.getuid();
    }
    return linux.getuid();
}

fn checkedJobRoot(c: Ctx, s: config.Settings) []const u8 {
    if (s.node_local_root.value.len == 0) die("no node-local root is configured; set storage.node_local_root in the site configuration (see the README).", .{});
    var r: storage.Refusal = .{};
    const job_id = c.env.get("SLURM_JOB_ID") orelse "";
    const jr = storage.jobRoot(c.a, s.node_local_root.value, s.node_local_fstype.value, job_id, userName(c), mountinfoText(c), callerUid(c), &r) catch |e| switch (e) {
        error.Refused => die("{s}", .{r.message}),
        error.OutOfMemory => oom(),
    };
    return jr.path;
}

const Durable = struct {
    sources: []const u8,
    logs: []const u8,
};

/// Sources and logs live beside the installation, and must stay there.
fn durableDirs(c: Ctx, prefix: []const u8) Durable {
    const root = std.fs.path.join(c.a, &.{ prefix, ".eb-local" }) catch oom();
    const d: Durable = .{
        .sources = std.fs.path.join(c.a, &.{ root, "sources" }) catch oom(),
        .logs = std.fs.path.join(c.a, &.{ root, "logs" }) catch oom(),
    };
    for ([_][]const u8{ d.sources, d.logs }) |p| {
        const resolved = storage.canonical(c.a, p, c.cwd) catch oom();
        if (!storage.under(resolved, prefix) or std.mem.eql(u8, resolved, prefix))
            die("source and log directories must remain inside the durable prefix.", .{});
    }
    return d;
}

// ---- clean ----------------------------------------------------------------

const CleanOpts = struct {
    logs: bool = true,
    logs_days: ?u32 = null,
    sources: bool = false,
    workspaces: bool = false,
    dry_run: bool = false,
    delete: bool = false,
};

const Collect = struct {
    c: Ctx,
    out: std.ArrayList([]const u8) = .empty,

    /// Regular files below `path`, on its file system, never through a
    /// symbolic link; `cutoff` keeps only files modified before it.
    fn dir(self: *Collect, path: []const u8, cutoff: ?i64) void {
        const st = fsx.statAt(fsx.cwd, path, false) catch return;
        if (st.isLink()) die("{s} is reached through a symbolic link; clean leaves it alone.", .{path});
        if (!st.isDir()) return;
        var buf: [sys.path_max]u8 = undefined;
        const real = fsx.realpath(fsx.cwd, path, &buf) catch return;
        if (!std.mem.eql(u8, real, path)) die("{s} is reached through a symbolic link; clean leaves it alone.", .{path});
        self.walk(path, st.dev, cutoff, 0);
    }

    fn walk(self: *Collect, path: []const u8, dev: u64, cutoff: ?i64, depth: usize) void {
        if (depth > 16) return;
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(self.c.a, fd) catch return;
        while (it.next() catch null) |e| {
            const st = fsx.statAt(fd, e.name, false) catch continue;
            if (st.dev != dev) continue;
            const child = std.fs.path.join(self.c.a, &.{ path, e.name }) catch oom();
            if (st.isDir()) {
                self.walk(child, dev, cutoff, depth + 1);
            } else if (st.isReg()) {
                if (cutoff) |cut| if (st.mtime.sec >= cut) continue;
                self.out.append(self.c.a, child) catch oom();
            }
        }
    }
};

fn removeEmptyDirs(c: Ctx, path: []const u8, depth: usize) void {
    if (depth > 16) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (!st.isDir()) continue;
        removeEmptyDirs(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), depth + 1);
        sys.unlinkat(fd, e.name, linux.AT.REMOVEDIR) catch {};
    }
}

fn cmdClean(c: Ctx, s: config.Settings, o: CleanOpts) u8 {
    const a = c.a;
    var job_root: ?[]const u8 = null;
    if (o.workspaces) {
        if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null) die("--workspaces works inside the allocation that made them.", .{});
        job_root = checkedJobRoot(c, s);
    }
    const p = place(c, s);
    const d = durableDirs(c, p.prefix);
    var trash = s.trash.value;
    const rtrash = proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null;
    switch (trash) {
        .auto => trash = if (rtrash != null) .rtrash else .none,
        .rtrash => if (rtrash == null) die("clean.trash is rtrash, but rtrash is not on PATH.", .{}),
        .none => {},
    }
    // find -mtime +N: more than N whole days old.
    const days: i64 = o.logs_days orelse s.logs_older_than_days.value;
    const now: i64 = nowSecs();
    var collect: Collect = .{ .c = c };
    if (o.logs) collect.dir(d.logs, now - (days + 1) * 86400 + 1);
    if (o.sources) collect.dir(d.sources, null);
    var spaces: std.ArrayList([]const u8) = .empty;
    if (job_root) |jr| {
        const fd = fsx.openDir(fsx.cwd, jr, false) catch die("cannot read {s}", .{jr});
        defer sys.close(fd);
        var it = fsx.DirIter.init(a, fd) catch die("cannot read {s}", .{jr});
        while (it.next() catch null) |e| {
            const full = std.fs.path.join(a, &.{ jr, e.name }) catch oom();
            if (storage.ownWorkspace(jr, full, callerUid(c))) spaces.append(a, full) catch oom();
        }
    }
    const targets = collect.out.items;
    if (targets.len == 0 and spaces.items.len == 0) {
        say("eb-local: nothing to clean in {s}", .{p.prefix});
        return 0;
    }
    for (targets) |t| say("  {s}", .{t});
    for (spaces.items) |w| say("  {s}/ (build workspace)", .{w});
    if (o.dry_run) {
        say("eb-local: dry run, nothing removed ({d} file(s), {d} workspace(s))", .{ targets.len, spaces.items.len });
        return 0;
    }
    // Build workspaces are node-local scratch the scheduler removes anyway;
    // they are deleted, not trashed.
    for (spaces.items) |w| fsx.deleteTree(a, fsx.cwd, w) catch |e| warn("cannot remove {s} ({s})", .{ w, @errorName(e) });
    if (targets.len > 0) {
        if (trash == .rtrash) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(a, &.{ rtrash.?, "put", "--" }) catch oom();
            argv.appendSlice(a, targets) catch oom();
            const rc = runAttached(a, argv.items, c.envp);
            if (rc != 0) die("rtrash put exited {d}", .{rc});
            say("eb-local: moved {d} file(s) to the trash (rtrash list, rtrash restore)", .{targets.len});
        } else if (o.delete) {
            for (targets) |t| sys.unlinkat(fsx.cwd, t, 0) catch |e| warn("cannot remove {s} ({s})", .{ t, @errorName(e) });
            say("eb-local: deleted {d} file(s)", .{targets.len});
        } else {
            warn("rtrash is not installed; nothing deleted. Install rtrash, or pass --delete to delete for good.", .{});
            return 1;
        }
        for ([_][]const u8{ d.logs, d.sources }) |dir| removeEmptyDirs(c, dir, 0);
    }
    return 0;
}

// ---- build ----------------------------------------------------------------

/// The part of a build that needs Lmod runs in bash. The stack, extension,
/// install variable, prefix and mode come as arguments and the easyconfig
/// arguments after them, so nothing a user typed is part of the script.
const build_script =
    \\set -eo pipefail
    \\stack=$1 extend=$2 install_var=$3 prefix=$4 mode=$5
    \\shift 5
    \\keep=(WORKING_DIR TMPDIR TMP TEMP EASYBUILD_BUILDPATH EASYBUILD_TMPDIR XDG_CACHE_HOME CARGO_HOME EASYBUILD_SOURCEPATH EASYBUILD_TMP_LOGDIR)
    \\declare -A saved
    \\for v in "${keep[@]}"; do saved[$v]=${!v}; done
    \\restore() { for v in "${keep[@]}"; do export "$v=${saved[$v]}"; done; }
    \\if ! type module >/dev/null 2>&1; then
    \\    for init in "${LMOD_PKG:-/usr/share/lmod/lmod}/init/bash" /etc/profile.d/lmod.sh; do
    \\        [ -r "$init" ] && { source "$init"; break; }
    \\    done
    \\fi
    \\type module >/dev/null 2>&1 || { echo "eb-local: no module command found" >&2; exit 1; }
    \\# EESSI-extend reads the variables when it loads, so it is loaded fresh.
    \\module unload "$extend" >/dev/null 2>&1 || true
    \\unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL
    \\unset EESSI_SITE_SOFTWARE_PREFIX
    \\unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK
    \\unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX
    \\restore
    \\export "$install_var=$prefix"
    \\module load "$stack" "$extend" >/dev/null 2>&1 || { echo "eb-local: could not load $stack and $extend" >&2; exit 1; }
    \\restore
    \\echo "eb-local: installing into $prefix ($mode)"
    \\echo "eb-local: target $EESSI_SOFTWARE_SUBDIR${EESSI_ACCELERATOR_TARGET:+ + $EESSI_ACCELERATOR_TARGET}, build space ${saved[EASYBUILD_BUILDPATH]%/build}"
    \\eb --umask=022 "$@"
;

fn cmdBuild(c: Ctx, s: config.Settings, args: []const []const u8) u8 {
    const a = c.a;
    if (args.len == 0) {
        cli.err("{s}", .{usage_text});
        return 2;
    }
    if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null) {
        warn("not inside a Slurm job.", .{});
        cli.err("  Software is built for the CPU of the node that runs eb-local, so build\n", .{});
        cli.err("  inside an allocation on the node type that will run it{s}\n", .{if (s.allocation_hint.value.len > 0) ", for example:" else ""});
        if (s.allocation_hint.value.len > 0) cli.err("  {s}\n", .{s.allocation_hint.value});
        return 2;
    }
    const job_root = checkedJobRoot(c, s);
    var p = place(c, s);
    for (s.shared_scratch.value) |refused| if (storage.under(p.prefix, refused))
        die("installation, source and log paths must use durable owned storage.", .{});
    if (storage.under(p.prefix, s.node_local_root.value)) die("installation, source and log paths must use durable owned storage.", .{});
    common.atomic.makedirs(p.prefix) catch die("installation prefix is not writable.", .{});
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = sys.z(&zb, p.prefix) catch die("installation prefix is not writable.", .{});
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0)) != .SUCCESS)
            die("installation prefix is not writable.", .{});
        var buf: [sys.path_max]u8 = undefined;
        p.prefix = a.dupe(u8, fsx.realpath(fsx.cwd, p.prefix, &buf) catch die("cannot resolve installation prefix.", .{})) catch oom();
    }
    const d = durableDirs(c, p.prefix);

    // Secrets before anything is made, so a missing one leaves nothing behind.
    var failure: secrets.Failure = .{};
    const values = secrets.resolve(a, s.secrets.items, c.env, c.envp, &failure) catch |e| switch (e) {
        error.Unavailable => die("{s}", .{failure.message}),
        error.OutOfMemory => oom(),
    };

    const work = storage.makeWorkspace(a, job_root) catch die("cannot create allocation workspace.", .{});
    for ([_][]const u8{ "build", "tmp", "cache", "cargo", "source-index" }) |sub|
        common.atomic.makedirs(std.fs.path.join(a, &.{ work, sub }) catch oom()) catch die("cannot create allocation workspace.", .{});
    common.atomic.makedirs(d.sources) catch die("cannot create {s}", .{d.sources});
    common.atomic.makedirs(d.logs) catch die("cannot create {s}", .{d.logs});
    const started: i64 = nowSecs();

    var env = c.env.clone(a) catch oom();
    for (install_vars) |v| _ = env.swapRemove(v);
    const tmp = std.fs.path.join(a, &.{ work, "tmp" }) catch oom();
    const pairs = [_][2][]const u8{
        .{ "WORKING_DIR", std.fs.path.join(a, &.{ work, "source-index" }) catch oom() },
        .{ "TMPDIR", tmp },
        .{ "TMP", tmp },
        .{ "TEMP", tmp },
        .{ "EASYBUILD_BUILDPATH", std.fs.path.join(a, &.{ work, "build" }) catch oom() },
        .{ "EASYBUILD_TMPDIR", tmp },
        .{ "XDG_CACHE_HOME", std.fs.path.join(a, &.{ work, "cache" }) catch oom() },
        .{ "CARGO_HOME", std.fs.path.join(a, &.{ work, "cargo" }) catch oom() },
        .{ "EASYBUILD_SOURCEPATH", d.sources },
        .{ "EASYBUILD_TMP_LOGDIR", d.logs },
        .{ "LMOD_EXACT_MATCH", "no" },
    };
    for (pairs) |kv| env.put(kv[0], kv[1]) catch oom();
    for (values) |v| env.put(v.name, v.value) catch oom();

    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{
        bash,                 "--noprofile",         "--norc",                                                         "-c",     build_script,                         "eb-local",
        s.stack_module.value, s.extend_module.value, if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", p.prefix, if (p.project) "project" else "user",
    }) catch oom();
    argv.appendSlice(a, args) catch oom();
    const rc = runAttached(a, argv.items, envpOf(a, &env));

    if (values.len > 0) {
        var report: secrets.RedactReport = .{};
        secrets.redactTree(a, d.logs, started, values, &report) catch |e| warn("cannot check the logs for secrets ({s})", .{@errorName(e)});
        if (report.files > 0) say("eb-local: removed secret values from {d} log file(s)", .{report.files});
        for (report.too_large.items) |f| warn("{s} is too large to check for secret values; inspect it before sharing", .{f});
    }

    const keep = std.mem.eql(u8, c.env.get("EB_LOCAL_KEEP_WORK") orelse "", "1");
    if (rc == 0 and !keep) {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) fsx.deleteTree(a, fsx.cwd, work) catch |e|
            warn("cannot remove {s} ({s}); it goes when the allocation ends", .{ work, @errorName(e) });
    } else {
        warn("build workspace kept at {s}; it goes when the allocation ends,", .{work});
        cli.err("  or now with: eb-local clean --workspaces --no-logs\n", .{});
    }
    if (rc == 0) {
        say("", .{});
        say("eb-local: done. To use the modules in a new shell or job:", .{});
        if (p.project) say("  eval \"$(eb-local env --project {s})\"", .{q(a, p.prefix)}) else say("  eval \"$(eb-local env)\"", .{});
    }
    return rc;
}

// ---- entry ----------------------------------------------------------------

const Command = enum { build, env, dev, clean, config, profiles };

pub fn main(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    const argv_all = init.minimal.args.toSlice(a) catch die("cannot read the arguments", .{});
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = a.dupe(u8, fsx.realpath(fsx.cwd, ".", &cwd_buf) catch "/") catch oom();
    const c: Ctx = .{ .a = a, .env = init.environ_map, .envp = init.minimal.environ.block.slice.ptr, .cwd = cwd };

    var args: []const [:0]const u8 = argv_all[1..];
    var command: Command = .build;
    if (args.len > 0) {
        const first: []const u8 = args[0];
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            cli.put(1, usage_text);
            return 0;
        }
        if (std.mem.eql(u8, first, "--version")) {
            cli.put(1, comptime cli.versionLine(tool, version, build_options.commit));
            return 0;
        }
        if (std.meta.stringToEnum(Command, first)) |cmd| {
            if (cmd != .build) {
                command = cmd;
                args = args[1..];
            }
        } else if (std.mem.eql(u8, first, "--env")) {
            command = .env;
            args = args[1..];
        }
    }

    var g: Global = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    var clean: CleanOpts = .{};
    var check = false;
    var i: usize = 0;
    const value = struct {
        fn get(xs: []const [:0]const u8, idx: *usize, opt: []const u8) []const u8 {
            if (idx.* + 1 >= xs.len or xs[idx.* + 1].len == 0) die("{s} needs a value", .{opt});
            idx.* += 1;
            return xs[idx.*];
        }
    }.get;
    while (i < args.len) : (i += 1) {
        const x: []const u8 = args[i];
        if (std.mem.eql(u8, x, "-h") or std.mem.eql(u8, x, "--help")) {
            cli.put(1, usage_text);
            return 0;
        } else if (std.mem.eql(u8, x, "--project")) {
            g.project = value(args, &i, "--project");
        } else if (std.mem.startsWith(u8, x, "--project=")) {
            g.project = x["--project=".len..];
        } else if (std.mem.eql(u8, x, "--profile")) {
            g.profile = value(args, &i, "--profile");
        } else if (std.mem.startsWith(u8, x, "--profile=")) {
            g.profile = x["--profile=".len..];
        } else if (std.mem.eql(u8, x, "--config")) {
            g.config_file = value(args, &i, "--config");
        } else if (std.mem.eql(u8, x, "--env") and command == .build and rest.items.len == 0) {
            command = .env;
        } else switch (command) {
            .build => rest.append(a, x) catch oom(),
            .env, .profiles => die("{s} takes only --project, --profile and --config; got '{s}'", .{ @tagName(command), x }),
            .config => {
                if (!std.mem.eql(u8, x, "--check")) die("config does not know '{s}'", .{x});
                check = true;
            },
            .dev => {
                if (std.mem.eql(u8, x, "--buildenv")) {
                    g.buildenv = value(args, &i, "--buildenv");
                } else if (std.mem.startsWith(u8, x, "--buildenv=")) {
                    g.buildenv = x["--buildenv=".len..];
                } else if (x.len > 0 and x[0] == '-') {
                    die("dev does not know the option '{s}'", .{x});
                } else if (!config.validModule(x)) {
                    die("'{s}' is not a module name", .{x});
                } else rest.append(a, x) catch oom();
            },
            .clean => {
                if (std.mem.eql(u8, x, "--logs-older-than")) {
                    const v = value(args, &i, "--logs-older-than");
                    const n = std.fmt.parseInt(u32, v, 10) catch die("--logs-older-than needs a number of days", .{});
                    if (n > 99999) die("--logs-older-than needs a number of days", .{});
                    clean.logs_days = n;
                } else if (std.mem.eql(u8, x, "--no-logs")) {
                    clean.logs = false;
                } else if (std.mem.eql(u8, x, "--sources")) {
                    clean.sources = true;
                } else if (std.mem.eql(u8, x, "--workspaces")) {
                    clean.workspaces = true;
                } else if (std.mem.eql(u8, x, "--dry-run")) {
                    clean.dry_run = true;
                } else if (std.mem.eql(u8, x, "--delete")) {
                    clean.delete = true;
                } else die("clean does not know '{s}'", .{x});
            },
        }
    }

    if (command == .profiles) return cmdProfiles(c, g);
    const s = loadSettings(c, g);
    return switch (command) {
        .env => cmdEnv(c, s),
        .dev => cmdDev(c, s, rest.items),
        .config => cmdConfig(c, s, check),
        .clean => cmdClean(c, s, clean),
        .build => cmdBuild(c, s, rest.items),
        .profiles => unreachable,
    };
}

test {
    _ = toml;
    _ = config;
    _ = secrets;
    _ = storage;
}

test "shell quoting reads back as the same word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("EESSI/2026.06", try shellQuote(a, "EESSI/2026.06"));
    try std.testing.expectEqualStrings("/gpfs/home3/u/eessi", try shellQuote(a, "/gpfs/home3/u/eessi"));
    try std.testing.expectEqualStrings("'owned space'", try shellQuote(a, "owned space"));
    try std.testing.expectEqualStrings("'a'\\''b $(x)'", try shellQuote(a, "a'b $(x)"));
    try std.testing.expectEqualStrings("''", try shellQuote(a, ""));
}
