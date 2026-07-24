const std = @import("std");
pub const Context = @import("Context.zig");
const command = @import("./command.zig");
const args = @import("./args.zig");
const addCommand = @import("./commands/add.zig");
const listCommand = @import("./commands/list.zig");
const checkCommand = @import("./commands/check.zig");
const versionCommand = @import("./commands/version.zig");
const version = @import("build_options").version;

pub fn run(ctx: Context, argv: []const [:0]const u8) !void {
    if (argv.len < 2) return printUsage(ctx);

    const a = argv[1];
    if (command.isVersionFlag(a)) return printVersion(ctx);
    if (command.isHelpFlag(a)) return printUsage(ctx);

    const cmd = std.meta.stringToEnum(command.Command, argv[1]) orelse {
        try printUsage(ctx);
        return error.UnknownCommand;
    };

    switch (cmd) {
        .add => try addCommand.run(ctx, argv),
        .list => try listCommand.run(ctx, argv),
        .check => try checkCommand.run(ctx, argv),
        .version => try versionCommand.run(ctx, argv),
        .help => return printUsage(ctx),
    }
}

fn printUsage(ctx: Context) !void {
    try ctx.out.writeAll(command.usage);
}

fn printVersion(ctx: Context) !void {
    try ctx.out.writeAll(version ++ "\n");
}

test {
    _ = @import("args.zig");
    _ = @import("semver.zig");
    _ = @import("./commands/add.zig");
    _ = @import("./commands/list.zig");
    _ = @import("./commands/check.zig");
    _ = @import("./commands/version.zig");
    _ = @import("Context.zig");
    _ = @import("./command.zig");
    _ = @import("git.zig");
    _ = @import("manifest.zig");
}
