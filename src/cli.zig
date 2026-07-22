const std = @import("std");
pub const Context = @import("Context.zig");
const command = @import("./command.zig");
const addCommand = @import("./commands/add.zig");
const listCommand = @import("./commands/list.zig");

pub fn run(ctx: Context, args: []const [:0]const u8) !void {
    if (args.len < 2) return printUsage(ctx.io);

    const cmd = std.meta.stringToEnum(command.Command, args[1]) orelse {
        return printUsage(ctx.io);
    };

    switch (cmd) {
        .add => try addCommand.run(ctx, args),
        .list => try listCommand.run(ctx, args),
        .help => return printUsage(ctx.io),
    }
}

fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, command.usage);
}

test {
    _ = @import("args.zig");
    _ = @import("semver.zig");
    _ = @import("./commands/add.zig");
    _ = @import("./commands/list.zig");
    _ = @import("Context.zig");
    _ = @import("./command.zig");
    _ = @import("source.zig");
    _ = @import("manifest.zig");
}
