const std = @import("std");
const args = @import("../args.zig");
const Context = @import("../Context.zig");
const manifest = @import("../manifest.zig");
const git = @import("../git.zig");
const fetch = @import("../fetch.zig");

/// Adds a dependency to the current project's `build.zig.zon`.
///
/// Thin wrapper around `zig fetch --save`, which downloads, hashes, and writes
/// the dependency entry itself. depz builds the `git+https://…` URL — choosing
/// the host from `--registry`, the project's `.depz.registry`, or the default —
/// and lets `zig fetch` resolve and pin the exact commit.
///
/// A trailing `@<tag>` pins a version; without it, the default branch's latest
/// commit is tracked. Range constraints (`^1.0.0`) need upstream tag
/// enumeration to pick a match; that's phase two and is rejected here for now.
pub fn run(ctx: Context, argv: []const []const u8) !void {
    const parsed = try args.classify(ctx.arena, argv[2..]);
    if (parsed.positionals.len == 0)
        std.process.fatal("`add` needs a package, e.g. `depz add <owner>/<repo>@<version>`", .{});

    const src = try ctx.root.readFileAllocOptions(ctx.io, "build.zig.zon", ctx.arena, .unlimited, .of(u8), 0);
    const man = try manifest.parse(ctx.arena, src);
    const target = parsed.positionals[0];
    const alias = parsed.get("as");
    const registry = parsed.get("registry");
    const host = git.resolveHost(registry, man.depz.registry);

    // Split repo from optional @version on the LAST '@', so an ssh-style
    // git@host:owner/repo keeps its leading git@ in the repo part.
    const at = std.mem.lastIndexOfScalar(u8, target, '@');
    const repo = if (at) |i| target[0..i] else target;
    const version: ?[]const u8 = if (at) |i| target[i + 1 ..] else null;

    const url = if (version) |v| blk: {
        if (isRange(v))
            std.process.fatal(
                "`add` needs a concrete version like @v1.2.3 for now, not a range ('{s}'). Range resolution is coming.",
                .{v},
            );
        break :blk try git.buildGitUrl(ctx.arena, host, repo, v);
    } else try git.buildGitUrl(ctx.arena, host, repo, null);

    switch (try fetch.fetchSave(ctx, alias, url)) {
        .ok => {},
        .name_not_inferable => std.process.fatal(
            \\'{s}' has no build.zig.zon, so its name can't be inferred.
            \\Re-run with --as=<name> to pick one:
            \\  depz add {s} --as=<name>
            \\
        , .{ target, target }),
        .failed => |stderr| std.process.fatal("`zig fetch` failed for {s}:\n{s}", .{ target, stderr }),
    }
}

/// True if `v` is a range constraint rather than a concrete version.
/// Concrete = a plain tag zig fetch can resolve directly (`v1.2.3`, `1.2.3`).
fn isRange(v: []const u8) bool {
    if (v.len == 0) return false;
    return switch (v[0]) {
        '^', '~', '>', '<', '=' => true,
        else => false,
    };
}

/// Run `zig fetch --save[=<alias>]`; it downloads, hashes, and writes the entry.
fn fetchSave(ctx: Context, alias: ?[]const u8, url: []const u8) !std.process.RunResult {
    const save = if (alias) |a| try std.fmt.allocPrint(ctx.arena, "--save={s}", .{a}) else "--save";
    return std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "zig", "fetch", save, url },
    });
}
