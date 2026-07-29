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

/// Buffered stdout, for command output proper. Injected so tests can point a
/// command at a fixed buffer instead of the real process stdout.
///
/// Context does not own the writer or its buffer: the caller constructs both
/// and is responsible for flushing before exit. Diagnostics don't belong
/// here — they go to `err`.
out: *std.Io.Writer,

/// Buffered stderr, for diagnostics: warnings, per-item failures, anything
/// that isn't the command's actual output. Kept separate from `out` so that
/// callers piping stdout — scripts, agents — get clean data on the pipe with
/// errors still surfacing on the terminal.
///
/// Same ownership rule as `out`: the caller constructs both the writer and its
/// buffer, and is responsible for flushing before exit.
err: *std.Io.Writer,

const Context = @This();
