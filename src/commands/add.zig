const std = @import("std");
const args = @import("../args.zig");
const Context = @import("../Context.zig");
const manifest = @import("../manifest.zig");
const git = @import("../git.zig");
const fetch = @import("../fetch.zig");

/// A parsed `<repo>[@<version>]` argument.
/// All fields are slices into the original argv string — no allocation.
const Target = struct {
    /// Exactly as the user typed it, for diagnostics.
    raw: []const u8,
    repo: []const u8,
    version: ?[]const u8,

    const Error = error{ EmptyRepo, EmptyVersion, RangeUnsupported };

    /// Split on the last '@', but only when what follows looks like a tag.
    /// An ssh-style `git@host:owner/repo` has an '@' too — its tail contains
    /// '/' or ':', which a tag never does, so it stays part of the repo.
    ///
    /// Consequence: tags containing '/' (`release/1.0`) are unsupported.
    pub fn parse(raw: []const u8) Error!Target {
        var repo = raw;
        var version: ?[]const u8 = null;

        if (std.mem.lastIndexOfScalar(u8, raw, '@')) |i| {
            const tail = raw[i + 1 ..];
            if (std.mem.indexOfAny(u8, tail, "/:") == null) {
                if (tail.len == 0) return error.EmptyVersion;
                if (isRange(tail)) return error.RangeUnsupported;
                repo = raw[0..i];
                version = tail;
            }
        }
        if (repo.len == 0) return error.EmptyRepo;
        return .{ .raw = raw, .repo = repo, .version = version };
    }
};

/// Adds one or more dependencies to the current project's `build.zig.zon`.
///
/// Thin wrapper around `zig fetch --save`, which downloads, hashes, and writes
/// each dependency entry itself. depz builds the `git+https://…` URL — choosing
/// the host from `--registry`, the project's `.depz.registry`, or the default —
/// and lets `zig fetch` resolve and pin the exact commit.
///
/// A trailing `@<tag>` pins a version; without it, the default branch's latest
/// commit is tracked. Range constraints (`^1.0.0`) need upstream tag
/// enumeration to pick a match; that's phase two and is rejected here for now.
///
/// Arguments are fully parsed and validated before any fetch runs, so a bad
/// argument late in the list can't leave a half-written manifest behind.
/// Fetches then run serially — each `--save` rewrites `build.zig.zon` — and a
/// failure is reported without stopping the rest. Returns 1 if any failed.
pub fn run(ctx: Context, argv: []const []const u8) !u8 {
    const parsed = try args.classify(ctx.arena, argv[2..]);
    if (parsed.positionals.len == 0)
        std.process.fatal("`add` needs a package, e.g. `depz add <owner>/<repo>@<version>`", .{});

    const alias = parsed.get("as");
    if (alias != null and parsed.positionals.len > 1)
        std.process.fatal("--as names a single package, but {d} were given", .{parsed.positionals.len});

    const targets = try ctx.arena.alloc(Target, parsed.positionals.len);
    for (parsed.positionals, 0..) |p, i| {
        targets[i] = Target.parse(p) catch |err| {
            switch (err) {
                error.EmptyRepo => std.process.fatal(
                    "'{s}': missing package name, expected <owner>/<repo>[@<version>]",
                    .{p},
                ),
                error.EmptyVersion => std.process.fatal(
                    "'{s}': trailing '@' with no version — drop it to track the default branch, or write @v1.2.3",
                    .{p},
                ),
                error.RangeUnsupported => std.process.fatal(
                    "{s}: needs a concrete version like @v1.2.3, not a range. Range resolution is coming.",
                    .{p},
                ),
            }
        };
        // Only catches literally repeated repos. Two distinct repos can still
        // resolve to the same package name, but that isn't known until fetch.
        for (targets[0..i]) |prev| {
            if (std.mem.eql(u8, prev.repo, targets[i].repo))
                std.process.fatal("'{s}' listed more than once", .{targets[i].repo});
        }
    }

    const src = try ctx.root.readFileAllocOptions(ctx.io, "build.zig.zon", ctx.arena, .unlimited, .of(u8), 0);
    const man = try manifest.parse(ctx.arena, src);
    const host = git.resolveHost(parsed.get("registry"), man.depz.registry);

    // No `fatal` past this point: it skips `defer`, so anything still sitting
    // in the stdout buffer — every "added …" line above — would be lost.
    var any_failed = false;
    for (targets) |t| {
        const url = try git.buildGitUrl(ctx.arena, host, t.repo, t.version);
        switch (try fetch.fetchSave(ctx, alias, url)) {
            .ok => try ctx.out.print("added {s}\n", .{t.raw}),
            .name_not_inferable => {
                any_failed = true;
                try ctx.err.print(
                    \\'{s}' has no build.zig.zon, so its name can't be inferred.
                    \\Re-run with --as=<name> to pick one:
                    \\  depz add {s} --as=<name>
                    \\
                , .{ t.raw, t.raw });
            },
            .failed => |stderr| {
                any_failed = true;
                try ctx.err.print("`zig fetch` failed for {s}:\n{s}\n", .{ t.raw, stderr });
            },
        }
    }

    return @intFromBool(any_failed);
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

test "Target.parse: accepted forms" {
    const cases = [_]struct {
        raw: []const u8,
        repo: []const u8,
        version: ?[]const u8,
    }{
        .{ .raw = "foo/bar", .repo = "foo/bar", .version = null },
        .{ .raw = "foo/bar@v1.0.0", .repo = "foo/bar", .version = "v1.0.0" },
        .{ .raw = "git@github.com:foo/bar", .repo = "git@github.com:foo/bar", .version = null },
        .{ .raw = "git@github.com:foo/bar@v1.0.0", .repo = "git@github.com:foo/bar", .version = "v1.0.0" },
    };
    for (cases) |c| {
        const t = try Target.parse(c.raw);
        try std.testing.expectEqualStrings(c.raw, t.raw);
        try std.testing.expectEqualStrings(c.repo, t.repo);
        if (c.version) |v| {
            try std.testing.expectEqualStrings(v, t.version.?);
        } else {
            try std.testing.expect(t.version == null);
        }
    }
}

test "Target.parse: rejected forms" {
    try std.testing.expectError(error.EmptyVersion, Target.parse("foo/bar@"));
    try std.testing.expectError(error.EmptyRepo, Target.parse("@v1.0.0"));
    try std.testing.expectError(error.RangeUnsupported, Target.parse("foo/bar@^1.0.0"));
}
