const builtin = @import("builtin");
const Context = @import("../Context.zig");
const version = @import("build_options").version;

pub fn run(ctx: Context, argv: []const []const u8) !void {
    _ = argv;
    try ctx.out.print(
        \\depz {s}
        \\
        \\zig     {s}
        \\target  {s}-{s}-{s}
        \\mode    {s}
        \\
    , .{
        version,
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.abi),
        @tagName(builtin.mode),
    });
}
