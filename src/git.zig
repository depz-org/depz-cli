//! The git vocabulary: the `git+<url>[?ref=<tag>][#<commit>]` syntax depz uses
//! to identify a dependency, plus upstream queries against a remote.
//!
//! Host-agnostic by design — anything `git` can reach works, not just GitHub.
//! Equally deliberate: this module speaks strings and `Context`, never
//! `Dependency` or `Pin`. Translation between the two vocabularies lives in
//! `source.zig`, and the dependency runs one way only.
//!
//! Network access shells out to `git ls-remote`. Every network call is a thin
//! wrapper over a pure parser, so the parsing is tested without a network. If
//! ls-remote stops being enough (rate limits, richer metadata), the transport
//! swaps for an HTTP client and the parsers stay put.

const std = @import("std");
const Context = @import("./Context.zig");

/// The default git host when no registry is configured.
const default_host = "github.com";

pub const GitUrl = struct {
    /// The transport URL git itself understands — no `git+`, no pin.
    /// Exactly what `git ls-remote` takes.
    repo: []const u8,
    /// `?ref=<tag>` — the human-meaningful pin, if present.
    ref: ?[]const u8 = null,
    /// `#<sha>` — the resolved commit, if present.
    commit: ?[]const u8 = null,

    /// Parse a `git+`-prefixed dependency URL. Returns null if `url` isn't one
    /// (tarball, relative path, plain https), which subsumes the `git+` guard
    /// callers would otherwise write by hand.
    pub fn parse(url: []const u8) ?GitUrl {
        const prefix = "git+";
        if (!std.mem.startsWith(u8, url, prefix)) return null;
        var rest = url[prefix.len..];

        // Strip right to left: '#' sits after '?ref=', so it comes off first.
        var commit: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, rest, '#')) |i| {
            commit = if (i + 1 == rest.len) null else rest[i + 1 ..];
            rest = rest[0..i];
        }

        var ref: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "?ref=")) |i| {
            const r = rest[i + "?ref=".len ..];
            ref = if (r.len == 0) null else r;
            rest = rest[0..i];
        }

        return .{ .repo = rest, .ref = ref, .commit = commit };
    }

    /// The host component of `repo`, e.g. `github.com`. Null when `repo` has no
    /// `scheme://authority` (ssh shorthand, local path).
    pub fn host(self: GitUrl) ?[]const u8 {
        const i = std.mem.indexOf(u8, self.repo, "://") orelse return null;
        const authority = self.repo[i + 3 ..];
        const end = std.mem.indexOfScalar(u8, authority, '/') orelse authority.len;
        return authority[0..end];
    }

    /// Render back to canonical `git+<repo>[?ref=<ref>][#<commit>]` form.
    pub fn format(self: GitUrl, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("git+{s}", .{self.repo});
        if (self.ref) |r| try writer.print("?ref={s}", .{r});
        if (self.commit) |c| try writer.print("#{s}", .{c});
    }
};

/// Pick the git host for a dependency: dependency-level registry overrides
/// project-level, which overrides the built-in default.
///
/// `dep_registry` — override (from --registry flag or dependency-level).
/// `project_registry` — the project-level `.depz.registry`, if any.
pub fn resolveHost(dep_registry: ?[]const u8, project_registry: ?[]const u8) []const u8 {
    return dep_registry orelse project_registry orelse default_host;
}

/// Build the git+https URL for fetching a dependency.
///   host="github.com", owner_repo="arrufat/zignal", tag="0.9.1"
///     -> git+https://github.com/arrufat/zignal#0.9.1
///   host="codeberg.org", owner_repo="foreverzer0/klack", tag=null
///     -> git+https://codeberg.org/foreverzer0/klack
///
/// `owner_repo` may carry a leading host/scheme prefix (github.com/, https://,
/// git+https://); it's stripped so callers can pass user input loosely.
pub fn buildGitUrl(arena: std.mem.Allocator, host: []const u8, owner_repo: []const u8, tag: ?[]const u8) ![]const u8 {
    var slug = owner_repo;
    inline for (.{ "git+https://", "https://", "http://" }) |p|
        if (std.mem.startsWith(u8, slug, p)) {
            slug = slug[p.len..];
        };
    // also strip a leading "<host>/" if the user typed the full host
    if (std.mem.startsWith(u8, slug, host)) {
        slug = slug[host.len..];
        if (slug.len > 0 and slug[0] == '/') slug = slug[1..];
    }

    return if (tag) |t|
        std.fmt.allocPrint(arena, "git+https://{s}/{s}#{s}", .{ host, slug, t })
    else
        std.fmt.allocPrint(arena, "git+https://{s}/{s}", .{ host, slug });
}

/// Parse the stdout of `git ls-remote --tags <url>` into tag names.
///
/// Each line looks like `<sha>\t refs/tags/<name>`. Annotated tags emit an
/// extra `refs/tags/<name>^{}` peel line pointing at the underlying commit;
/// those are dropped, since the plain `refs/tags/<name>` line is always present
/// too. Lines without a `refs/tags/` ref (HEAD, branches, blanks) are ignored.
///
/// Ownership: the returned slice is arena-owned; the name strings alias
/// `stdout` and must not outlive it.
pub fn parseTags(arena: std.mem.Allocator, stdout: []const u8) ![]const []const u8 {
    const prefix = "refs/tags/";
    var out: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const idx = std.mem.indexOf(u8, line, prefix) orelse continue;
        const name = line[idx + prefix.len ..];
        if (std.mem.endsWith(u8, name, "^{}")) continue; // peeled annotated tag
        if (name.len == 0) continue;
        try out.append(arena, name);
    }
    return out.items;
}

/// List version tags for `repo_url` via `git ls-remote --tags`.
///
/// Returns raw tag names (see `parseTags`). Errors if `git` fails to spawn or
/// exits non-zero (unreachable host, private repo without creds, etc.).
pub fn listTags(ctx: Context, repo_url: []const u8) ![]const []const u8 {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "git", "ls-remote", "--tags", repo_url },
    });
    if (result.term != .exited or result.term.exited != 0)
        return error.GitLsRemoteFailed;

    return parseTags(ctx.arena, result.stdout);
}

/// Parse the stdout of `git ls-remote <url> HEAD` into the commit SHA.
///
/// The relevant line is `<sha>\tHEAD`. Returns null if no such line is found
/// (empty output, unexpected format).
pub fn parseHead(stdout: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const sha = line[0..tab];
        const ref = line[tab + 1 ..];
        if (std.mem.eql(u8, ref, "HEAD")) return sha;
    }
    return null;
}

/// Fetch the default branch's HEAD commit for `repo_url` via `git ls-remote`.
///
/// Returns the full SHA. Errors if `git` fails to spawn/exits non-zero, or if
/// the output has no HEAD line.
pub fn headCommit(ctx: Context, repo_url: []const u8) ![]const u8 {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "git", "ls-remote", repo_url, "HEAD" },
    });
    if (result.term != .exited or result.term.exited != 0)
        return error.GitLsRemoteFailed;

    return parseHead(result.stdout) orelse error.NoHeadRef;
}

/// The URL to hand `zig fetch`: repo plus an *unresolved* committish (tag,
/// branch, or SHA). Deliberately not `GitUrl` — that models a manifest entry,
/// where the fragment is always a resolved SHA. zig rewrites this into
/// `?ref=<tag>#<sha>` when it saves.
pub fn fetchUrl(arena: std.mem.Allocator, repo: []const u8, committish: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "git+{s}#{s}", .{ repo, committish });
}

/// Format a commit SHA for display: `#` sigil plus the first 8 chars.
pub fn fmtSha(arena: std.mem.Allocator, sha: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "#{s}", .{sha[0..@min(sha.len, 8)]});
}

// ───────────────────────── tests ─────────────────────────
test "GitUrl round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "git+https://codeberg.org/x/y.git?ref=v1.1.0#78bd4ba5",
        "git+https://github.com/x/y#354309b9",
        "git+https://github.com/x/y?ref=v2.0.0",
        "git+https://github.com/x/y",
    }) |url| {
        const parsed = GitUrl.parse(url).?;
        try std.testing.expectEqualStrings(url, try std.fmt.allocPrint(arena, "{f}", .{parsed}));
    }
}

test "GitUrl rejects non-git URLs" {
    // The `git+` guard now lives in one place instead of at every call site.
    try std.testing.expect(GitUrl.parse("https://example.com/z.tar.gz?ref=v1") == null);
}

test "resolveHost: dependency > project > default" {
    try std.testing.expectEqualStrings("codeberg.org", resolveHost("codeberg.org", "gitlab.com"));
    try std.testing.expectEqualStrings("gitlab.com", resolveHost(null, "gitlab.com"));
    try std.testing.expectEqualStrings("github.com", resolveHost(null, null));
}

test "buildGitUrl: with and without tag, strips prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("git+https://github.com/arrufat/zignal#0.9.1", try buildGitUrl(a, "github.com", "arrufat/zignal", "0.9.1"));
    try std.testing.expectEqualStrings("git+https://codeberg.org/foreverzer0/klack", try buildGitUrl(a, "codeberg.org", "foreverzer0/klack", null));
    // prefix stripping — all three should produce the same slug
    try std.testing.expectEqualStrings("git+https://github.com/x/y#v1.0.0", try buildGitUrl(a, "github.com", "github.com/x/y", "v1.0.0"));
    try std.testing.expectEqualStrings("git+https://github.com/x/y#v1.0.0", try buildGitUrl(a, "github.com", "https://github.com/x/y", "v1.0.0"));
}

test "parses plain tags, strips prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const stdout =
        "abc123\trefs/tags/v1.0.0\n" ++
        "def456\trefs/tags/v1.2.3\n";
    const tags = try parseTags(arena.allocator(), stdout);

    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("v1.0.0", tags[0]);
    try std.testing.expectEqualStrings("v1.2.3", tags[1]);
}

test "drops peeled annotated-tag lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const stdout =
        "abc123\trefs/tags/v1.0.0\n" ++
        "def456\trefs/tags/v1.0.0^{}\n"; // peel of the same tag
    const tags = try parseTags(arena.allocator(), stdout);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("v1.0.0", tags[0]);
}

test "ignores HEAD, branches, and blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const stdout =
        "abc123\tHEAD\n" ++
        "def456\trefs/heads/main\n" ++
        "\n" ++
        "ghi789\trefs/tags/v2.0.0\n";
    const tags = try parseTags(arena.allocator(), stdout);

    try std.testing.expectEqual(@as(usize, 1), tags.len);
    try std.testing.expectEqualStrings("v2.0.0", tags[0]);
}

test "empty stdout yields no tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tags = try parseTags(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), tags.len);
}

test "parseHead extracts the HEAD sha" {
    const stdout = "354309b9496780f0f81e741614db01cfcd076d74\tHEAD\n";
    try std.testing.expectEqualStrings(
        "354309b9496780f0f81e741614db01cfcd076d74",
        parseHead(stdout).?,
    );
}

test "parseHead ignores other refs, finds HEAD among them" {
    // ls-remote <url> HEAD usually returns just HEAD, but be robust if it doesn't
    const stdout =
        "abc\trefs/heads/main\n" ++
        "354309b9\tHEAD\n";
    try std.testing.expectEqualStrings("354309b9", parseHead(stdout).?);
}

test "parseHead returns null on empty" {
    try std.testing.expect(parseHead("") == null);
}

test "fmtSha" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("#78bd4ba5", try fmtSha(arena, "78bd4ba5e1c2d3f4a5b6"));
    // Shorter than 8 chars: truncation is a no-op, no padding.
    try std.testing.expectEqualStrings("#abc", try fmtSha(arena, "abc"));
    try std.testing.expectEqualStrings("#", try fmtSha(arena, ""));
}
