const std = @import("std");

pub const Command = enum {
    add,
    list,
    help,

    const Meta = struct { args: []const u8, desc: []const u8 };

    fn meta(self: Command) Meta {
        return switch (self) {
            .add => .{ .args = "<url>", .desc = "Add a dependency to build.zig.zon (wraps `zig fetch --save`)" },
            .list => .{ .args = "", .desc = "List current dependencies (not yet implemented)" },
            .help => .{ .args = "", .desc = "Show this help text" },
        };
    }
};
