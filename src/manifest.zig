const std = @import("std");
const Ast = std.zig.Ast;

/// depz's own metadata for a single dependency, stored as a nested
/// `.depz = .{ ... }` block inside that dependency's `build.zig.zon` entry.
///
/// `version` holds a range constraint (`^1.0.0`) for dependencies added with a
/// range spec. Exact pins don't need it — the pinned tag already lives in the
/// URL's `?ref=` — so today it's written only once range specs land (add
/// phase two). `registry` overrides the git host for this one dependency.
pub const DepzMeta = struct { version: ?[]const u8 = null, registry: ?[]const u8 = null };

/// Project-wide depz config, stored as a top-level `.depz = .{ ... }` in
/// `build.zig.zon`. `registry` is the default git host for the project;
/// `schema` versions this metadata format for future migrations.
pub const ProjectDepz = struct { schema: u32 = 0, registry: ?[]const u8 = null };

/// Where a dependency's source lives: a remote `url` or a local `path`.
pub const Location = union(enum) { url: []const u8, path: []const u8 };

/// One parsed dependency entry from `build.zig.zon`.
pub const Dependency = struct {
    name: []const u8,
    location: Location,
    hash: ?[]const u8 = null,
    depz: DepzMeta = .{},
};

/// The parsed contents of a `build.zig.zon` file.
pub const Manifest = struct {
    name: []const u8,
    deps: []const Dependency,
    depz: ProjectDepz = .{},
};

const keys = struct {
    const name = "name";
    const dependencies = "dependencies";
    const depz = "depz";

    const dep = struct {
        const url = "url";
        const path = "path";
        const hash = "hash";
        const depz = "depz";
    };

    const meta = struct {
        const version = "version";
        const registry = "registry";
        const schema = "schema";
    };
};

pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) !Manifest {
    var ast = try Ast.parse(arena, source, .{ .mode = .zon });

    const root = ast.nodeData(.root).node;
    var buf: [2]Ast.Node.Index = undefined;
    const obj = ast.fullStructInit(&buf, root) orelse return error.NotAstStruct;

    var name: []const u8 = "";
    var deps: std.ArrayList(Dependency) = .empty;
    var project_depz: ProjectDepz = .{};

    for (obj.ast.fields) |field| {
        const key = fieldName(ast, field);
        if (std.mem.eql(u8, key, keys.name)) {
            name = ast.tokenSlice(ast.nodeMainToken(field));
        } else if (std.mem.eql(u8, key, keys.dependencies)) {
            try parseDeps(arena, ast, field, &deps);
        } else if (std.mem.eql(u8, key, keys.depz)) {
            project_depz = try parseProjectDepz(arena, ast, field);
        }
    }

    return .{ .name = name, .deps = try deps.toOwnedSlice(arena), .depz = project_depz };
}

/// Write a `.depz = .{...}` block into the dependency named `dep_name`.
///   - dependency has no `.depz` yet → insert a new field into its struct
///   - dependency already has `.depz` → parse it, merge (only overwrite keys
///     that are non-null in `incoming`), and re-render the whole block
///
/// Only the one dependency's `.depz` region is touched; the rest of the file is
/// left byte-for-byte unchanged. Returns the new source text (arena-allocated).
///
/// Currently unused by `add`: exact pins carry their version in the URL's
/// `?ref=`, so nothing needs writing. This is groundwork for range specs
/// (`depz add x@^1.0.0`), where the constraint must be stored separately from
/// the resolved commit.
pub fn injectDepz(arena: std.mem.Allocator, source: [:0]const u8, dep_name: []const u8, incoming: DepzMeta) ![:0]const u8 {
    var ast = try Ast.parse(arena, source, .{ .mode = .zon });
    const root = ast.nodeData(.root).node;

    const deps_node = findField(ast, root, keys.dependencies) orelse return error.NoDependencies;
    const dep_node = findField(ast, deps_node, dep_name) orelse return error.DepNotFound;
    const existing = findField(ast, dep_node, keys.depz);

    const rendered = try renderDepz(arena, ast, existing, incoming);

    if (existing) |depz_val| {
        // REPLACE: swap the whole `.depz = .{...}` for the new render (the
        // trailing `,` sits outside the span, so it's preserved automatically).
        //
        // FRAGILE: `- 3` walks back from the value node's first token over
        // `{`, `=`, `depz` to land on the leading `.`. This assumes the
        // standard `.depz = .{` token layout; a comment or unusual spacing
        // before `.depz` would shift the count.
        const start = ast.tokenStart(ast.firstToken(depz_val) - 3); // back up to the leading `.` of `.depz`
        const end = ast.tokenStart(ast.lastToken(depz_val) + 1); // one byte past `}`
        return splice(arena, source, start, end, rendered);
    } else {
        // INSERT: add a line just before the dependency struct's closing `}`.
        const rb = ast.tokenStart(ast.lastToken(dep_node));
        const line_start = lineStartBefore(source, rb);
        const brace_indent = source[line_start..rb]; // leading whitespace of the `}` line
        const text = try std.fmt.allocPrint(arena, "{s}    {s},\n", .{ brace_indent, rendered });
        return splice(arena, source, line_start, line_start, text);
    }
}

fn parseDeps(arena: std.mem.Allocator, ast: Ast, deps_node: Ast.Node.Index, out: *std.ArrayList(Dependency)) !void {
    var buf: [2]Ast.Node.Index = undefined;
    const obj = ast.fullStructInit(&buf, deps_node) orelse return error.BadDependency;

    for (obj.ast.fields) |field| {
        const dep_name = fieldName(ast, field);
        try out.append(arena, try parseSingleDep(arena, ast, dep_name, field));
    }
}

fn parseSingleDep(arena: std.mem.Allocator, ast: Ast, name: []const u8, node: Ast.Node.Index) !Dependency {
    var buf: [2]Ast.Node.Index = undefined;
    const obj = ast.fullStructInit(&buf, node) orelse return error.BadDependency;

    var location: ?Location = null;
    var hash: ?[]const u8 = null;
    var depz: ?DepzMeta = null;

    for (obj.ast.fields) |field| {
        const key = fieldName(ast, field);
        if (std.mem.eql(u8, key, keys.dep.url)) {
            location = .{ .url = try strValue(arena, ast, field) };
        } else if (std.mem.eql(u8, key, keys.dep.path)) {
            location = .{ .path = try strValue(arena, ast, field) };
        } else if (std.mem.eql(u8, key, keys.dep.hash)) {
            hash = try strValue(arena, ast, field);
        } else if (std.mem.eql(u8, key, keys.dep.depz)) {
            depz = try parseDepzMeta(arena, ast, field);
        }
    }

    return .{ .name = name, .location = location orelse return error.DependencyMissingLocation, .hash = hash, .depz = depz orelse .{} };
}

fn parseProjectDepz(arena: std.mem.Allocator, ast: Ast, node: Ast.Node.Index) !ProjectDepz {
    var buf: [2]Ast.Node.Index = undefined;
    const obj = ast.fullStructInit(&buf, node) orelse return error.BadDepz;

    var out: ProjectDepz = .{};
    for (obj.ast.fields) |field| {
        const key = fieldName(ast, field);
        if (std.mem.eql(u8, key, keys.meta.schema)) {
            out.schema = try intValue(u32, ast, field);
        } else if (std.mem.eql(u8, key, keys.meta.registry)) {
            out.registry = try strValue(arena, ast, field);
        }
    }

    return out;
}

fn parseDepzMeta(arena: std.mem.Allocator, ast: Ast, node: Ast.Node.Index) !DepzMeta {
    var buf: [2]Ast.Node.Index = undefined;
    const obj = ast.fullStructInit(&buf, node) orelse return error.BadDepzMeta;

    var out: DepzMeta = .{};
    for (obj.ast.fields) |field| {
        const key = fieldName(ast, field);
        if (std.mem.eql(u8, key, keys.meta.version)) {
            out.version = try strValue(arena, ast, field);
        } else if (std.mem.eql(u8, key, keys.meta.registry)) {
            out.registry = try strValue(arena, ast, field);
        }
    }

    return out;
}

fn findField(ast: Ast, struct_node: Ast.Node.Index, key: []const u8) ?Ast.Node.Index {
    var buf: [2]Ast.Node.Index = undefined;
    const obj = ast.fullStructInit(&buf, struct_node) orelse return null;
    for (obj.ast.fields) |field| {
        if (std.mem.eql(u8, fieldName(ast, field), key)) return field;
    }

    return null;
}

fn renderDepz(arena: std.mem.Allocator, ast: Ast, existing: ?Ast.Node.Index, incoming: DepzMeta) ![]const u8 {
    var merged: DepzMeta = if (existing) |e| try parseDepzMeta(arena, ast, e) else .{};
    if (incoming.version) |v| merged.version = v;
    if (incoming.registry) |r| merged.registry = r;

    var body: std.ArrayList(u8) = .empty;
    if (merged.version) |v|
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, " .version = \"{f}\",", .{std.zig.fmtString(v)}));
    if (merged.registry) |r|
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, " .registry = \"{f}\",", .{std.zig.fmtString(r)}));

    return std.fmt.allocPrint(arena, ".depz = .{{{s} }}", .{body.items});
}

fn splice(arena: std.mem.Allocator, source: []const u8, start: usize, end: usize, insert: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, "{s}{s}{s}", .{ source[0..start], insert, source[end..] }, 0);
}

fn lineStartBefore(source: []const u8, off: usize) usize {
    var i = off;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// The field-name identifier sits two tokens before the value node's first
/// token: `.url = "..."` → step back over `=` and `.` to land on `url`.
fn fieldName(ast: Ast, value_node: Ast.Node.Index) []const u8 {
    return ast.tokenSlice(ast.firstToken(value_node) - 2);
}

/// Strip the surrounding quotes from a string literal. zon url/path/hash values
/// don't contain escapes, so this is enough for the common case; anything with
/// a backslash falls back to `std.zig.string_literal.parseAlloc` for full
/// correctness.
fn strValue(arena: std.mem.Allocator, ast: Ast, node: Ast.Node.Index) ![]const u8 {
    if (ast.nodeTag(node) != .string_literal) return error.ExpectedString;

    const raw = ast.tokenSlice(ast.nodeMainToken(node)); // includes quotes
    const inner = raw[1 .. raw.len - 1];

    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

    return std.zig.string_literal.parseAlloc(arena, raw);
}

fn intValue(comptime T: type, ast: Ast, node: Ast.Node.Index) !T {
    if (ast.nodeTag(node) != .number_literal) return error.ExpectedNumber;

    return std.fmt.parseInt(T, ast.tokenSlice(ast.nodeMainToken(node)), 10);
}

// ───────────────────────── tests ─────────────────────────
const testing = std.testing;

const test_zon =
    \\.{
    \\    .name = .depz_cli,
    \\    .version = "0.0.0",
    \\    .dependencies = .{
    \\        .httpz = .{
    \\            .url = "git+https://github.com/karlseguin/http.zig#5d1b4e2e",
    \\            .hash = "httpz-0.0.0-PNVzrPjhCAAaw",
    \\            .depz = .{ .version = "^1.0.0" },
    \\        },
    \\        .mylib = .{
    \\            .path = "../mylib",
    \\        },
    \\    },
    \\    .depz = .{
    \\        .schema = 1,
    \\        .registry = "https://depz.com",
    \\    },
    \\}
;

fn findDep(man: Manifest, name: []const u8) ?Dependency {
    for (man.deps) |d| {
        if (std.mem.eql(u8, d.name, name)) {
            return d;
        }
    }

    return null;
}

test "parse: name and dependency count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const man = try parse(arena.allocator(), test_zon);

    try testing.expectEqualStrings("depz_cli", man.name);
    try testing.expectEqual(@as(usize, 2), man.deps.len);
}

test "parse: top-level .depz (guards schema spelling + wiring)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const man = try parse(arena.allocator(), test_zon);

    try testing.expectEqual(@as(u32, 1), man.depz.schema);
    try testing.expect(man.depz.registry != null);
    try testing.expectEqualStrings("https://depz.com", man.depz.registry.?);
}

test "parse: per-dep .depz version (guards dropping depz in parseSingleDep)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const man = try parse(arena.allocator(), test_zon);

    const httpz = findDep(man, "httpz") orelse return error.DepNotFound;
    try testing.expect(httpz.depz.version != null);
    try testing.expectEqualStrings("^1.0.0", httpz.depz.version.?);
}

test "parse: path dependency location variant (guards .path parsed as .url)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const man = try parse(arena.allocator(), test_zon);

    const mylib = findDep(man, "mylib") orelse return error.DepNotFound;
    switch (mylib.location) {
        .path => |p| try testing.expectEqualStrings("../mylib", p),
        .url => return error.ExpectedPathGotUrl,
    }
}

/// Confirm the output is valid zon first — a bad offset blows up as a parse
/// error here instead of slipping through silently.
fn expectParses(arena: std.mem.Allocator, src: [:0]const u8) !Manifest {
    const ast = try Ast.parse(arena, src, .{ .mode = .zon });
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    return parse(arena, src);
}

test "injectDepz: dependency without .depz → insert, leaving other fields alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\.{
        \\    .name = .depz_cli,
        \\    .fingerprint = 0x1234abcd,
        \\    .dependencies = .{
        \\        .httpz = .{
        \\            .url = "git+https://github.com/karlseguin/http.zig#5d1b",
        \\            .hash = "httpz-0.0.0-PNVzr",
        \\        },
        \\        .mylib = .{
        \\            .path = "../mylib",
        \\        },
        \\    },
        \\    .depz = .{ .schema = 1 },
        \\}
    ;

    const out = try injectDepz(a, src, "httpz", .{ .version = "^2.0.0" });
    const man = try expectParses(a, out);

    // target dependency got the version
    const httpz = findDep(man, "httpz") orelse return error.DepNotFound;
    try testing.expectEqualStrings("^2.0.0", httpz.depz.version orelse return error.NoVersion);

    // everything else untouched: other deps, top-level name, top-level .depz
    const mylib = findDep(man, "mylib") orelse return error.DepNotFound;
    switch (mylib.location) {
        .path => |p| try testing.expectEqualStrings("../mylib", p),
        .url => return error.MylibClobbered,
    }
    try testing.expectEqualStrings("depz_cli", man.name);
    try testing.expectEqual(@as(u32, 1), man.depz.schema);
}

test "injectDepz: dependency already has .depz → merge, registry not lost" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\.{
        \\    .name = .depz_cli,
        \\    .dependencies = .{
        \\        .httpz = .{
        \\            .url = "git+https://github.com/karlseguin/http.zig#5d1b",
        \\            .hash = "httpz-0.0.0-PNVzr",
        \\            .depz = .{ .registry = "https://depz.com" },
        \\        },
        \\    },
        \\}
    ;

    const out = try injectDepz(a, src, "httpz", .{ .version = "^2.0.0" });
    const man = try expectParses(a, out);

    const httpz = findDep(man, "httpz") orelse return error.DepNotFound;
    try testing.expectEqualStrings("^2.0.0", httpz.depz.version orelse return error.NoVersion);
    try testing.expectEqualStrings("https://depz.com", httpz.depz.registry orelse return error.RegistryClobbered);
}

test "injectDepz: output alignment — real entry from zig fetch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // verbatim, as depz add writes it (git+https with ?ref= and resolved commit)
    const src =
        \\.{
        \\    .name = .local_example,
        \\    .version = "0.0.0",
        \\    .dependencies = .{
        \\        .example = .{
        \\            .url = "git+https://github.com/depz-org/example?ref=v1.0.0#354309b9496780f0f81e741614db01cfcd076d74",
        \\            .hash = "example-1.0.0-AO3nTUA-AAB_ccZVWc5Qi2JDN5dgieFkYxCR681Oj_1Y",
        \\        },
        \\    },
        \\}
    ;

    const out = try injectDepz(a, src, "example", .{ .version = "v1.0.0" });

    try testing.expect(std.mem.indexOf(u8, out, "            .depz = .{") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".version = \"v1.0.0\"") != null);
}
