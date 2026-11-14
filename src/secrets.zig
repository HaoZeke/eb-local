//! Secrets for a build: each names the variable eb receives and where its
//! value comes from. Values are read only for a build, after every other
//! check, go only into eb's environment, and are never printed. A failed
//! read reports why without the value. After the build, logs written during
//! it are scanned and every occurrence of a value is replaced.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const config = @import("config.zig");
const Allocator = std.mem.Allocator;

/// Largest secret accepted from any source.
pub const value_limit = 64 * 1024;
/// How long nimvault may take (a GPG agent may ask for a passphrase).
pub const nimvault_timeout_ms = 30_000;

pub const Resolved = struct {
    name: []const u8,
    value: []const u8,
};

pub const Failure = struct {
    message: []const u8 = "",
};

pub const Error = error{Unavailable} || Allocator.Error;

fn fail(a: Allocator, f: *Failure, comptime fmt: []const u8, args: anytype) Error {
    f.message = try std.fmt.allocPrint(a, fmt, args);
    return error.Unavailable;
}

/// One trailing newline, as files and command output usually end, is not
/// part of the value.
fn trimNewline(v: []const u8) []const u8 {
    if (std.mem.endsWith(u8, v, "\r\n")) return v[0 .. v.len - 2];
    if (std.mem.endsWith(u8, v, "\n")) return v[0 .. v.len - 1];
    return v;
}

fn checked(a: Allocator, f: *Failure, s: config.Secret, v: []const u8) Error![]const u8 {
    if (v.len == 0) return fail(a, f, "secret {s} ({s}) is empty", .{ s.name, s.source });
    if (std.mem.indexOfScalar(u8, v, 0) != null) return fail(a, f, "secret {s} ({s}) holds a NUL byte", .{ s.name, s.source });
    return v;
}

fn fromFile(a: Allocator, f: *Failure, s: config.Secret, raw_path: []const u8, home: ?[]const u8) Error![]const u8 {
    const path = if (std.mem.startsWith(u8, raw_path, "~/")) blk: {
        const h = home orelse return fail(a, f, "secret {s}: {s} needs HOME", .{ s.name, s.source });
        break :blk try std.fs.path.join(a, &.{ h, raw_path[2..] });
    } else raw_path;
    const opened = fsx.openRegular(fsx.cwd, path, false) catch |e|
        return fail(a, f, "secret {s}: cannot open {s} ({s}); a symbolic link is not followed", .{ s.name, path, @errorName(e) });
    defer sys.close(opened.fd);
    const st = opened.stat;
    if (st.uid != linux.getuid()) return fail(a, f, "secret {s}: {s} is not owned by you", .{ s.name, path });
    if (st.mode & 0o077 != 0) return fail(a, f, "secret {s}: {s} is readable or writable by others; chmod 600 it", .{ s.name, path });
    if (st.nlink != 1) return fail(a, f, "secret {s}: {s} has more than one link", .{ s.name, path });
    const bytes = fsx.readAll(a, opened.fd, value_limit) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return fail(a, f, "secret {s}: {s} is larger than {d} bytes", .{ s.name, path, value_limit }),
        else => return fail(a, f, "secret {s}: cannot read {s} ({s})", .{ s.name, path, @errorName(e) }),
    };
    return checked(a, f, s, trimNewline(bytes));
}

fn fromNimvault(a: Allocator, f: *Failure, s: config.Secret, entry: []const u8, env: *const std.process.Environ.Map, envp: proc.Envp) Error![]const u8 {
    const path_env = env.get("PATH") orelse "";
    const exe = (try proc.which(a, "nimvault", path_env)) orelse
        return fail(a, f, "secret {s}: nimvault is not on PATH", .{s.name});
    const r = proc.run(a, exe, &.{ exe, "get", entry }, envp, .{
        .stdout_limit = value_limit,
        .stderr_limit = 4096,
        .timeout_ms = nimvault_timeout_ms,
        .grace_ms = 1000,
        .exec_error = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimedOut => return fail(a, f, "secret {s}: nimvault get {s} took longer than {d} s (is the GPG agent waiting for a passphrase?)", .{ s.name, entry, nimvault_timeout_ms / 1000 }),
        error.StreamTooLong => return fail(a, f, "secret {s}: nimvault get {s} printed more than {d} bytes", .{ s.name, entry, value_limit }),
        else => return fail(a, f, "secret {s}: cannot run {s} ({s})", .{ s.name, exe, @errorName(e) }),
    };
    if (r.term.code() != 0) {
        // Its stderr, never its stdout: a partial value must not be shown.
        const why = std.mem.trim(u8, r.stderr, " \t\r\n");
        return fail(a, f, "secret {s}: nimvault get {s} exited {d}{s}{s}", .{ s.name, entry, r.term.code(), if (why.len > 0) ": " else "", why });
    }
    return checked(a, f, s, trimNewline(r.stdout));
}

/// The value of every secret, in order.
pub fn resolve(
    a: Allocator,
    secrets: []const config.Secret,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    f: *Failure,
) Error![]Resolved {
    var out: std.ArrayList(Resolved) = .empty;
    for (secrets) |s| {
        const colon = std.mem.indexOfScalar(u8, s.source, ':').?;
        const kind = s.source[0..colon];
        const rest = s.source[colon + 1 ..];
        const value = if (std.mem.eql(u8, kind, "env"))
            try checked(a, f, s, env.get(rest) orelse return fail(a, f, "secret {s}: {s} is not set", .{ s.name, rest }))
        else if (std.mem.eql(u8, kind, "file"))
            try fromFile(a, f, s, rest, env.get("HOME"))
        else
            try fromNimvault(a, f, s, rest, env, envp);
        try out.append(a, .{ .name = s.name, .value = value });
    }
    return out.items;
}

/// What stands in for a value in a redacted log.
pub fn placeholder(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "<secret {s} removed by eb-local>", .{name});
}

/// The forms a value takes in a log: as it is, base64 (an HTTP basic
/// authorization header) and percent-encoded (a URL).
fn variants(a: Allocator, value: []const u8) Allocator.Error![3][]const u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(value.len));
    _ = enc.encode(b64, value);
    var url: std.ArrayList(u8) = .empty;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null) {
            try url.append(a, c);
        } else {
            try url.appendSlice(a, try std.fmt.allocPrint(a, "%{X:0>2}", .{c}));
        }
    }
    return .{ value, b64, url.items };
}

/// Shorter values would match ordinary text everywhere; they are not
/// redacted, and a build that has one is told so.
pub const min_redacted_len = 4;

/// Replace every value, in each of its forms, in `bytes`; null when none occurs.
pub fn redactText(a: Allocator, bytes: []const u8, values: []const Resolved) Allocator.Error!?[]u8 {
    var current: []const u8 = bytes;
    var changed = false;
    for (values) |v| {
        if (v.value.len < min_redacted_len) continue;
        for (try variants(a, v.value)) |form| {
            if (form.len < min_redacted_len or std.mem.indexOf(u8, current, form) == null) continue;
            current = try std.mem.replaceOwned(u8, a, current, form, try placeholder(a, v.name));
            changed = true;
        }
    }
    return if (changed) @constCast(current) else null;
}

/// Largest log rewritten; a larger one is reported, not rewritten.
pub const log_limit: usize = 1 << 30;
/// Deepest directory searched; anything deeper is reported.
pub const max_depth = 16;

pub const RedactReport = struct {
    files: usize = 0,
    too_large: std.ArrayList([]const u8) = .empty,
    too_deep: std.ArrayList([]const u8) = .empty,
};

pub const Filter = enum {
    /// Every regular file.
    all,
    /// Only files in a directory named "easybuild": the logs and recipes an
    /// installation keeps, not the installed software itself.
    easybuild_dirs,
};

/// Redact regular files below `dir` (never through a symbolic link)
/// modified at or after `since` (seconds).
pub fn redactTree(a: Allocator, dir_path: []const u8, since: i64, values: []const Resolved, filter: Filter, report: *RedactReport) (fsx.Error || Allocator.Error)!void {
    if (values.len == 0) return;
    const dir = fsx.openDir(fsx.cwd, dir_path, false) catch |e| switch (e) {
        error.NotFound => return,
        else => return e,
    };
    defer sys.close(dir);
    try redactDir(a, dir, dir_path, since, values, filter, report, 0);
}

fn redactDir(a: Allocator, dir: sys.fd_t, path: []const u8, since: i64, values: []const Resolved, filter: Filter, report: *RedactReport, depth: usize) (fsx.Error || Allocator.Error)!void {
    const in_easybuild = std.mem.eql(u8, std.fs.path.basename(path), "easybuild");
    if (filter == .easybuild_dirs and !in_easybuild) {
        // An installation's root holds easybuild/; only that is searched,
        // not the installed software beside it.
        const is_root = if (fsx.statAt(dir, "easybuild", false)) |st| st.isDir() else |_| false;
        if (is_root) {
            const sub = fsx.openDir(dir, "easybuild", false) catch return;
            defer sys.close(sub);
            return redactDir(a, sub, try std.fs.path.join(a, &.{ path, "easybuild" }), since, values, filter, report, depth + 1);
        }
    }
    var it = try fsx.DirIter.init(a, dir);
    while (try it.next()) |e| {
        const st = fsx.statAt(dir, e.name, false) catch continue;
        const child = try std.fs.path.join(a, &.{ path, e.name });
        if (st.isDir()) {
            if (depth >= max_depth) {
                if (filter == .all) try report.too_deep.append(a, child);
                continue;
            }
            const sub = fsx.openDir(dir, e.name, false) catch continue;
            defer sys.close(sub);
            try redactDir(a, sub, child, since, values, filter, report, depth + 1);
            continue;
        }
        if (!st.isReg() or st.mtime.sec < since) continue;
        if (filter == .easybuild_dirs and !in_easybuild) continue;
        if (st.size > log_limit) {
            try report.too_large.append(a, child);
            continue;
        }
        const opened = fsx.openRegular(dir, e.name, false) catch continue;
        const bytes = fsx.readAll(a, opened.fd, log_limit) catch {
            sys.close(opened.fd);
            continue;
        };
        sys.close(opened.fd);
        if (try redactText(a, bytes, values)) |clean| {
            try fsx.replaceContents(a, dir, e.name, clean);
            report.files += 1;
        }
    }
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    env: std.process.Environ.Map,

    fn init() !Scratch {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = arena.allocator();
        var cwd_buf: [sys.path_max]u8 = undefined;
        const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
        const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/secrets-test-{d}", .{ cwd, linux.getpid() });
        try common.atomic.makedirs(root);
        return .{ .arena = arena, .root = root, .env = std.process.Environ.Map.init(testing.allocator) };
    }

    fn deinit(s: *Scratch) void {
        fsx.deleteTree(s.arena.allocator(), fsx.cwd, s.root) catch {};
        s.env.deinit();
        s.arena.deinit();
    }

    fn write(s: *Scratch, name: []const u8, text: []const u8, mode: u32) ![]const u8 {
        const path = try std.fs.path.join(s.arena.allocator(), &.{ s.root, name });
        const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
        defer sys.close(fd);
        try sys.writeAll(fd, text);
        try sys.fchmod(fd, mode);
        return path;
    }
};

const no_env: proc.Envp = &[_:null]?[*:0]const u8{};

fn resolveOne(s: *Scratch, source: []const u8) !struct { value: ?[]const u8, message: []const u8 } {
    var f: Failure = .{};
    const r = resolve(s.arena.allocator(), &.{.{ .name = "TOKEN", .source = source, .from = "test" }}, &s.env, no_env, &f) catch |e| switch (e) {
        error.Unavailable => return .{ .value = null, .message = f.message },
        else => return e,
    };
    return .{ .value = r[0].value, .message = "" };
}

test "env and file sources, and why a file is refused" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.env.put("MY_TOKEN", "from-the-environment");
    try testing.expectEqualStrings("from-the-environment", (try resolveOne(&s, "env:MY_TOKEN")).value.?);
    try testing.expect(std.mem.indexOf(u8, (try resolveOne(&s, "env:ABSENT")).message, "ABSENT is not set") != null);

    const good = try s.write("good", "s3cret-value\n", 0o600);
    const good_src = try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{good});
    try testing.expectEqualStrings("s3cret-value", (try resolveOne(&s, good_src)).value.?);

    const open = try s.write("open", "x-value\n", 0o644);
    const r = try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{open}));
    try testing.expect(r.value == null and std.mem.indexOf(u8, r.message, "chmod 600") != null);
    // The value never appears in a refusal.
    try testing.expect(std.mem.indexOf(u8, r.message, "x-value") == null);

    const empty = try s.write("empty", "\n", 0o600);
    try testing.expect(std.mem.indexOf(u8, (try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{empty}))).message, "empty") != null);

    const link = try std.fs.path.join(s.arena.allocator(), &.{ s.root, "link" });
    var zt: [sys.path_max:0]u8 = undefined;
    var zl: [sys.path_max:0]u8 = undefined;
    _ = linux.symlinkat((try sys.z(&zt, good)).ptr, linux.AT.FDCWD, (try sys.z(&zl, link)).ptr);
    try testing.expect((try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{link}))).value == null);
}

test "nimvault: the value from stdout, the reason from stderr only" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.write("nimvault",
        \\#!/bin/sh
        \\[ "$1" = get ] || exit 64
        \\case "$2" in
        \\  ok) printf 'vault-value\n' ;;
        \\  leak) printf 'partial-value'; echo 'gpg: decryption failed' >&2; exit 2 ;;
        \\  *) echo "no entry $2" >&2; exit 1 ;;
        \\esac
    , 0o700);
    try s.env.put("PATH", s.root);
    try testing.expectEqualStrings("vault-value", (try resolveOne(&s, "nimvault:ok")).value.?);
    const r = try resolveOne(&s, "nimvault:leak");
    try testing.expect(r.value == null);
    try testing.expect(std.mem.indexOf(u8, r.message, "decryption failed") != null);
    try testing.expect(std.mem.indexOf(u8, r.message, "partial-value") == null);
    try s.env.put("PATH", "/nonexistent");
    try testing.expect(std.mem.indexOf(u8, (try resolveOne(&s, "nimvault:ok")).message, "not on PATH") != null);
}

test "logs written during the build are redacted" {
    var s = try Scratch.init();
    defer s.deinit();
    const a = s.arena.allocator();
    try common.atomic.makedirs(try std.fs.path.join(a, &.{ s.root, "logs", "sub" }));
    const log = try s.write("logs/sub/easybuild.log", "export TOKEN=s3cret-value\nother line s3cret-value\n", 0o640);
    _ = try s.write("logs/clean.log", "nothing here\n", 0o644);
    const values = [_]Resolved{ .{ .name = "TOKEN", .value = "s3cret-value" }, .{ .name = "SHORT", .value = "ab" } };
    var report: RedactReport = .{};
    try redactTree(a, try std.fs.path.join(a, &.{ s.root, "logs" }), 0, &values, .all, &report);
    try testing.expectEqual(@as(usize, 1), report.files);
    const opened = try fsx.openRegular(fsx.cwd, log, false);
    defer sys.close(opened.fd);
    const text = try fsx.readAll(a, opened.fd, 4096);
    try testing.expect(std.mem.indexOf(u8, text, "s3cret-value") == null);
    try testing.expect(std.mem.indexOf(u8, text, "<secret TOKEN removed by eb-local>") != null);
    try testing.expectEqual(@as(u32, 0o640), opened.stat.perm());
}

test "a value is removed as it is, in base64 and percent-encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]Resolved{.{ .name = "T", .value = "p@ss word/1" }};
    const text = "raw p@ss word/1 b64 cEBzcyB3b3JkLzE= url p%40ss%20word%2F1 end";
    const clean = (try redactText(a, text, &values)).?;
    try testing.expect(std.mem.indexOf(u8, clean, "p@ss") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "cEBzcyB3b3JkLzE=") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "p%40ss") == null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, clean, "<secret T removed by eb-local>"));
}
