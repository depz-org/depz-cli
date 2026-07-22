const std = @import("std");
const args = @import("../args.zig");
const Context = @import("../Context.zig");
const manifest = @import("../manifest.zig");
const semver = @import("../semver.zig");
const source = @import("../source.zig");

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
    const host = source.resolveHost(registry, man.depz.registry);

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
        break :blk try source.buildGitUrl(ctx.arena, host, repo, v);
    } else try source.buildGitUrl(ctx.arena, host, repo, null);

    const result = try fetchSave(ctx, alias, url);
    if (result.term != .exited or result.term.exited != 0) {
        if (wantsAlias(result.stderr, alias))
            std.process.fatal(
                \\'{s}' has no build.zig.zon, so its name can't be inferred.
                \\Re-run with --as=<name> to pick one:
                \\  depz add {s} --as=<name>
                \\
            , .{ target, target });
        std.process.fatal("`zig fetch` failed for {s}:\n{s}", .{ target, result.stderr });
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
    return try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "zig", "fetch", save, url },
    });
}

/// True if a failed `zig fetch` failed *specifically* because the package
/// has no build.zig.zon to derive a name from — the one case `--as` fixes.
///
/// Matches zig's stderr text (zig 0.17.0-dev):
///   error: unable to determine name; fetched package has no build.zig.zon file
/// This couples us to an unstable, unpromised message: if zig rewords it,
/// this returns false and we fall back to the raw error — degraded, not broken.
///
/// Guarded on `alias == null`: if the user already passed --as and it still
/// failed, the cause isn't a missing name, so suggesting --as would mislead.
fn wantsAlias(stderr: []const u8, alias: ?[]const u8) bool {
    if (alias != null) return false;
    return std.mem.indexOf(u8, stderr, "unable to determine name") != null;
}

test "wantsAlias: real 'no build.zig.zon' stderr with no alias → true" {
    // Verbatim from `depz add kokke/tiny-regex-c`, zig 0.17.0-dev.
    const stderr = "error: unable to determine name; fetched package has no build.zig.zon file\n";
    try std.testing.expect(wantsAlias(stderr, null));
}

test "wantsAlias: same failure but alias already given → false" {
    const stderr = "error: unable to determine name; fetched package has no build.zig.zon file\n";
    try std.testing.expect(!wantsAlias(stderr, "my-lib"));
}

test "wantsAlias: an unrelated fetch failure → false" {
    const stderr = "error: unable to resolve host 'github.com'\n";
    try std.testing.expect(!wantsAlias(stderr, null));
}
