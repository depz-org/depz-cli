//! Schema-free argv classifier: splits tokens into positionals and flags.
//! Per-command validation lives at the call site, not here.

const std = @import("std");

/// A parsed command-line flag.
///
/// `value` is `""` both for flags written without `=` (`--verbose`) and for
/// flags written with a trailing `=` and nothing after it (`--output=`). This
/// classifier does not distinguish the two: read `value` only for flags you
/// know take an argument, and test boolean presence via `Parsed.has`.
pub const Flag = struct { name: []const u8, value: []const u8 };

/// Result of classifying an argv slice.
///
/// Ownership: the outer slices (`positionals`, `flags`) are owned by the arena
/// passed to `classify`. The string *contents* — each name, value, and
/// positional — alias the original `argv` and are NOT copied. A `Parsed` thus
/// borrows both the arena and `argv`, and must not outlive either.
pub const Parsed = struct {
    positionals: []const []const u8,
    flags: []const Flag,

    /// True if a flag named `name` is present, with or without a value.
    /// Use this for boolean flags.
    pub fn has(self: Parsed, name: []const u8) bool {
        for (self.flags) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }

    /// Value of the first flag matching `name`, or `null` if absent.
    /// A present flag with no `=` yields `""`, not `null` — only absence is `null`.
    pub fn get(self: Parsed, name: []const u8) ?[]const u8 {
        for (self.flags) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }
};

/// Splits `argv` into positionals and flags.
///
/// A token is a flag when it begins with `-`; all leading dashes are stripped
/// from the name. The first `=` separates name from value, so `--foo=a=b`
/// yields value `a=b`; a token with no `=` gets an empty value.
///
/// The returned `Parsed` borrows `arena` (outer slices) and `argv` (contents);
/// see `Parsed` for details.
pub fn classify(arena: std.mem.Allocator, argv: []const []const u8) !Parsed {
    var pos: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList(Flag) = .empty;

    for (argv) |tok| {
        if (tok.len > 0 and tok[0] == '-') {
            const body = std.mem.trimStart(u8, tok, "-");
            if (std.mem.indexOfScalar(u8, body, '=')) |i|
                try flags.append(arena, .{ .name = body[0..i], .value = body[i + 1 ..] })
            else
                try flags.append(arena, .{ .name = body, .value = "" });
        } else try pos.append(arena, tok);
    }

    return .{ .positionals = pos.items, .flags = flags.items };
}

// ───────────────────────── tests ─────────────────────────
test "positionals only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try classify(arena.allocator(), &.{ "add", "foo", "bar" });
    try std.testing.expectEqual(@as(usize, 3), p.positionals.len);
    try std.testing.expectEqual(@as(usize, 0), p.flags.len);
    try std.testing.expectEqualStrings("bar", p.positionals[2]);
}

test "long and short flags, with and without value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try classify(arena.allocator(), &.{ "--save", "-u", "--out=dist" });
    try std.testing.expect(p.has("save"));
    try std.testing.expect(p.has("u"));
    try std.testing.expectEqualStrings("", p.get("save").?);
    try std.testing.expectEqualStrings("dist", p.get("out").?);
}

test "trailing '=' collapses to empty value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try classify(arena.allocator(), &.{"--out="});
    try std.testing.expect(p.has("out"));
    try std.testing.expectEqualStrings("", p.get("out").?);
}

test "first '=' wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try classify(arena.allocator(), &.{"--filter=a=b"});
    try std.testing.expectEqualStrings("a=b", p.get("filter").?);
}

test "mixed order is preserved within each bucket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try classify(arena.allocator(), &.{ "add", "--save", "pkg", "-u" });
    try std.testing.expectEqualStrings("add", p.positionals[0]);
    try std.testing.expectEqualStrings("pkg", p.positionals[1]);
    try std.testing.expect(p.has("save") and p.has("u"));
}

test "absent flag is null, not empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try classify(arena.allocator(), &.{"add"});
    try std.testing.expect(!p.has("nope"));
    try std.testing.expectEqual(@as(?[]const u8, null), p.get("nope"));
}
