const std = @import("std");

/// Append `s` left-aligned in a field of `width`, padding with spaces.
pub fn padTo(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
}
