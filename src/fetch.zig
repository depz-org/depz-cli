const std = @import("std");
const Context = @import("./Context.zig");

/// What `zig fetch` did. Not an error union: a non-zero exit is a normal,
/// inspectable result here, and callers differ in how much of it they need.
pub const Outcome = union(enum) {
    ok,
    /// zig couldn't infer a package name — the target has no build.zig.zon.
    /// Only reachable when `alias` was null; an explicit `--save=<name>`
    /// leaves nothing to infer.
    name_not_inferable,
    /// Any other failure. `stderr` is zig's own message, already user-facing.
    failed: []const u8,
};

/// Run `zig fetch --save[=<alias>] <url>`; zig downloads, hashes, and splices
/// the entry into build.zig.zon.
///
/// `--save=<alias>` is load-bearing when the manifest key differs from the
/// package's own declared name: bare `--save` keys off the latter and silently
/// creates a second entry.
///
/// Errors only if `zig` can't be spawned at all — a fetch that ran and failed
/// comes back as an `Outcome`.
pub fn fetchSave(ctx: Context, alias: ?[]const u8, url: []const u8) !Outcome {
    const save: []const u8 = if (alias) |a|
        try std.fmt.allocPrint(ctx.arena, "--save={s}", .{a})
    else
        "--save";

    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "zig", "fetch", save, url },
    });
    if (result.term == .exited and result.term.exited == 0) return .ok;

    if (alias == null and wantsAlias(result.stderr)) return .name_not_inferable;
    return .{ .failed = result.stderr };
}

/// Matching on another tool's stderr text is brittle by nature, so it lives
/// here in exactly one place — if zig's wording changes, this is the only
/// thing to fix.
fn wantsAlias(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "unable to determine name") != null;
}
