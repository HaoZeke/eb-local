//! eb-local: install and build software on top of EESSI into a directory you
//! own, with the configuration in TOML.
const std = @import("std");
const build_options = @import("build_options");
const common = @import("zig_common");
const cli = common.cli;
pub const toml = @import("toml.zig");
pub const config = @import("config.zig");
pub const secrets = @import("secrets.zig");
pub const storage = @import("storage.zig");

const tool = "eb-local";
pub const version = "2.0.0";

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch cli.die(tool, "cannot read the arguments", .{});
    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        cli.put(1, comptime cli.versionLine(tool, version, build_options.commit));
        return 0;
    }
    return 0;
}

test {
    _ = toml;
    _ = config;
    _ = secrets;
    _ = storage;
}
