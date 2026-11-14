//! The part of TOML 1.0 that eb-local's configuration uses: tables
//! (`[a.b]`), dotted keys, basic and literal strings, integers, booleans and
//! arrays, which may span lines. Floats, dates, inline tables and arrays of
//! tables are refused by name rather than misread. A duplicate key, a table
//! defined twice, or a key used both as a value and as a table is an error
//! naming its line.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
    array: []const Value,
    table: *Table,

    pub fn kindName(v: Value) []const u8 {
        return switch (v) {
            .string => "a string",
            .int => "an integer",
            .boolean => "a boolean",
            .array => "an array",
            .table => "a table",
        };
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
    line: usize,
};

pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Defined by a `[header]` (not only implied by a dotted name).
    explicit: bool = false,
    line: usize = 0,

    pub fn get(t: *const Table, key: []const u8) ?*const Entry {
        for (t.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }

    fn getMut(t: *Table, key: []const u8) ?*Entry {
        for (t.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }
};

/// Where and why the text is not accepted.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{Invalid} || Allocator.Error;

const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    diag: *Diagnostic,

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.* = .{ .line = p.line, .message = try std.fmt.allocPrint(p.a, fmt, args) };
        return error.Invalid;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn skipSpace(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.pos += 1;
        }
    }

    fn skipComment(p: *Parser) void {
        if (p.peek() == '#') {
            while (p.peek()) |c| {
                if (c == '\n') break;
                p.pos += 1;
            }
        }
    }

    /// The rest of the line holds nothing but blanks and a comment.
    fn endOfLine(p: *Parser) Error!void {
        p.skipSpace();
        p.skipComment();
        if (p.peek()) |c| {
            if (c == '\r' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '\n') {
                p.pos += 2;
            } else if (c == '\n') {
                p.pos += 1;
            } else {
                return p.fail("unexpected '{c}' after the value", .{c});
            }
            p.line += 1;
        }
    }

    /// Blanks, comments and newlines, inside an array.
    fn skipWhitespaceAndNewlines(p: *Parser) void {
        while (p.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r' => p.pos += 1,
                '\n' => {
                    p.pos += 1;
                    p.line += 1;
                },
                '#' => p.skipComment(),
                else => return,
            }
        }
    }

    fn bareKeyChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    /// One part of a key: bare, or a basic or literal string.
    fn keyPart(p: *Parser) Error![]const u8 {
        p.skipSpace();
        const c = p.peek() orelse return p.fail("a key is missing", .{});
        if (c == '"') return p.basicString();
        if (c == '\'') return p.literalString();
        const start = p.pos;
        while (p.peek()) |d| {
            if (!bareKeyChar(d)) break;
            p.pos += 1;
        }
        if (p.pos == start) return p.fail("'{c}' cannot start a key", .{c});
        return p.src[start..p.pos];
    }

    /// A dotted key: one or more parts joined by '.'.
    fn key(p: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(p.a, try p.keyPart());
        while (true) {
            p.skipSpace();
            if (p.peek() != '.') break;
            p.pos += 1;
            try parts.append(p.a, try p.keyPart());
        }
        return parts.items;
    }

    fn basicString(p: *Parser) Error![]const u8 {
        p.pos += 1; // opening quote
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '"' and p.src[p.pos + 1] == '"')
            return p.fail("multi-line strings are not supported", .{});
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("a string is not closed", .{});
            p.pos += 1;
            switch (c) {
                '"' => return out.items,
                '\n' => return p.fail("a string is not closed on its line", .{}),
                '\\' => {
                    const e = p.peek() orelse return p.fail("a string is not closed", .{});
                    p.pos += 1;
                    switch (e) {
                        '"' => try out.append(p.a, '"'),
                        '\\' => try out.append(p.a, '\\'),
                        'n' => try out.append(p.a, '\n'),
                        't' => try out.append(p.a, '\t'),
                        'r' => try out.append(p.a, '\r'),
                        'b' => try out.append(p.a, 0x08),
                        'f' => try out.append(p.a, 0x0c),
                        'u', 'U' => {
                            const n: usize = if (e == 'u') 4 else 8;
                            if (p.pos + n > p.src.len) return p.fail("a \\{c} escape is cut short", .{e});
                            const cp = std.fmt.parseInt(u21, p.src[p.pos .. p.pos + n], 16) catch
                                return p.fail("a \\{c} escape is not hexadecimal", .{e});
                            p.pos += n;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(cp, &buf) catch
                                return p.fail("\\{c} names no Unicode scalar value", .{e});
                            try out.appendSlice(p.a, buf[0..len]);
                        },
                        else => return p.fail("'\\{c}' is not an escape TOML knows", .{e}),
                    }
                },
                else => {
                    if (c < 0x20 and c != '\t') return p.fail("a control character is in a string", .{});
                    try out.append(p.a, c);
                },
            }
        }
    }

    fn literalString(p: *Parser) Error![]const u8 {
        p.pos += 1;
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '\'' and p.src[p.pos + 1] == '\'')
            return p.fail("multi-line strings are not supported", .{});
        const start = p.pos;
        while (true) {
            const c = p.peek() orelse return p.fail("a string is not closed", .{});
            if (c == '\'') {
                p.pos += 1;
                return p.src[start .. p.pos - 1];
            }
            if (c == '\n') return p.fail("a string is not closed on its line", .{});
            if (c < 0x20 and c != '\t') return p.fail("a control character is in a string", .{});
            p.pos += 1;
        }
    }

    fn value(p: *Parser) Error!Value {
        p.skipSpace();
        const c = p.peek() orelse return p.fail("a value is missing", .{});
        switch (c) {
            '"' => return .{ .string = try p.basicString() },
            '\'' => return .{ .string = try p.literalString() },
            '[' => return p.array(),
            '{' => return p.fail("inline tables are not supported; use a [table]", .{}),
            else => {},
        }
        const start = p.pos;
        while (p.peek()) |d| {
            if (d == ' ' or d == '\t' or d == '\n' or d == '\r' or d == '#' or d == ',' or d == ']') break;
            p.pos += 1;
        }
        const word = p.src[start..p.pos];
        if (word.len == 0) return p.fail("a value is missing", .{});
        if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
        if (isInteger(word)) {
            return .{ .int = std.fmt.parseInt(i64, word, 10) catch return p.fail("{s} is out of range", .{word}) };
        }
        if (std.mem.indexOfAny(u8, word, ".eE") != null and std.mem.indexOfAny(u8, word, "0123456789") != null)
            return p.fail("{s}: floating-point values are not supported", .{word});
        if (std.mem.indexOfAny(u8, word, "-:") != null and word.len >= 8 and std.ascii.isDigit(word[0]))
            return p.fail("{s}: dates and times are not supported", .{word});
        return p.fail("{s} is not a value (strings are quoted)", .{word});
    }

    fn isInteger(word: []const u8) bool {
        var digits = word;
        if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) digits = digits[1..];
        if (digits.len == 0) return false;
        for (digits) |d| if (!std.ascii.isDigit(d)) return false;
        // No leading zeros, as TOML says.
        return !(digits.len > 1 and digits[0] == '0');
    }

    fn array(p: *Parser) Error!Value {
        p.pos += 1; // [
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipWhitespaceAndNewlines();
            if (p.peek() == ']') {
                p.pos += 1;
                return .{ .array = items.items };
            }
            try items.append(p.a, try p.value());
            p.skipWhitespaceAndNewlines();
            const c = p.peek() orelse return p.fail("an array is not closed", .{});
            if (c == ',') {
                p.pos += 1;
            } else if (c != ']') {
                return p.fail("'{c}' in an array: items are separated by commas", .{c});
            }
        }
    }

    /// The table a dotted path names below `root`, made when missing. A path
    /// through a value that is not a table is refused.
    fn descend(p: *Parser, root: *Table, path: []const []const u8) Error!*Table {
        var t = root;
        for (path) |part| {
            if (t.getMut(part)) |e| {
                switch (e.value) {
                    .table => |sub| t = sub,
                    else => return p.fail("'{s}' is already {s} (line {d}), not a table", .{ part, e.value.kindName(), e.line }),
                }
            } else {
                const sub = try p.a.create(Table);
                sub.* = .{ .line = p.line };
                try t.entries.append(p.a, .{ .key = part, .value = .{ .table = sub }, .line = p.line });
                t = sub;
            }
        }
        return t;
    }

    fn header(p: *Parser, root: *Table) Error!*Table {
        const line = p.line;
        p.pos += 1; // [
        if (p.peek() == '[') return p.fail("arrays of tables are not supported", .{});
        const path = try p.key();
        p.skipSpace();
        if (p.peek() != ']') return p.fail("a table header is not closed with ']'", .{});
        p.pos += 1;
        const parent = try p.descend(root, path[0 .. path.len - 1]);
        const last = path[path.len - 1];
        const t: *Table = blk: {
            if (parent.getMut(last)) |e| {
                switch (e.value) {
                    .table => |t| {
                        if (t.explicit) return p.fail("table [{s}] is defined twice (first on line {d})", .{ joined(p.a, path), t.line });
                        t.explicit = true;
                        t.line = line;
                        break :blk t;
                    },
                    else => return p.fail("'{s}' is already {s} (line {d}), not a table", .{ last, e.value.kindName(), e.line }),
                }
            }
            const t = try p.a.create(Table);
            t.* = .{ .explicit = true, .line = line };
            try parent.entries.append(p.a, .{ .key = last, .value = .{ .table = t }, .line = line });
            break :blk t;
        };
        // Bookkeeping first, so an error above names this line.
        try p.endOfLine();
        return t;
    }

    fn keyValue(p: *Parser, current: *Table) Error!void {
        const path = try p.key();
        p.skipSpace();
        if (p.peek() != '=') return p.fail("'=' is missing after the key", .{});
        p.pos += 1;
        const line = p.line;
        const v = try p.value();
        // An array may span lines; the key's own line names the tables its
        // dotted path implies and any error about the key.
        const after = p.line;
        p.line = line;
        const parent = try p.descend(current, path[0 .. path.len - 1]);
        const last = path[path.len - 1];
        if (parent.get(last)) |e|
            return p.fail("'{s}' is set twice (first on line {d})", .{ joined(p.a, path), e.line });
        try parent.entries.append(p.a, .{ .key = last, .value = v, .line = line });
        p.line = after;
        try p.endOfLine();
    }
};

fn joined(a: Allocator, parts: []const []const u8) []const u8 {
    return std.mem.join(a, ".", parts) catch "?";
}

/// Parse `src`. Everything is allocated with `a` (an arena is expected).
pub fn parse(a: Allocator, src: []const u8, diag: *Diagnostic) Error!*Table {
    const root = try a.create(Table);
    root.* = .{ .explicit = true };
    var p: Parser = .{ .a = a, .src = src, .diag = diag };
    if (std.mem.indexOfScalar(u8, src, 0) != null) return p.fail("the file holds a NUL byte", .{});
    if (!std.unicode.utf8ValidateSlice(src)) return p.fail("the file is not UTF-8", .{});
    var current = root;
    while (p.pos < src.len) {
        p.skipSpace();
        const c = p.peek() orelse break;
        switch (c) {
            '\n' => {
                p.pos += 1;
                p.line += 1;
            },
            '\r', '#' => try p.endOfLine(),
            '[' => current = try p.header(root),
            else => try p.keyValue(current),
        }
    }
    return root;
}

// ---- tests ----------------------------------------------------------------

fn parseOk(a: Allocator, src: []const u8) !*Table {
    var d: Diagnostic = .{};
    return parse(a, src, &d) catch |e| {
        std.debug.print("unexpected error on line {d}: {s}\n", .{ d.line, d.message });
        return e;
    };
}

fn expectInvalid(src: []const u8, line: usize, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), src, &d));
    std.testing.expectEqual(line, d.line) catch |e| {
        std.debug.print("message: {s}\n", .{d.message});
        return e;
    };
    if (std.mem.indexOf(u8, d.message, needle) == null) {
        std.debug.print("message '{s}' lacks '{s}'\n", .{ d.message, needle });
        return error.TestUnexpectedResult;
    }
}

test "tables, dotted keys, strings, integers, booleans and arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parseOk(arena.allocator(),
        \\# site
        \\default_profile = "mine"   # comment
        \\[storage]
        \\node_local_root = "/scratch-node"
        \\shared_scratch = [
        \\  "/scratch-shared", # one
        \\  '/gpfs/scratch1',
        \\]
        \\[profile.gpu]
        \\dev.modules = ["CUDA/13.3.0"]
        \\clean.logs_older_than_days = 7
        \\keep = true
        \\"quoted key" = "tab\there é"
    );
    try std.testing.expectEqualStrings("mine", t.get("default_profile").?.value.string);
    const storage = t.get("storage").?.value.table;
    try std.testing.expectEqualStrings("/scratch-node", storage.get("node_local_root").?.value.string);
    const scratch = storage.get("shared_scratch").?.value.array;
    try std.testing.expectEqual(@as(usize, 2), scratch.len);
    try std.testing.expectEqualStrings("/gpfs/scratch1", scratch[1].string);
    const gpu = t.get("profile").?.value.table.get("gpu").?.value.table;
    try std.testing.expectEqualStrings("CUDA/13.3.0", gpu.get("dev").?.value.table.get("modules").?.value.array[0].string);
    try std.testing.expectEqual(@as(i64, 7), gpu.get("clean").?.value.table.get("logs_older_than_days").?.value.int);
    try std.testing.expect(gpu.get("keep").?.value.boolean);
    try std.testing.expectEqualStrings("tab\there \u{e9}", gpu.get("quoted key").?.value.string);
    try std.testing.expectEqual(@as(usize, 10), gpu.get("dev").?.line);
}

test "every refusal names its line" {
    try expectInvalid("a = 1\na = 2\n", 2, "set twice (first on line 1)");
    try expectInvalid("[a]\nx = 1\n[a]\n", 3, "defined twice");
    try expectInvalid("a = 1\n[a]\n", 2, "already an integer");
    try expectInvalid("a.b = 1\na.b.c = 2\n", 2, "not a table");
    try expectInvalid("x = 1.5\n", 1, "floating-point");
    try expectInvalid("x = 2026-11-14\n", 1, "dates");
    try expectInvalid("x = { a = 1 }\n", 1, "inline tables");
    try expectInvalid("[[x]]\n", 1, "arrays of tables");
    try expectInvalid("x = bare\n", 1, "strings are quoted");
    try expectInvalid("x = \"open\n", 1, "not closed");
    try expectInvalid("x = \"a\\q\"\n", 1, "escape");
    try expectInvalid("x = 1 2\n", 1, "after the value");
    try expectInvalid("ok = 1\nx = [1 2]\n", 2, "commas");
    try expectInvalid("x = 012\n", 1, "not a value");
    try expectInvalid("x = 99999999999999999999\n", 1, "out of range");
    try expectInvalid("= 1\n", 1, "cannot start a key");
    try expectInvalid("x = \"\"\"a\"\"\"\n", 1, "multi-line");
    try expectInvalid("x = \"a\x01\"\n", 1, "control character");
    try expectInvalid("x = 1\x00\n", 1, "NUL");
}

test "an empty file and a file of comments are empty tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try parseOk(arena.allocator(), "")).entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try parseOk(arena.allocator(), "# x\n\n  # y\r\n")).entries.items.len);
}
