//! Where a build may write: the allocation's own node-local mount, and a
//! durable installation prefix that is neither node-local nor shared
//! scratch. Mounts are read from /proc/self/mountinfo.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const Allocator = std.mem.Allocator;

pub const Refusal = struct {
    message: []const u8 = "",
};

pub const Error = error{Refused} || Allocator.Error;

fn refuse(a: Allocator, r: *Refusal, comptime fmt: []const u8, args: anytype) Error {
    r.message = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

pub const Mount = struct {
    target: []const u8,
    fstype: []const u8,
    options: []const u8,
};

/// mountinfo escapes space, tab, newline and backslash as \ooo.
fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |c| {
                try out.append(a, c);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

/// The mount `path` lies on: the last entry (a later mount covers an
/// earlier one) whose target is `path` or a parent of it.
pub fn mountOf(a: Allocator, mountinfo: []const u8, path: []const u8) Allocator.Error!?Mount {
    var best: ?Mount = null;
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        var head = std.mem.tokenizeScalar(u8, line[0..sep], ' ');
        var fields: [6][]const u8 = undefined;
        var n: usize = 0;
        while (head.next()) |f| : (n += 1) {
            if (n < fields.len) fields[n] = f;
        }
        if (n < 6) continue;
        var tail = std.mem.tokenizeScalar(u8, line[sep + 3 ..], ' ');
        const fstype = tail.next() orelse continue;
        const target = try unescape(a, fields[4]);
        const inside = std.mem.eql(u8, target, "/") or std.mem.eql(u8, path, target) or
            (std.mem.startsWith(u8, path, target) and path.len > target.len and path[target.len] == '/');
        if (!inside) continue;
        if (best) |b| if (target.len < b.target.len) continue;
        best = .{ .target = target, .fstype = fstype, .options = fields[5] };
    }
    return best;
}

/// `path` made absolute and normal: the deepest part that exists is
/// resolved through symbolic links, the rest is joined on with . and ..
/// applied, as `readlink -m` does.
pub fn canonical(a: Allocator, path: []const u8, cwd: []const u8) Allocator.Error![]const u8 {
    const abs = if (path.len > 0 and path[0] == '/') path else try std.fs.path.join(a, &.{ cwd, path });
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, p);
    }
    // The longest existing prefix, resolved.
    var k: usize = parts.items.len;
    while (true) : (k -= 1) {
        const prefix = try std.mem.concat(a, u8, &.{ "/", try std.mem.join(a, "/", parts.items[0..k]) });
        var buf: [sys.path_max]u8 = undefined;
        if (fsx.realpath(fsx.cwd, prefix, &buf)) |real| {
            const rest = parts.items[k..];
            if (rest.len == 0) return try a.dupe(u8, real);
            const tail = try std.mem.join(a, "/", rest);
            return if (std.mem.eql(u8, real, "/")) try std.mem.concat(a, u8, &.{ "/", tail }) else try std.mem.concat(a, u8, &.{ real, "/", tail });
        } else |_| {}
        if (k == 0) break;
    }
    return std.mem.concat(a, u8, &.{ "/", try std.mem.join(a, "/", parts.items) });
}

pub fn under(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    return std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/';
}

pub const JobRoot = struct {
    path: []const u8,
};

/// The allocation's node-local mount: <root>/<user>.<job id>, an owned,
/// writable, canonical directory that is its own mount of `fstype`.
pub fn jobRoot(
    a: Allocator,
    node_local_root: []const u8,
    fstype: []const u8,
    job_id: []const u8,
    user: []const u8,
    mountinfo: []const u8,
    r: *Refusal,
) Error!JobRoot {
    if (job_id.len == 0 or job_id[0] == '0') return refuse(a, r, "invalid Slurm allocation identity.", .{});
    for (job_id) |c| if (!std.ascii.isDigit(c)) return refuse(a, r, "invalid Slurm allocation identity.", .{});
    if (user.len == 0 or std.mem.indexOfAny(u8, user, "/\x00") != null or std.mem.eql(u8, user, "..") or std.mem.eql(u8, user, "."))
        return refuse(a, r, "cannot determine the allocation user.", .{});
    const path = try std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ node_local_root, user, job_id });
    const st = fsx.statAt(fsx.cwd, path, false) catch
        return refuse(a, r, "allocation node-local root must be an owned writable directory.", .{});
    if (!st.isDir()) return refuse(a, r, "allocation node-local root must be an owned writable directory.", .{});
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return refuse(a, r, "allocation node-local root must be an owned writable directory.", .{});
    if (linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0)) != .SUCCESS)
        return refuse(a, r, "allocation node-local root must be an owned writable directory.", .{});
    var buf: [sys.path_max]u8 = undefined;
    const real = fsx.realpath(fsx.cwd, path, &buf) catch return refuse(a, r, "cannot resolve allocation node-local root.", .{});
    if (!std.mem.eql(u8, real, path)) return refuse(a, r, "allocation node-local root must be canonical.", .{});
    if (st.uid != linux.getuid()) return refuse(a, r, "allocation node-local root belongs to another user.", .{});
    const m = (try mountOf(a, mountinfo, path)) orelse return refuse(a, r, "cannot inspect allocation mount.", .{});
    if (!std.mem.eql(u8, m.fstype, fstype))
        return refuse(a, r, "allocation node-local root must use {s}, not shared or memory-backed storage.", .{fstype});
    if (!std.mem.eql(u8, m.target, path)) return refuse(a, r, "allocation node-local root must be its own mount.", .{});
    var opts = std.mem.tokenizeScalar(u8, m.options, ',');
    while (opts.next()) |o| {
        if (std.mem.eql(u8, o, "rw")) return .{ .path = path };
    }
    return refuse(a, r, "allocation mount is not writable.", .{});
}

/// A workspace eb-local made: a real directory of the caller named
/// eb-local.XXXXXXXX directly in the job mount.
pub fn ownWorkspace(job_root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, job_root) or path.len != job_root.len + 1 + "eb-local.".len + 8) return false;
    const name = path[job_root.len + 1 ..];
    if (path[job_root.len] != '/' or !std.mem.startsWith(u8, name, "eb-local.")) return false;
    for (name["eb-local.".len..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    const st = fsx.statAt(fsx.cwd, path, false) catch return false;
    return st.isDir() and st.uid == linux.getuid();
}

/// A new eb-local.XXXXXXXX directory, mode 0700, in `job_root`.
pub fn makeWorkspace(a: Allocator, job_root: []const u8) (fsx.Error || Allocator.Error)![]const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        var raw: [8]u8 = undefined;
        if (linux.getrandom(&raw, raw.len, 0) != raw.len) return error.Unexpected;
        var name: [8]u8 = undefined;
        for (raw, 0..) |b, i| name[i] = alphabet[b % alphabet.len];
        const path = try std.fmt.allocPrint(a, "{s}/eb-local.{s}", .{ job_root, name });
        var zb: [sys.path_max:0]u8 = undefined;
        const rc = linux.mkdirat(linux.AT.FDCWD, (try sys.z(&zb, path)).ptr, 0o700);
        switch (linux.errno(rc)) {
            .SUCCESS => return path,
            .EXIST => continue,
            else => return error.AccessDenied,
        }
    }
    return error.Exists;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "the mount a path lies on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info =
        \\22 1 0:21 / / rw,relatime - xfs /dev/sda1 rw
        \\40 22 0:40 / /scratch-node rw,nosuid - xfs /dev/nvme0n1 rw
        \\41 40 0:41 / /scratch-node/u.123 rw,nosuid shared:5 - xfs /dev/nvme0n1 rw
        \\50 22 0:50 / /gpfs/home3 rw - gpfs home3 rw
        \\51 22 0:51 / /mnt/with\040space ro - tmpfs tmpfs ro
    ;
    const m = (try mountOf(a, info, "/scratch-node/u.123")).?;
    try testing.expectEqualStrings("/scratch-node/u.123", m.target);
    try testing.expectEqualStrings("xfs", m.fstype);
    try testing.expectEqualStrings("/scratch-node", (try mountOf(a, info, "/scratch-node/u.123x")).?.target);
    try testing.expectEqualStrings("/scratch-node", (try mountOf(a, info, "/scratch-node/u.1234")).?.target);
    try testing.expectEqualStrings("gpfs", (try mountOf(a, info, "/gpfs/home3/u/x")).?.fstype);
    try testing.expectEqualStrings("/mnt/with space", (try mountOf(a, info, "/mnt/with space/a")).?.target);
    try testing.expectEqualStrings("/", (try mountOf(a, info, "/etc")).?.target);
}

test "canonical paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/no/such/place", try canonical(a, "/no/such/./x/../place", "/"));
    try testing.expectEqualStrings("/tmp/a/b", try canonical(a, "a/b", "/tmp"));
    try testing.expect(under("/a/b", "/a"));
    try testing.expect(under("/a", "/a"));
    try testing.expect(!under("/ab", "/a"));
}
