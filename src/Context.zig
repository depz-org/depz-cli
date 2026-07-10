//! Shared state passed to every CLI command handler.
//!
//! A single `Context` is constructed once per invocation and threaded
//! through to each subcommand. It owns none of the resources it wraps.

const std = @import("std");

/// Allocator backing all per-invocation allocations.
///
/// Expected to be arena-backed (e.g. `std.heap.ArenaAllocator.allocator()`)
/// so command handlers can allocate freely without pairing every allocation
/// with a `defer`. The caller frees the arena once the command finishes.
arena: std.mem.Allocator,

/// I/O backend used for file, network, and other blocking/async operations.
/// Injected rather than looked up globally so commands stay testable against
/// alternate `Io` implementations.
io: std.Io,

/// Directory that filesystem operations resolve against, the project root in
/// normal use. Injected rather than read from `Dir.cwd()` at each call site so
/// tests can point a command at a temp dir without mutating process-global
/// state.
root: std.Io.Dir,

const Context = @This();

/// Builds a `Context` from an already-initialized allocator and I/O backend.
/// Takes no ownership of either.
pub fn init(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) Context {
    return .{ .arena = arena, .io = io, .root = root };
}

test "Context stays a bundle of handles, not an owner of storage" {
    // Context must stay cheap to pass by value: every field is a handle
    // pointing at a resource that lives elsewhere, never the resource
    // itself. If this size jumps, a field has probably started embedding
    // owned storage (a buffer, an ArrayList, an ArenaAllocator by value) —
    // which breaks the "Context owns nothing" contract. std.Io's layout is
    // still in flux, so when this legitimately changes, confirm the growth
    // came from another handle before you bump the number.
    try std.testing.expectEqual(40, @sizeOf(Context));
}
