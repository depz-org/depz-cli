//! npm-style semver *constraint* parsing, C-library-aware.
//!
//! `std.SemanticVersion` only compares two concrete versions. This module adds
//! the range semantics depz needs (`^`, `~`, `>=`, exact) and the light tag
//! cleanup C libraries require (a `v`/`n` prefix, partial versions like `1.2`).
//!
//! Layering: `parseVersion` returns `null` for tags that are not semver even after
//! cleanup (e.g. OpenSSL `1.1.1w`). Callers decide what to do with opaque tags —
//! currently update-checking skips them (they can't be range-compared).

const std = @import("std");

/// Parse a version tag, tolerating a `v`/`n` prefix and a partial core.
///
/// `1.2` → `1.2.0`, `v1.2.3` → `1.2.3`, `1` → `1.0.0`. Returns `null` for tags
/// that are still not semver (`1.1.1w`, `n6` with letters, `1.2-beta`): those
/// are opaque and belong on the exact-match path.
///
/// Ownership: if the tag carries `-pre`/`+build`, the result aliases `text`
/// (like `std.SemanticVersion.parse`) and must not outlive it. Completed
/// partials carry no such metadata and do not alias.
pub fn parseVersion(text: []const u8) ?std.SemanticVersion {
    var s = std.mem.trim(u8, text, " ");
    if (s.len == 0) return null;
    if (s[0] == 'v' or s[0] == 'n') s = s[1..];

    const core_end = std.mem.indexOfAny(u8, s, "-+") orelse s.len;
    var dots: usize = 0;
    for (s[0..core_end]) |c| {
        if (c == '.') dots += 1;
    }

    // Complete a bare numeric partial (no suffix, so nothing aliases `buf`).
    if (dots < 2 and core_end == s.len) {
        var buf: [32]u8 = undefined;
        const tail = if (dots == 0) ".0.0" else ".0";
        const done = std.fmt.bufPrint(&buf, "{s}{s}", .{ s, tail }) catch return null;
        return std.SemanticVersion.parse(done) catch null;
    }

    return std.SemanticVersion.parse(s) catch null;
}

/// A parsed version constraint (`^1.2.3`, `~1.2.3`, `>=1.2.3`, or exact).
///
/// Currently only `parseVersion`/`order` are exercised by update-checking;
/// the range logic here (`satisfies`, `upperBound`) is groundwork for planned
/// range specs (`depz add x@^1.0.0`) and `--target=semver`. It is tested but
/// not yet wired into a command.
pub const Constraint = struct {
    op: Op,
    base: std.SemanticVersion,

    pub const Op = enum { caret, tilde, gte, exact };

    /// Parse `^1.2.3`, `~1.2.3`, `>=1.2.3`, or a bare `1.2.3`. The operand runs
    /// through `parseVersion`, so `^v1.2` and `^1.2` are accepted.
    ///
    /// Errors if the operand is opaque — you cannot range-check against a
    /// version that is not semver. Ownership: see `parseVersion`.
    pub fn parse(text: []const u8) !Constraint {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return error.EmptyConstraint;

        var op: Op = .exact;
        var rest = trimmed;
        if (std.mem.startsWith(u8, rest, ">=")) {
            op = .gte;
            rest = rest[2..];
        } else switch (rest[0]) {
            '^' => {
                op = .caret;
                rest = rest[1..];
            },
            '~' => {
                op = .tilde;
                rest = rest[1..];
            },
            else => {}, // no operator → exact
        }

        return .{ .op = op, .base = parseVersion(rest) orelse return error.InvalidVersion };
    }

    /// Does `v` satisfy this constraint?
    pub fn satisfies(self: Constraint, v: std.SemanticVersion) bool {
        // node-semver prerelease rule: a prerelease version satisfies a range
        // only when the constraint's base is itself a prerelease of the SAME
        // major.minor.patch. Otherwise prereleases are excluded — this one
        // guard also plugs the ceiling leak (^1.0.0 must reject 2.0.0-beta).
        if (v.pre != null) {
            const b = self.base;
            const same = v.major == b.major and v.minor == b.minor and v.patch == b.patch;
            if (b.pre == null or !same) return false;
        }
        return switch (self.op) {
            .exact => v.order(self.base) == .eq,
            .gte => v.order(self.base) != .lt,
            .caret, .tilde => v.order(self.base) != .lt and v.order(self.upperBound()) == .lt,
        };
    }

    /// Exclusive ceiling for caret/tilde. Undefined for exact/gte — never called.
    fn upperBound(self: Constraint) std.SemanticVersion {
        const b = self.base;
        return switch (self.op) {
            .caret => if (b.major > 0)
                .{ .major = b.major + 1, .minor = 0, .patch = 0 }
            else if (b.minor > 0)
                .{ .major = 0, .minor = b.minor + 1, .patch = 0 }
            else
                .{ .major = 0, .minor = 0, .patch = b.patch + 1 },
            // tilde locks the minor (full-version form).
            .tilde => .{ .major = b.major, .minor = b.minor + 1, .patch = 0 },
            else => unreachable,
        };
    }
};

// ───────────────────────── tests ─────────────────────────
fn expectSat(constraint: []const u8, version: []const u8, want: bool) !void {
    const c = try Constraint.parse(constraint);
    const v = parseVersion(version).?;
    try std.testing.expectEqual(want, c.satisfies(v));
}

test "caret major>0 locks major" {
    try expectSat("^1.2.3", "1.2.3", true);
    try expectSat("^1.2.3", "1.9.9", true);
    try expectSat("^1.2.3", "2.0.0", false);
    try expectSat("^1.2.3", "1.2.2", false);
}

test "caret 0.x locks minor, 0.0.x locks patch" {
    try expectSat("^0.2.3", "0.2.9", true);
    try expectSat("^0.2.3", "0.3.0", false);
    try expectSat("^0.0.3", "0.0.3", true);
    try expectSat("^0.0.3", "0.0.4", false);
}

test "tilde locks minor" {
    try expectSat("~1.2.3", "1.2.9", true);
    try expectSat("~1.2.3", "1.3.0", false);
}

test "gte and exact" {
    try expectSat(">=1.2.3", "5.0.0", true);
    try expectSat(">=1.2.3", "1.2.2", false);
    try expectSat("1.2.3", "1.2.3", true);
    try expectSat("1.2.3", "1.2.4", false);
}

test "v/n prefix is stripped" {
    try expectSat("^1.0.0", "v1.4.0", true);
    try std.testing.expect(parseVersion("n6.1.0") != null);
}

test "partial versions complete to .0" {
    try std.testing.expectEqual(@as(usize, 0), parseVersion("1.2").?.patch);
    try std.testing.expectEqual(@as(usize, 0), parseVersion("1").?.minor);
    try expectSat("^1.2.0", "1.5", true); // upstream tag written as "1.5"
}

test "prerelease excluded unless same tuple opted in" {
    try expectSat("^1.0.0", "2.0.0-beta", false); // ceiling leak plugged
    try expectSat("^1.0.0", "1.5.0-beta", false); // clean range, but pre not opted in
    try expectSat("^1.2.3-beta.1", "1.2.3-beta.2", true); // same tuple, opted in
    try expectSat("^1.2.3-beta.1", "1.2.4-beta.1", false); // different tuple
    try expectSat("^1.2.3-beta.1", "1.2.3", true); // clean release satisfies
}

test "opaque and empty" {
    try std.testing.expect(parseVersion("1.1.1w") == null); // OpenSSL-style → opaque
    try std.testing.expect(parseVersion("") == null);
    try std.testing.expectError(error.EmptyConstraint, Constraint.parse("  "));
    try std.testing.expectError(error.InvalidVersion, Constraint.parse("^1.1.1w"));
}
