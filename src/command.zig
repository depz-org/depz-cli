const std = @import("std");

pub const Command = enum {
    add,
    list,
    help,

    const Meta = struct { args: []const u8, desc: []const u8 };

    fn meta(self: Command) Meta {
        return switch (self) {
            .add => .{ .args = "<owner>/<repo>[@<tag>] [--registry=<host>]", .desc = "Add a dependency to build.zig.zon (wraps `zig fetch --save`)" },
            .list => .{ .args = "[--check] [--all] [--target=<latest|minor|patch>]", .desc = "List dependencies, or check for updates with --check" },
            .help => .{ .args = "", .desc = "Show this help text" },
        };
    }
};

pub const usage = blk: {
    var cmds: []const u8 = "";
    const fieldNames = std.meta.fieldNames(Command);
    for (fieldNames) |fieldName| {
        const m = (@field(Command, fieldName)).meta();
        const left: []const u8 = if (m.args.len <= 0) fieldName else std.fmt.comptimePrint("{s} {s}", .{ fieldName, m.args });
        cmds = cmds ++ std.fmt.comptimePrint(" {s:<14}{s}\n", .{ left, m.desc });
    }
    break :blk std.fmt.comptimePrint(
        \\depz — ergonomic dependency management for Zig
        \\
        \\Usage:
        \\  depz <command> [args]
        \\
        \\Commands:
        \\{s}
        \\Examples:
        \\  depz add depz-org/example@v1.0.0
        \\  depz add depz-org/example
        \\  depz add foreverzer0/klack@v1.1.0 --registry=codeberg.org
        \\  depz list --check
        \\
    , .{cmds});
};

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}
