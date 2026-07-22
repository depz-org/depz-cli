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
    const registry = parsed.get("registry");
    const host = source.resolveHost(registry, man.depz.registry);

    // Split repo from optional @version on the LAST '@', so an ssh-style
    // git@host:owner/repo keeps its leading git@ in the repo part.
    const at = std.mem.lastIndexOfScalar(u8, target, '@');
    const repo = if (at) |i| target[0..i] else target;
    const version: ?[]const u8 = if (at) |i| target[i + 1 ..] else null;

    if (version) |v| {
        // Phase one: reject ranges rather than pretend to honor them.
        if (isRange(v))
            std.process.fatal(
                "`add` needs a concrete version like @v1.2.3 for now, not a range ('{s}'). Range resolution is coming.",
                .{v},
            );

        // Concrete tag: git+https://host/repo#<tag>. zig fetch resolves the tag
        // to a commit and records both in .url as ?ref=<tag>#<commit>, so the
        // URL carries the pinned version — no .depz block needed.
        const url = try source.buildGitUrl(ctx.arena, host, repo, v);
        try fetchSave(ctx, url);
    } else {
        // Latest: track the default branch. zig fetch resolves it to a concrete
        // commit and writes it into .url (git+https://…#<commit>), so the URL is
        // the single source of truth — no .depz block to add.
        const url = try source.buildGitUrl(ctx.arena, host, repo, null);
        try fetchSave(ctx, url);
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

/// Run `zig fetch --save <url>`; it downloads, hashes, and writes the entry.
fn fetchSave(ctx: Context, url: []const u8) !void {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "zig", "fetch", "--save", url },
    });
    if (result.term != .exited or result.term.exited != 0)
        std.process.fatal("`zig fetch` failed for {s}:\n{s}", .{ url, result.stderr });
}
