//! Everything depz needs to talk to git hosts and to read/write the git URLs
//! that identify dependencies:
//!   - URL construction (`buildGitUrl`) and host selection (`resolveHost`)
//!   - URL parsing (`repoFromGitUrl`, `commitFromGitUrl`, `refFromGitUrl`)
//!   - upstream queries via `git ls-remote` (`listTags`, `headCommit`)
//!
//! Host-agnostic: anything `git` can reach works, not just GitHub. Network
//! functions shell out to `git`; the pure parse/build helpers are unit-tested
//! in isolation. If we outgrow ls-remote (rate limits, richer metadata), the
//! transport can swap for an HTTP client while the parsers stay put.

const std = @import("std");
const Context = @import("./Context.zig");

/// The default git host when no registry is configured.
const default_host = "github.com";

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

/// Extract the pinned commit from a git dependency URL.
///   git+https://github.com/x/y#abc123              -> abc123
///   git+https://github.com/x/y?ref=dev#abc123      -> abc123
/// Returns null if there's no `#commit` part.
pub fn commitFromGitUrl(url: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, url, '#') orelse return null;
    const commit = url[i + 1 ..];
    return if (commit.len == 0) null else commit;
}

/// Recover the plain repo URL from a git dependency URL, for `git ls-remote`.
///   git+https://github.com/x/y#abc123          -> https://github.com/x/y
///   git+https://github.com/x/y?ref=dev#abc123  -> https://github.com/x/y
///   git+https://codeberg.org/a/b.git#v1.1.0    -> https://codeberg.org/a/b.git
/// Returns null if `url` isn't a `git+` URL.
pub fn repoFromGitUrl(url: []const u8) ?[]const u8 {
    const prefix = "git+";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const after = url[prefix.len..];
    const cut = std.mem.indexOfAny(u8, after, "?#") orelse after.len;
    return after[0..cut];
}

/// Extract the pinned ref (tag/branch) from a git URL's ?ref= query.
///   git+https://github.com/x/y?ref=v1.0.0#commit  ->  v1.0.0
///   git+https://github.com/x/y#commit             ->  null (no ref pinned)
pub fn refFromGitUrl(url: []const u8) ?[]const u8 {
    const marker = "?ref=";
    const i = std.mem.indexOf(u8, url, marker) orelse return null;
    const rest = url[i + marker.len ..];
    // ref ends at '#' (commit) if present, else end of string
    const end = std.mem.indexOfScalar(u8, rest, '#') orelse rest.len;
    return rest[0..end];
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

// ───────────────────────── tests ─────────────────────────
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

test "commitFromGitUrl: plain, with ref, and none" {
    try std.testing.expectEqualStrings("abc123", commitFromGitUrl("git+https://github.com/x/y#abc123").?);
    try std.testing.expectEqualStrings("abc123", commitFromGitUrl("git+https://github.com/x/y?ref=dev#abc123").?);
    try std.testing.expect(commitFromGitUrl("git+https://github.com/x/y") == null);
}

test "repoFromGitUrl: strips git+ prefix, ?ref, and #commit" {
    try std.testing.expectEqualStrings("https://github.com/x/y", repoFromGitUrl("git+https://github.com/x/y#abc123").?);
    try std.testing.expectEqualStrings("https://github.com/x/y", repoFromGitUrl("git+https://github.com/x/y?ref=dev#abc123").?);
    try std.testing.expectEqualStrings("https://codeberg.org/a/b.git", repoFromGitUrl("git+https://codeberg.org/a/b.git#v1.1.0").?);
    try std.testing.expect(repoFromGitUrl("https://github.com/x/y") == null);
}

test "refFromGitUrl" {
    // 标准：?ref=tag#commit —— tag 在 ? 和 # 之间
    try std.testing.expectEqualStrings("v1.1.0", refFromGitUrl("git+https://codeberg.org/x/y.git?ref=v1.1.0#78bd4ba5").?);

    // 无 ref（latest 依赖）：只有 #commit —— 返回 null
    try std.testing.expect(refFromGitUrl("git+https://github.com/x/y#354309b9") == null);

    // 裸 URL（latest，无 # 无 ?ref）—— 返回 null
    try std.testing.expect(refFromGitUrl("git+https://github.com/x/y") == null);

    // ref 但没有 #commit（理论边界：ref 一直到结尾）
    try std.testing.expectEqualStrings("v2.0.0", refFromGitUrl("git+https://github.com/x/y?ref=v2.0.0").?);
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
