const std = @import("std");
const args = @import("../args.zig");
const Context = @import("../Context.zig");
const manifest = @import("../manifest.zig");
const git = @import("../git.zig");

/// Prints the dependencies declared in the current project's `build.zig.zon`.
///
/// Local only — reads the manifest and nothing else. Anything that needs to
/// talk to an upstream lives in `check`.
pub fn run(ctx: Context, argv: []const []const u8) !void {
    const parsed = try args.classify(ctx.arena, argv[2..]);

    // Migration shim: `--check` moved out into its own command.
    if (parsed.has("check")) {
        std.process.fatal("`list --check` is now its own command — run `depz check`", .{});
    }

    const src = try ctx.root.readFileAllocOptions(ctx.io, "build.zig.zon", ctx.arena, .unlimited, .of(u8), 0);
    const man = try manifest.parse(ctx.arena, src);

    if (man.deps.len == 0) {
        try ctx.out.writeAll("No dependencies.\n");
        return;
    }

    var name_w: usize = 0;
    for (man.deps) |dep| name_w = @max(name_w, dep.name.len);

    const plural = if (man.deps.len == 1) "y" else "ies";
    try ctx.out.print("{d} dependenc{s}\n\n", .{ man.deps.len, plural });

    for (man.deps) |dep| {
        try ctx.out.writeAll("  ");
        try padTo(ctx.out, dep.name, name_w + 4);
        try ctx.out.print("{s}\n", .{try pinLabel(ctx.arena, dep)});
    }
}

fn pinLabel(arena: std.mem.Allocator, dep: manifest.Dependency) ![]const u8 {
    const url = switch (dep.location) {
        .path => |p| return std.fmt.allocPrint(arena, "local {s}", .{p}),
        .url => |u| u,
    };
    const git_url = git.GitUrl.parse(url) orelse return "url";

    if (git_url.ref) |ref| return ref;
    if (git_url.commit) |sha| return git.fmtSha(arena, sha);
    return "url"; // git+ URL with no pin at all
}

/// Append `s` left-aligned in a field of `width`, padding with spaces.
fn padTo(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}
