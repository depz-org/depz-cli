const std = @import("std");
const args = @import("../args.zig");
const Context = @import("../Context.zig");
const manifest = @import("../manifest.zig");
const semver = @import("../semver.zig");
const git = @import("../git.zig");
const fetch = @import("../fetch.zig");

/// How far to look for updates.
pub const Target = enum { latest, minor, patch };

/// One dependency's check result, ready to format once column widths are known.
pub const Row = struct {
    name: []const u8,
    current: []const u8, // version tag or short SHA, or "" for path/failed
    status: Status,

    pub const Status = union(enum) {
        update: Update,
        up_to_date,
        local, // path dep
        failed: []const u8,
        no_match,
    };

    pub const Update = struct {
        /// Rendered for the "→" column; may be truncated.
        display: []const u8,
        /// Transport URL, no `git+`, no pin.
        repo: []const u8,
        /// Tag name or full SHA — never the truncated display form.
        committish: []const u8,
    };

    pub fn isUpToDate(self: Row) bool {
        return self.status == Status.up_to_date;
    }
};

/// Checks each dependency in `build.zig.zon` against its upstream.
///
/// Tag-pinned dependencies are compared by version, branch-tracking ones by
/// commit. By default only outdated dependencies are shown; `--all` shows
/// every one, and `--target=<latest|minor|patch>` bounds how far to look.
///
/// Read-only unless `-u` is passed, which re-fetches everything the check
/// found an update for. Without it, `check` is exactly the dry run of
/// `check -u`.
pub fn run(ctx: Context, argv: []const []const u8) !void {
    const parsed = try args.classify(ctx.arena, argv[2..]);
    const show_all = parsed.has("all");
    const apply = parsed.has("u");
    const target = try parseTarget(parsed);

    const src = try ctx.root.readFileAllocOptions(ctx.io, "build.zig.zon", ctx.arena, .unlimited, .of(u8), 0);
    const man = try manifest.parse(ctx.arena, src);

    if (man.deps.len == 0) {
        try ctx.out.writeAll("No dependencies.\n");
        return;
    }

    const plural = if (man.deps.len == 1) "y" else "ies";
    try ctx.out.print("Checking {d} dependenc{s}\n\n", .{ man.deps.len, plural });

    const rows = try gather(ctx, man.deps, target);
    try report(ctx.out, rows, show_all);

    if (!apply) return;

    const applied = try applyUpdates(ctx, rows);
    if (applied > 0)
        try ctx.out.print("\nUpdated {d} dependenc{s}.\n", .{ applied, if (applied == 1) "y" else "ies" });
}

/// Render the check results as an aligned table, plus a footer for anything
/// hidden. Pure formatting — no network, no Context.
fn report(w: *std.Io.Writer, rows: []const Row, show_all: bool) !void {
    var name_w: usize = 0;
    var cur_w: usize = 0;
    var hidden: usize = 0;
    for (rows) |row| {
        if (!show_all and row.isUpToDate()) {
            hidden += 1;
            continue;
        }
        name_w = @max(name_w, row.name.len);
        cur_w = @max(cur_w, row.current.len);
    }

    for (rows) |row| {
        if (!show_all and row.isUpToDate()) continue;
        try writeRow(w, row, name_w, cur_w);
    }

    if (hidden == rows.len) {
        try w.writeAll("All dependencies are up to date.\n");
    } else if (hidden > 0) {
        try w.print("\n{d} up to date. Run with --all to show {s}.\n", .{ hidden, if (hidden == 1) "it" else "them" });
    }
}

/// Check every dependency against its upstream. Shared with `update`.
pub fn gather(ctx: Context, deps: []const manifest.Dependency, target: Target) ![]Row {
    const rows = try ctx.arena.alloc(Row, deps.len);
    for (deps, rows) |dep, *row| row.* = checkRow(ctx, dep, target);
    return rows;
}

fn applyUpdates(ctx: Context, rows: []const Row) !usize {
    var applied: usize = 0;
    for (rows) |row| {
        const up = switch (row.status) {
            .update => |u| u,
            else => continue,
        };
        const url = try git.fetchUrl(ctx.arena, up.repo, up.committish);
        switch (try fetch.fetchSave(ctx, row.name, url)) {
            .ok => applied += 1,
            // `-u` always passes an explicit name, so name_not_inferable can't occur.
            else => try ctx.out.print("  {s}: update failed\n", .{row.name}),
        }
    }
    return applied;
}

fn parseTarget(parsed: args.Parsed) !Target {
    if (parsed.get("target")) |t| {
        return std.meta.stringToEnum(Target, t) orelse {
            std.process.fatal("unknown --target '{s}' (use latest, minor, or patch)", .{t});
        };
    }

    return .latest;
}

fn checkRow(ctx: Context, dep: manifest.Dependency, target: Target) Row {
    return checkDep(ctx, dep, target) catch |err| Row{ .name = dep.name, .current = "", .status = .{ .failed = @errorName(err) } };
}

/// Route a dependency to the right upstream check. Parses the URL exactly once;
/// the shape of the resulting `GitUrl` *is* the dispatch.
fn checkDep(ctx: Context, dep: manifest.Dependency, target: Target) !Row {
    const url = switch (dep.location) {
        .path => return .{ .name = dep.name, .current = "", .status = .local },
        .url => |u| u,
    };
    const git_url = git.GitUrl.parse(url) orelse return error.UnsupportedUrl;

    // A ref pins a human-meaningful version; a bare commit tracks a branch.
    if (git_url.ref) |ref| return checkGitTagDep(ctx, dep, git_url, ref, target);
    if (git_url.commit) |sha| return checkGitDep(ctx, dep, git_url, sha);
    return error.UnsupportedUrl; // git+ URL carrying no pin at all
}

/// Check a git tag-pinned dependency (git+...?ref=<tag>#commit) for a newer tag.
fn checkGitTagDep(ctx: Context, dep: manifest.Dependency, git_url: git.GitUrl, ref: []const u8, target: Target) !Row {
    const cur_v = semver.parseVersion(ref) orelse return error.CurrentNotSemver;
    const tags = try git.listTags(ctx, git_url.repo);

    var best: ?std.SemanticVersion = null;
    var best_raw: []const u8 = "";
    for (tags) |tag| {
        const v = semver.parseVersion(tag) orelse continue;
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

    const best_v = best orelse return .{ .name = dep.name, .current = ref, .status = .no_match };

    if (best_v.order(cur_v) == .gt)
        return .{ .name = dep.name, .current = ref, .status = .{ .update = .{ .display = best_raw, .repo = git_url.repo, .committish = best_raw } } };

    return .{ .name = dep.name, .current = ref, .status = .up_to_date };
}

/// Check a branch-tracking git dependency by comparing its pinned commit
/// against the upstream default branch HEAD.
fn checkGitDep(ctx: Context, dep: manifest.Dependency, git_url: git.GitUrl, sha: []const u8) !Row {
    const latest = try git.headCommit(ctx, git_url.repo);
    const cur = try git.fmtSha(ctx.arena, sha);

    if (std.mem.eql(u8, sha, latest))
        return .{ .name = dep.name, .current = cur, .status = .up_to_date };

    return .{ .name = dep.name, .current = cur, .status = .{ .update = .{ .display = try git.fmtSha(ctx.arena, latest), .repo = git_url.repo, .committish = latest } } };
}

fn writeRow(w: *std.Io.Writer, row: Row, name_w: usize, cur_w: usize) !void {
    try w.writeAll("  ");
    try padTo(w, row.name, name_w + 4);
    try padTo(w, row.current, cur_w + 2);

    switch (row.status) {
        .update => |u| try w.print("→ {s}", .{u.display}),
        .up_to_date => try w.writeAll("(up to date)"),
        .local => try w.writeAll("(local)"),
        .no_match => try w.writeAll("(no update in range)"),
        .failed => |e| try w.print("(check failed: {s})", .{e}),
    }
    try w.writeByte('\n');
}

/// Append `s` left-aligned in a field of `width`, padding with spaces.
fn padTo(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}
