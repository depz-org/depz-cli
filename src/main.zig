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

pub fn main(init: std.process.Init) !u8 {
    const arena: std.mem.Allocator = init.arena.allocator();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    const ctx: Context = Context.init(arena, init.io, std.Io.Dir.cwd(), &stdout.interface);

    const args = try init.minimal.args.toSlice(arena);

    // Error policy for now: let everything propagate. Any failure prints a
    // Zig trace and exits non-zero — crude, but correct. Don't add a
    // catch-and-map layer here until `run` exposes a real error set with
    // *distinct* variants worth separating (e.g. usage vs runtime). Mapping
    // a grab-bag inferred error set to codes before those variants exist is
    // inventing categories for errors that don't exist yet.
    depz_cli.run(ctx, args) catch |e| switch (e) {
        error.UnknownCommand => return 1,
        else => return e,
    };

    return 0;
}
