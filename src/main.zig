//! Entry point and imperative shell.
//!
//! `main` does the one thing that can't be unit-tested: it reaches for the
//! real world — the process arena, the real I/O backend, the actual working
//! directory — and packs them into a `Context`. Everything worth testing
//! lives under `depz_cli.run`, which takes the world through `ctx` and its
//! input as a plain value, so tests can swap both for fakes.

const std = @import("std");
const Io = std.Io;

const depz_cli = @import("depz_cli");
const Context = depz_cli.Context;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const ctx: Context = .{ .arena = arena, .io = init.io, .root = std.Io.Dir.cwd() };

    const args = try init.minimal.args.toSlice(arena);

    // Error policy for now: let everything propagate. Any failure prints a
    // Zig trace and exits non-zero — crude, but correct. Don't add a
    // catch-and-map layer here until `run` exposes a real error set with
    // *distinct* variants worth separating (e.g. usage vs runtime). Mapping
    // a grab-bag inferred error set to codes before those variants exist is
    // inventing categories for errors that don't exist yet.
    try depz_cli.run(ctx, args);
}
