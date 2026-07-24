const std = @import("std");
pub const Context = @import("Context.zig");
const command = @import("./command.zig");
const args = @import("./args.zig");
const addCommand = @import("./commands/add.zig");
const listCommand = @import("./commands/list.zig");
const versionCommand = @import("./commands/version.zig");

pub fn run(ctx: Context, argv: []const [:0]const u8) !void {
    if (argv.len < 2) return printUsage(ctx);

    const a = argv[1];
    if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V"))
        return printVersion(ctx);

    const cmd = std.meta.stringToEnum(command.Command, argv[1]) orelse {
        try printUsage(ctx);
        return error.UnknownCommand;
    };

    switch (cmd) {
        .add => try addCommand.run(ctx, argv),
        .list => try listCommand.run(ctx, argv),
        .version => try versionCommand.run(ctx, argv),
        .help => return printUsage(ctx),
    }
}

fn printUsage(ctx: Context) !void {
    try ctx.out.writeAll(command.usage);
}

fn printVersion(ctx: Context) !void {
    try ctx.out.writeAll(@import("build_options").version ++ "\n");
}

test {
    _ = @import("args.zig");
    _ = @import("semver.zig");
    _ = @import("./commands/add.zig");
    _ = @import("./commands/list.zig");
    _ = @import("./commands/version.zig");
    _ = @import("Context.zig");
    _ = @import("./command.zig");
    _ = @import("source.zig");
    _ = @import("manifest.zig");
}
