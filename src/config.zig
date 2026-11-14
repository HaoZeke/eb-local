//! eb-local's settings, layered lowest first: built-in defaults, the site
//! file, a site profile, the user file, a user profile, EB_LOCAL_* variables,
//! command-line options. Every value keeps where it came from. The storage
//! settings come only from the site layer: a user cannot point builds at a
//! shared file system. Secrets are named sources, never values.
const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;

pub const Trash = enum { auto, rtrash, none };

pub fn Setting(comptime T: type) type {
    return struct {
        value: T,
        from: []const u8 = "default",
    };
}

pub const Secret = struct {
    /// The variable eb receives.
    name: []const u8,
    /// env:VAR, file:PATH or nimvault:ENTRY.
    source: []const u8,
    from: []const u8,
};

pub const Settings = struct {
    profile: ?[]const u8 = null,
    prefix: Setting([]const u8) = .{ .value = "~/.local/eessi" },
    project: Setting(?[]const u8) = .{ .value = null },
    stack_module: Setting([]const u8) = .{ .value = "EESSI/2026.06" },
    extend_module: Setting([]const u8) = .{ .value = "EESSI-extend/2026.06-easybuild" },
    dev_buildenv: Setting([]const u8) = .{ .value = "buildenv/default-foss-2026.1" },
    dev_modules: Setting([]const []const u8) = .{ .value = &.{} },
    allocation_hint: Setting([]const u8) = .{ .value = "" },
    trash: Setting(Trash) = .{ .value = .auto },
    logs_older_than_days: Setting(u32) = .{ .value = 30 },
    node_local_root: Setting([]const u8) = .{ .value = "" },
    node_local_fstype: Setting([]const u8) = .{ .value = "xfs" },
    shared_scratch: Setting([]const []const u8) = .{ .value = &.{} },
    secrets: std.ArrayList(Secret) = .empty,
};

pub const Layer = enum { site, user };

/// One configuration file, already read and trusted.
pub const Source = struct {
    path: []const u8,
    text: []const u8,
    layer: Layer,
};

pub const Overrides = struct {
    profile: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    project: ?[]const u8 = null,
    buildenv: ?[]const u8 = null,
};

pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = error{Invalid} || Allocator.Error;

/// Module names as Lmod writes them. Anything else could change the meaning
/// of the lines env and dev print for eval.
pub fn validModule(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return false;
    var prev_slash = false;
    for (name) |c| {
        if (c == '/') {
            if (prev_slash) return false;
            prev_slash = true;
            continue;
        }
        prev_slash = false;
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '+' or c == '-')) return false;
    }
    if (prev_slash) return false;
    // ".." as a path part.
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

/// A variable name a secret may set: a shell name that is not one the build
/// depends on for its paths or loader.
pub fn validSecretName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    const refused = [_][]const u8{ "PATH", "HOME", "USER", "SHELL", "TMPDIR", "MODULEPATH", "PYTHONPATH", "BASH_ENV", "ENV" };
    for (refused) |r| if (std.mem.eql(u8, name, r)) return false;
    const refused_prefixes = [_][]const u8{ "LD_", "EESSI_", "EASYBUILD_", "LMOD_", "SLURM_", "EB_LOCAL_", "BASH_FUNC_" };
    for (refused_prefixes) |r| if (std.mem.startsWith(u8, name, r)) return false;
    return true;
}

pub fn validSecretSource(source: []const u8) bool {
    inline for (.{ "env:", "file:", "nimvault:" }) |kind| {
        if (std.mem.startsWith(u8, source, kind)) {
            const rest = source[kind.len..];
            if (rest.len == 0 or std.mem.indexOfAny(u8, rest, "\n\r\x00") != null) return false;
            if (comptime std.mem.eql(u8, kind, "env:")) return validEnvName(rest);
            if (comptime std.mem.eql(u8, kind, "file:")) return rest[0] == '/' or std.mem.startsWith(u8, rest, "~/");
            return true;
        }
    }
    return false;
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn validAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/') return false;
    return std.mem.indexOfAny(u8, path, " \t\n\r\x00") == null;
}

const Loader = struct {
    a: Allocator,
    s: *Settings,
    diag: *Diagnostic,

    fn fail(l: *Loader, comptime fmt: []const u8, args: anytype) Error {
        l.diag.message = try std.fmt.allocPrint(l.a, fmt, args);
        return error.Invalid;
    }

    fn where(l: *Loader, src: Source, line: usize, profile: ?[]const u8) Error![]const u8 {
        const layer = @tagName(src.layer);
        return if (profile) |p|
            std.fmt.allocPrint(l.a, "{s} profile {s}, {s}:{d}", .{ layer, p, src.path, line })
        else
            std.fmt.allocPrint(l.a, "{s} {s}:{d}", .{ layer, src.path, line });
    }

    fn string(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error![]const u8 {
        return switch (e.value) {
            .string => |v| v,
            else => l.fail("{s}:{d}: {s} must be a string, not {s}", .{ src.path, e.line, name, e.value.kindName() }),
        };
    }

    fn module(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error![]const u8 {
        const v = try l.string(src, e, name);
        if (!validModule(v)) return l.fail("{s}:{d}: {s} '{s}' is not a module name", .{ src.path, e.line, name, v });
        return v;
    }

    fn stringList(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error![]const []const u8 {
        const items = switch (e.value) {
            .array => |v| v,
            else => return l.fail("{s}:{d}: {s} must be an array of strings", .{ src.path, e.line, name }),
        };
        var out: std.ArrayList([]const u8) = .empty;
        for (items) |item| switch (item) {
            .string => |v| try out.append(l.a, v),
            else => return l.fail("{s}:{d}: {s} must be an array of strings", .{ src.path, e.line, name }),
        };
        return out.items;
    }

    fn table(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error!*toml.Table {
        return switch (e.value) {
            .table => |t| t,
            else => l.fail("{s}:{d}: {s} must be a table", .{ src.path, e.line, name }),
        };
    }

    /// The keys a profile and a file's top level share.
    fn apply(l: *Loader, src: Source, t: *const toml.Table, profile: ?[]const u8) Error!void {
        for (t.entries.items) |*e| {
            const k = e.key;
            const from = try l.where(src, e.line, profile);
            if (std.mem.eql(u8, k, "prefix")) {
                l.s.prefix = .{ .value = try l.string(src, e, "prefix"), .from = from };
            } else if (std.mem.eql(u8, k, "project")) {
                l.s.project = .{ .value = try l.string(src, e, "project"), .from = from };
            } else if (std.mem.eql(u8, k, "stack")) {
                const sub = try l.table(src, e, "stack");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "module")) {
                        l.s.stack_module = .{ .value = try l.module(src, f, "stack.module"), .from = ff };
                    } else if (std.mem.eql(u8, f.key, "extend")) {
                        l.s.extend_module = .{ .value = try l.module(src, f, "stack.extend"), .from = ff };
                    } else return l.fail("{s}:{d}: unknown key stack.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "dev")) {
                const sub = try l.table(src, e, "dev");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "buildenv")) {
                        l.s.dev_buildenv = .{ .value = try l.module(src, f, "dev.buildenv"), .from = ff };
                    } else if (std.mem.eql(u8, f.key, "modules")) {
                        const mods = try l.stringList(src, f, "dev.modules");
                        for (mods) |m| if (!validModule(m)) return l.fail("{s}:{d}: dev.modules: '{s}' is not a module name", .{ src.path, f.line, m });
                        l.s.dev_modules = .{ .value = mods, .from = ff };
                    } else return l.fail("{s}:{d}: unknown key dev.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "build")) {
                const sub = try l.table(src, e, "build");
                for (sub.entries.items) |*f| {
                    if (std.mem.eql(u8, f.key, "allocation_hint")) {
                        l.s.allocation_hint = .{ .value = try l.string(src, f, "build.allocation_hint"), .from = try l.where(src, f.line, profile) };
                    } else return l.fail("{s}:{d}: unknown key build.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "clean")) {
                const sub = try l.table(src, e, "clean");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "trash")) {
                        const v = try l.string(src, f, "clean.trash");
                        const t2 = std.meta.stringToEnum(Trash, v) orelse return l.fail("{s}:{d}: clean.trash is auto, rtrash or none", .{ src.path, f.line });
                        l.s.trash = .{ .value = t2, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "logs_older_than_days")) {
                        const v = switch (f.value) {
                            .int => |n| n,
                            else => return l.fail("{s}:{d}: clean.logs_older_than_days must be an integer", .{ src.path, f.line }),
                        };
                        if (v < 0 or v > 99999) return l.fail("{s}:{d}: clean.logs_older_than_days is out of range", .{ src.path, f.line });
                        l.s.logs_older_than_days = .{ .value = @intCast(v), .from = ff };
                    } else return l.fail("{s}:{d}: unknown key clean.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "secrets")) {
                const sub = try l.table(src, e, "secrets");
                for (sub.entries.items) |*f| {
                    if (!validSecretName(f.key)) return l.fail("{s}:{d}: secret {s}: not a variable name a secret may set", .{ src.path, f.line, f.key });
                    const v = try l.string(src, f, "a secret");
                    if (!validSecretSource(v))
                        return l.fail("{s}:{d}: secret {s}: a source is env:VAR, file:PATH or nimvault:ENTRY; a value is never written in a configuration file", .{ src.path, f.line, f.key });
                    const ff = try l.where(src, f.line, profile);
                    // A later layer replaces a secret of the same name.
                    for (l.s.secrets.items, 0..) |old, i| if (std.mem.eql(u8, old.name, f.key)) {
                        _ = l.s.secrets.orderedRemove(i);
                        break;
                    };
                    try l.s.secrets.append(l.a, .{ .name = f.key, .source = v, .from = ff });
                }
            } else if (std.mem.eql(u8, k, "storage")) {
                if (src.layer != .site or profile != null)
                    return l.fail("{s}:{d}: [storage] is a site setting; a user file or a profile cannot change it", .{ src.path, e.line });
                const sub = try l.table(src, e, "storage");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, null);
                    if (std.mem.eql(u8, f.key, "node_local_root")) {
                        const v = try l.string(src, f, "storage.node_local_root");
                        if (!validAbsolute(v)) return l.fail("{s}:{d}: storage.node_local_root must be one absolute path without a trailing slash", .{ src.path, f.line });
                        l.s.node_local_root = .{ .value = v, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "node_local_fstype")) {
                        const v = try l.string(src, f, "storage.node_local_fstype");
                        for (v) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '.'))
                            return l.fail("{s}:{d}: storage.node_local_fstype must be a file system type name", .{ src.path, f.line });
                        if (v.len == 0) return l.fail("{s}:{d}: storage.node_local_fstype is empty", .{ src.path, f.line });
                        l.s.node_local_fstype = .{ .value = v, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "shared_scratch")) {
                        const v = try l.stringList(src, f, "storage.shared_scratch");
                        for (v) |p| if (!validAbsolute(p)) return l.fail("{s}:{d}: storage.shared_scratch takes absolute paths without a trailing slash", .{ src.path, f.line });
                        l.s.shared_scratch = .{ .value = v, .from = ff };
                    } else return l.fail("{s}:{d}: unknown key storage.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "default_profile") or std.mem.eql(u8, k, "profile")) {
                if (profile != null) return l.fail("{s}:{d}: {s} cannot be set inside a profile", .{ src.path, e.line, k });
            } else return l.fail("{s}:{d}: unknown key {s}", .{ src.path, e.line, k });
        }
    }
};

fn profileTable(t: *const toml.Table, name: []const u8) ?*const toml.Table {
    const profiles = t.get("profile") orelse return null;
    const pt = switch (profiles.value) {
        .table => |x| x,
        else => return null,
    };
    const e = pt.get(name) orelse return null;
    return switch (e.value) {
        .table => |x| x,
        else => null,
    };
}

/// Profile names a file defines.
pub fn profileNames(a: Allocator, t: *const toml.Table) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const profiles = t.get("profile") orelse return out.items;
    switch (profiles.value) {
        .table => |pt| for (pt.entries.items) |e| try out.append(a, e.key),
        else => {},
    }
    return out.items;
}

fn defaultProfile(l: *Loader, src: Source, t: *const toml.Table) Error!?[]const u8 {
    const e = t.get("default_profile") orelse return null;
    return try l.string(src, e, "default_profile");
}

/// The configuration in `sources` (site first, then user), with `env` and
/// `cli` on top.
pub fn load(
    a: Allocator,
    sources: []const Source,
    env: *const std.process.Environ.Map,
    cli: Overrides,
    diag: *Diagnostic,
) Error!Settings {
    var s: Settings = .{};
    var l: Loader = .{ .a = a, .s = &s, .diag = diag };
    var tables: std.ArrayList(*toml.Table) = .empty;
    for (sources) |src| {
        var td: toml.Diagnostic = .{};
        const t = toml.parse(a, src.text, &td) catch |e| switch (e) {
            error.Invalid => return l.fail("{s}:{d}: {s}", .{ src.path, td.line, td.message }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try tables.append(a, t);
    }

    // The profile: an option, then EB_LOCAL_PROFILE, then the last default_profile.
    var profile: ?[]const u8 = cli.profile orelse env.get("EB_LOCAL_PROFILE");
    if (profile == null) for (sources, tables.items) |src, t| {
        if (try defaultProfile(&l, src, t)) |p| profile = p;
    };
    if (profile) |p| {
        if (p.len == 0) profile = null;
    }

    // Every profile is checked, selected or not, so a mistake in one shows
    // the first time the file is read rather than the first time it is used.
    for (sources, tables.items) |src, t| {
        if (t.get("profile")) |pe| {
            const pt = try l.table(src, pe, "profile");
            for (pt.entries.items) |*e| {
                const body = try l.table(src, e, "a profile");
                var scratch: Settings = .{};
                var check: Loader = .{ .a = a, .s = &scratch, .diag = diag };
                try check.apply(src, body, e.key);
            }
        }
    }

    var found = profile == null;
    for (sources, tables.items) |src, t| {
        try l.apply(src, t, null);
        if (profile) |p| if (profileTable(t, p)) |pt| {
            found = true;
            try l.apply(src, pt, p);
        };
    }
    if (!found) {
        var names: std.ArrayList([]const u8) = .empty;
        for (tables.items) |t| try names.appendSlice(a, try profileNames(a, t));
        return l.fail("no profile '{s}' (defined: {s})", .{ profile.?, if (names.items.len == 0) "none" else try std.mem.join(a, ", ", names.items) });
    }
    s.profile = profile;

    // Every scalar key has an EB_LOCAL_* form; storage has none.
    if (env.get("EB_LOCAL_PREFIX")) |v| if (v.len > 0) {
        s.prefix = .{ .value = v, .from = "environment EB_LOCAL_PREFIX" };
    };
    if (env.get("EB_LOCAL_PROJECT")) |v| if (v.len > 0) {
        s.project = .{ .value = v, .from = "environment EB_LOCAL_PROJECT" };
    };
    inline for (.{
        .{ "EB_LOCAL_STACK_MODULE", "stack_module" },
        .{ "EB_LOCAL_STACK_EXTEND", "extend_module" },
        .{ "EB_LOCAL_DEV_BUILDENV", "dev_buildenv" },
    }) |pair| {
        if (env.get(pair[0])) |v| if (v.len > 0) {
            if (!validModule(v)) return l.fail("{s}: '{s}' is not a module name", .{ pair[0], v });
            @field(s, pair[1]) = .{ .value = v, .from = "environment " ++ pair[0] };
        };
    }
    if (env.get("EB_LOCAL_DEV_MODULES")) |v| if (v.len > 0) {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, v, " \t");
        while (it.next()) |m| {
            if (!validModule(m)) return l.fail("EB_LOCAL_DEV_MODULES: '{s}' is not a module name", .{m});
            try out.append(a, m);
        }
        s.dev_modules = .{ .value = out.items, .from = "environment EB_LOCAL_DEV_MODULES" };
    };
    if (env.get("EB_LOCAL_BUILD_ALLOCATION_HINT")) |v| if (v.len > 0) {
        s.allocation_hint = .{ .value = v, .from = "environment EB_LOCAL_BUILD_ALLOCATION_HINT" };
    };
    // EB_LOCAL_TRASH is the 1.x name.
    inline for (.{ "EB_LOCAL_TRASH", "EB_LOCAL_CLEAN_TRASH" }) |name| {
        if (env.get(name)) |v| if (v.len > 0) {
            const t = std.meta.stringToEnum(Trash, v) orelse return l.fail("{s} is auto, rtrash or none", .{name});
            s.trash = .{ .value = t, .from = "environment " ++ name };
        };
    }
    if (env.get("EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS")) |v| if (v.len > 0) {
        const n = std.fmt.parseInt(u32, v, 10) catch return l.fail("EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS must be a number of days", .{});
        if (n > 99999) return l.fail("EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS is out of range", .{});
        s.logs_older_than_days = .{ .value = n, .from = "environment EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS" };
    };

    if (cli.prefix) |v| s.prefix = .{ .value = v, .from = "option" };
    if (cli.project) |v| s.project = .{ .value = v, .from = "option --project" };
    if (cli.buildenv) |v| {
        if (!validModule(v)) return l.fail("--buildenv: '{s}' is not a module name", .{v});
        s.dev_buildenv = .{ .value = v, .from = "option --buildenv" };
    }
    return s;
}

/// The 1.x site file: `key = value` lines, parsed, never sourced. Kept so a
/// site's existing eb-local.conf keeps working.
pub fn legacyToToml(a: Allocator, text: []const u8, diag: *Diagnostic) Error![]const u8 {
    const tables = [_][]const u8{ "storage", "stack", "build", "dev", "clean" };
    var bufs: [tables.len]std.ArrayList(u8) = @splat(.empty);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            diag.message = try std.fmt.allocPrint(a, "line {d}: cannot read the line '{s}'", .{ n, line });
            return error.Invalid;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // (table index, TOML key) for each 1.x setting.
        const Map = struct { k: []const u8, t: usize, name: []const u8, list: bool = false };
        const map = [_]Map{
            .{ .k = "node_local_root", .t = 0, .name = "node_local_root" },
            .{ .k = "node_local_fstype", .t = 0, .name = "node_local_fstype" },
            .{ .k = "shared_scratch", .t = 0, .name = "shared_scratch", .list = true },
            .{ .k = "stack_module", .t = 1, .name = "module" },
            .{ .k = "extend_module", .t = 1, .name = "extend" },
            .{ .k = "allocation_hint", .t = 2, .name = "allocation_hint" },
            .{ .k = "dev_buildenv", .t = 3, .name = "buildenv" },
            .{ .k = "trash", .t = 4, .name = "trash" },
        };
        const m = for (map) |m| {
            if (std.mem.eql(u8, m.k, key)) break m;
        } else {
            diag.message = try std.fmt.allocPrint(a, "line {d}: unknown setting '{s}'", .{ n, key });
            return error.Invalid;
        };
        const buf = &bufs[m.t];
        try buf.appendSlice(a, m.name);
        try buf.appendSlice(a, " = ");
        if (m.list) {
            try buf.append(a, '[');
            var it = std.mem.tokenizeAny(u8, value, " \t");
            var first = true;
            while (it.next()) |p| {
                if (!first) try buf.appendSlice(a, ", ");
                first = false;
                try appendQuoted(a, buf, p);
            }
            try buf.append(a, ']');
        } else {
            try appendQuoted(a, buf, value);
        }
        try buf.append(a, '\n');
    }
    var out: std.ArrayList(u8) = .empty;
    for (tables, &bufs) |name, *buf| if (buf.items.len > 0) {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "[{s}]\n", .{name}));
        try out.appendSlice(a, buf.items);
    };
    return out.items;
}

fn appendQuoted(a: Allocator, buf: *std.ArrayList(u8), v: []const u8) Allocator.Error!void {
    try buf.append(a, '"');
    for (v) |c| {
        if (c == '"' or c == '\\') try buf.append(a, '\\');
        try buf.append(a, c);
    }
    try buf.append(a, '"');
}

// ---- tests ----------------------------------------------------------------

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,

    fn init() Fixture {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .env = std.process.Environ.Map.init(std.testing.allocator) };
    }
    fn deinit(t: *Fixture) void {
        t.env.deinit();
        t.arena.deinit();
    }
    fn load(t: *Fixture, sources: []const Source, cli: Overrides) !Settings {
        var d: Diagnostic = .{};
        return config_load(t.arena.allocator(), sources, &t.env, cli, &d) catch |e| {
            std.debug.print("{s}\n", .{d.message});
            return e;
        };
    }
    fn refuse(t: *Fixture, sources: []const Source, needle: []const u8) !void {
        var d: Diagnostic = .{};
        try std.testing.expectError(error.Invalid, config_load(t.arena.allocator(), sources, &t.env, .{}, &d));
        if (std.mem.indexOf(u8, d.message, needle) == null) {
            std.debug.print("message '{s}' lacks '{s}'\n", .{ d.message, needle });
            return error.TestUnexpectedResult;
        }
    }
};
const config_load = load;

const site_text =
    \\[storage]
    \\node_local_root = "/scratch-node"
    \\shared_scratch = ["/scratch-shared", "/gpfs/scratch1"]
    \\[stack]
    \\module = "EESSI/2026.06"
    \\[profile.gpu]
    \\dev.modules = ["CUDA/13.3.0"]
    \\build.allocation_hint = "salloc -p gpu_h100"
;
const user_text =
    \\default_profile = "mine"
    \\[profile.mine]
    \\prefix = "/home/u/eessi"
    \\dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]
    \\[profile.group]
    \\project = "/projects/p/eessi"
    \\[profile.group.secrets]
    \\LM_LICENSE_FILE = "nimvault:licences/flexlm"
    \\[secrets]
    \\SOURCE_TOKEN = "env:MY_TOKEN"
;

test "layers, profiles and where each value came from" {
    var t = Fixture.init();
    defer t.deinit();
    const sources = [_]Source{
        .{ .path = "/etc/eb-local/config.toml", .text = site_text, .layer = .site },
        .{ .path = "/home/u/.config/eb-local/config.toml", .text = user_text, .layer = .user },
    };
    const s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("mine", s.profile.?);
    try std.testing.expectEqualStrings("/home/u/eessi", s.prefix.value);
    try std.testing.expectEqualStrings("user profile mine, /home/u/.config/eb-local/config.toml:3", s.prefix.from);
    try std.testing.expectEqualStrings("FFTW/3.3.10-GCC-15.2.0", s.dev_modules.value[0]);
    try std.testing.expectEqualStrings("/scratch-node", s.node_local_root.value);
    try std.testing.expectEqual(@as(usize, 1), s.secrets.items.len);
    try std.testing.expectEqualStrings("SOURCE_TOKEN", s.secrets.items[0].name);

    const g = try t.load(&sources, .{ .profile = "group" });
    try std.testing.expectEqualStrings("/projects/p/eessi", g.project.value.?);
    try std.testing.expectEqual(@as(usize, 2), g.secrets.items.len);

    const gpu = try t.load(&sources, .{ .profile = "gpu" });
    try std.testing.expectEqualStrings("CUDA/13.3.0", gpu.dev_modules.value[0]);
    try std.testing.expectEqualStrings("salloc -p gpu_h100", gpu.allocation_hint.value);
}

test "the environment overrides files and options override the environment" {
    var t = Fixture.init();
    defer t.deinit();
    const sources = [_]Source{.{ .path = "u.toml", .text = user_text, .layer = .user }};
    try t.env.put("EB_LOCAL_PREFIX", "/env/prefix");
    try t.env.put("EB_LOCAL_DEV_MODULES", "GSL/2.8-GCC-15.2.0 CMake/3.31.11-GCCcore-15.2.0");
    try t.env.put("EB_LOCAL_TRASH", "none");
    var s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("/env/prefix", s.prefix.value);
    try std.testing.expectEqualStrings("environment EB_LOCAL_PREFIX", s.prefix.from);
    try std.testing.expectEqual(@as(usize, 2), s.dev_modules.value.len);
    try std.testing.expectEqual(Trash.none, s.trash.value);
    s = try t.load(&sources, .{ .prefix = "/opt/prefix", .buildenv = "buildenv/mine" });
    try std.testing.expectEqualStrings("/opt/prefix", s.prefix.value);
    try std.testing.expectEqualStrings("buildenv/mine", s.dev_buildenv.value);
    try t.env.put("EB_LOCAL_PROFILE", "group");
    s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("group", s.profile.?);
}

test "refusals" {
    var t = Fixture.init();
    defer t.deinit();
    const r = struct {
        fn one(tt: *Fixture, text: []const u8, layer: Layer, needle: []const u8) !void {
            try tt.refuse(&.{.{ .path = "c.toml", .text = text, .layer = layer }}, needle);
        }
    };
    try r.one(&t, "[storage]\nnode_local_root = \"/x\"\n", .user, "site setting");
    try r.one(&t, "[profile.p.storage]\nnode_local_root = \"/x\"\n", .site, "site setting");
    try r.one(&t, "[profile.unused]\ncolour = 1\n", .user, "unknown key colour");
    try r.one(&t, "[secrets]\nTOKEN = \"hunter2\"\n", .user, "never written");
    try r.one(&t, "[secrets]\nLD_PRELOAD = \"env:X\"\n", .user, "not a variable name");
    try r.one(&t, "[secrets]\nPATH = \"env:X\"\n", .user, "not a variable name");
    try r.one(&t, "[secrets]\nT = \"file:relative\"\n", .user, "never written");
    try r.one(&t, "[stack]\nmodule = \"EESSI;rm -rf ~\"\n", .user, "not a module name");
    try r.one(&t, "[dev]\nmodules = [\"$(id)\"]\n", .user, "not a module name");
    try r.one(&t, "[dev]\nmodules = \"GSL\"\n", .user, "array of strings");
    try r.one(&t, "[clean]\ntrash = \"bin\"\n", .user, "auto, rtrash or none");
    try r.one(&t, "[clean]\nlogs_older_than_days = -1\n", .user, "out of range");
    try r.one(&t, "colour = \"blue\"\n", .user, "unknown key colour");
    try r.one(&t, "[stack]\nmodule = 1\n", .user, "must be a string");
    try r.one(&t, "default_profile = \"nope\"\n", .user, "no profile 'nope'");
    try r.one(&t, "[storage]\nnode_local_root = \"relative\"\n", .site, "absolute");
    try r.one(&t, "x = 1\nx = 2\n", .user, "c.toml:2");
    t.env.put("EB_LOCAL_STACK_MODULE", "a b") catch unreachable;
    try r.one(&t, "", .user, "EB_LOCAL_STACK_MODULE");
}

test "module names" {
    for ([_][]const u8{ "EESSI/2026.06", "buildenv/default-foss-2026.1", "R/4.6.1-gfbf-2026.1", "Python-bundle-PyPI/2025.04-GCCcore-14.2.0", "g++/1" }) |ok|
        try std.testing.expect(validModule(ok));
    for ([_][]const u8{ "", "/x", "x/", "a//b", "../x", "a/../b", "-x", "a b", "a;b", "$(id)", "a`b`", "a\nb" }) |bad|
        try std.testing.expect(!validModule(bad));
}

test "the 1.x site file" {
    var t = Fixture.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var d: Diagnostic = .{};
    const text = try legacyToToml(a,
        \\# site
        \\node_local_root = /scratch-node
        \\node_local_fstype = xfs
        \\shared_scratch = /scratch-shared /gpfs/scratch1
        \\allocation_hint = salloc -p rome -n 16 -t 02:00:00
        \\stack_module = 2026
        \\extend_module = EESSI-extend/2026.06-easybuild
        \\trash = none
    , &d);
    const s = try t.load(&.{.{ .path = "eb-local.conf", .text = text, .layer = .site }}, .{});
    try std.testing.expectEqualStrings("/scratch-node", s.node_local_root.value);
    try std.testing.expectEqual(@as(usize, 2), s.shared_scratch.value.len);
    try std.testing.expectEqualStrings("salloc -p rome -n 16 -t 02:00:00", s.allocation_hint.value);
    try std.testing.expectEqual(Trash.none, s.trash.value);
    try std.testing.expectEqualStrings("2026", s.stack_module.value);
    try std.testing.expectError(error.Invalid, legacyToToml(a, "source_me = $(touch x)\n", &d));
}
