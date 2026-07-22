const std = @import("std");
const args = @import("../args.zig");
const Context = @import("../Context.zig");
const manifest = @import("../manifest.zig");
const semver = @import("../semver.zig");
const source = @import("../source.zig");

const Target = enum { latest, minor, patch };

/// One dependency's check result, ready to format once column widths are known.
const Row = struct {
    name: []const u8,
    current: []const u8, // version tag or short SHA, or "" for path/failed
    status: Status,

    const Status = union(enum) {
        update: []const u8, // the newer version/sha to show after "→"
        up_to_date,
        local, // path dep
        failed: []const u8, // error name
        no_match,
        plain,
    };
};

/// Lists the dependencies declared in the current project's `build.zig.zon`.
///
/// Bare `list` reads the manifest and prints each dependency — no network.
/// `--check` additionally queries each upstream for newer versions: tag-pinned
/// dependencies are compared by version, branch-tracking ones by commit. By
/// default only outdated dependencies are shown; `--all` shows every one, and
/// `--target=<latest|minor|patch>` bounds how far to look for updates.
pub fn run(ctx: Context, argv: []const []const u8) !void {
    const parsed = try args.classify(ctx.arena, argv[2..]);
    const src = try ctx.root.readFileAllocOptions(ctx.io, "build.zig.zon", ctx.arena, .unlimited, .of(u8), 0);
    const man = try manifest.parse(ctx.arena, src);

    if (man.deps.len == 0) {
        try std.Io.File.stdout().writeStreamingAll(ctx.io, "No dependencies.\n");
        return;
    }

    const do_check = parsed.has("check");
    const show_all = parsed.has("all");
    const target: Target = if (do_check) try parseTarget(parsed) else .latest;

    var rows: std.ArrayList(Row) = .empty;
    var name_w: usize = 0;
    var cur_w: usize = 0;
    var hidden: usize = 0;

    for (man.deps) |dep| {
        const row = if (do_check) try checkRow(ctx, dep, target) else try listRow(ctx, dep);
        try rows.append(ctx.arena, row);

        if (do_check and !show_all and isUpToDate(row)) {
            hidden += 1;
        } else {
            name_w = @max(name_w, row.name.len);
            cur_w = @max(cur_w, row.current.len);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    const plural = if (man.deps.len == 1) "y" else "ies";
    try out.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}{d} dependenc{s}\n\n", .{ if (do_check) "Checking " else "", man.deps.len, plural }));

    for (rows.items) |row| {
        if (do_check and !show_all and isUpToDate(row)) continue;
        try appendRow(ctx.arena, &out, row, name_w, cur_w);
    }

    if (do_check) {
        const all_up_to_date = (rows.items.len - hidden) == 0;
        if (all_up_to_date and hidden > 0) {
            try out.appendSlice(ctx.arena, "All dependencies are up to date.\n");
        } else if (hidden > 0) {
            try out.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "\n{d} up to date. Run with --all to show {s}.\n", .{ hidden, if (hidden == 1) "it" else "them" }));
        }
    }
    try std.Io.File.stdout().writeStreamingAll(ctx.io, out.items);
}

fn isUpToDate(row: Row) bool {
    return switch (row.status) {
        .up_to_date => true,
        else => false,
    };
}

fn parseTarget(parsed: args.Parsed) !Target {
    if (parsed.get("target")) |t| {
        return std.meta.stringToEnum(Target, t) orelse {
            std.process.fatal("unknown --target '{s}' (use latest, minor, or patch)", .{t});
        };
    }
    return .latest;
}

fn checkRow(ctx: Context, dep: manifest.Dependency, target: Target) !Row {
    if (dep.location == .path) {
        return .{ .name = dep.name, .current = "", .status = .local };
    }

    const url = dep.location.url;

    return blk: {
        // Every dependency depz adds is a git+https URL: a `?ref=` means it's
        // pinned to a tag (compare versions); otherwise it tracks a branch
        // (compare commits). Anything else isn't something we produce.
        if (std.mem.startsWith(u8, url, "git+")) {
            if (source.refFromGitUrl(url) != null)
                break :blk checkGitTagDep(ctx, dep, target);
            break :blk checkGitDep(ctx, dep);
        }
        break :blk error.UnsupportedUrl;
    } catch |err| {
        return .{ .name = dep.name, .current = "", .status = .{ .failed = @errorName(err) } };
    };
}

fn listRow(ctx: Context, dep: manifest.Dependency) !Row {
    const label = try depLabel(ctx.arena, dep);
    return .{ .name = dep.name, .current = label, .status = .plain };
}

fn depLabel(arena: std.mem.Allocator, dep: manifest.Dependency) ![]const u8 {
    if (dep.depz.version) |v| return v;

    return switch (dep.location) {
        .path => |p| std.fmt.allocPrint(arena, "local {s}", .{p}),
        .url => |u| blk: {
            if (std.mem.indexOfScalar(u8, u, '#')) |i| {
                const sha = u[i + 1 ..];
                break :blk try std.fmt.allocPrint(arena, "git ({s})", .{shortSha(sha)});
            }
            break :blk "url";
        },
    };
}

/// Check a git tag-pinned dependency (git+...?ref=<tag>#commit) for a newer tag.
fn checkGitTagDep(ctx: Context, dep: manifest.Dependency, target: Target) !Row {
    const url = dep.location.url;
    const repo = source.repoFromGitUrl(url) orelse return error.NotAGitUrl;
    const current = source.refFromGitUrl(url) orelse return error.NoRef;
    const cur_v = semver.parseVersion(current) orelse return error.CurrentNotSemver;

    const tags = try source.listTags(ctx, repo);

    var best: ?std.SemanticVersion = null;
    var best_raw: []const u8 = "";
    for (tags) |tag| {
        const v = semver.parseVersion(tag) orelse continue; // skip non-semver tags
        if (v.pre != null) continue;

        const allowed = switch (target) {
            .latest => true,
            .minor => v.major == cur_v.major,
            .patch => v.major == cur_v.major and v.minor == cur_v.minor,
        };
        if (!allowed) continue;

        if (best == null or v.order(best.?) == .gt) {
            best = v;
            best_raw = tag;
        }
    }

    const highest_raw = if (best == null) return .{ .name = dep.name, .current = current, .status = .no_match } else best_raw;
    if (best.?.order(cur_v) == .gt)
        return .{ .name = dep.name, .current = current, .status = .{ .update = highest_raw } };

    return .{ .name = dep.name, .current = current, .status = .up_to_date };
}

/// Check a branch-tracking git dependency by comparing its pinned commit
/// against the upstream default branch HEAD.
fn checkGitDep(ctx: Context, dep: manifest.Dependency) !Row {
    const url = dep.location.url; // path deps are filtered out in checkRow
    const repo = source.repoFromGitUrl(url) orelse return error.NotAGitUrl;
    const current = source.commitFromGitUrl(url) orelse return error.NoPinnedCommit;

    const latest = try source.headCommit(ctx, repo);

    if (std.mem.eql(u8, current, latest)) return .{ .name = dep.name, .current = shortSha(current), .status = .up_to_date };
    return .{ .name = dep.name, .current = shortSha(current), .status = .{ .update = latest } };
}

fn appendRow(arena: std.mem.Allocator, out: *std.ArrayList(u8), row: Row, name_w: usize, cur_w: usize) !void {
    try out.appendSlice(arena, "  ");
    try padTo(arena, out, row.name, name_w + 4);
    try padTo(arena, out, row.current, cur_w + 2);

    switch (row.status) {
        .update => |newer| try out.appendSlice(arena, try std.fmt.allocPrint(arena, "→ {s}", .{newer})),
        .up_to_date => try out.appendSlice(arena, "(up to date)"),
        .local => try out.appendSlice(arena, "(local)"),
        .no_match => try out.appendSlice(arena, "(no update in range)"),
        .plain => {},
        .failed => |e| try out.appendSlice(arena, try std.fmt.allocPrint(arena, "(check failed: {s})", .{e})),
    }
    try out.append(arena, '\n');
}

/// Append `s` left-aligned in a field of `width`, padding with spaces.
fn padTo(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, width: usize) !void {
    try out.appendSlice(arena, s);
    if (s.len < width) {
        const pad = width - s.len;
        var i: usize = 0;
        while (i < pad) : (i += 1) try out.append(arena, ' ');
    }
}

/// First 8 chars of a commit SHA for display.
pub fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, 8)];
}
