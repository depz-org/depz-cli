const std = @import("std");

pub const Command = enum {
    add,
    list,
    check,
    version,
    help,

    const Meta = struct { args: []const u8, desc: []const u8 };

    fn meta(self: Command) Meta {
        return switch (self) {
            .add => .{ .args = "<owner>/<repo>[@<tag>] [--as=<name>] [--registry=<host>]", .desc = "Add a dependency to build.zig.zon (wraps `zig fetch --save`)" },
            .list => .{ .args = "", .desc = "List the dependencies declared in build.zig.zon" },
            .check => .{ .args = "[-u] [--all] [--target=<latest|minor|patch>]", .desc = "Check dependencies against upstream, or update them with -u" },
            .version => .{ .args = "", .desc = "Show version info" },
            .help => .{ .args = "", .desc = "Show this help text" },
        };
    }
};

pub const usage = blk: {
    const names = std.meta.fieldNames(Command);

    var synopsis: []const u8 = "";
    var cmds: []const u8 = "";
    for (names) |name| {
        const m = @field(Command, name).meta();
        if (m.args.len != 0)
            synopsis = synopsis ++ std.fmt.comptimePrint("  depz {s} {s}\n", .{ name, m.args });
        cmds = cmds ++ std.fmt.comptimePrint("  {s:<10}{s}\n", .{ name, m.desc });
    }

    break :blk std.fmt.comptimePrint(
        \\depz — ergonomic dependency management for Zig
        \\
        \\Usage:
        \\  depz <command> [args]
        \\
        \\{s}
        \\Commands:
        \\{s}
        \\Options:
        \\  -h, --help       Show this help text
        \\  -V, --version    Print the version string
        \\
    , .{ synopsis, cmds });
};

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version");
}
