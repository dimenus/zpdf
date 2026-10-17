//! Fails when a committed copy of a generated file differs from what the generator writes now.
//!
//!     same-file <generated> <committed> <the command that updates the copy>
//!
//! Both paths are build inputs, so a change to either reruns it; a comparison done while build.zig
//! is configured would not be, because the configuration is cached.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: same-file <generated> <committed> <update command>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const generated = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 24));
    const committed = try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 24));
    if (!std.mem.eql(u8, generated, committed)) {
        std.debug.print("{s} differs from what the generator writes now; run: {s}\n", .{ args[2], args[3] });
        std.process.exit(1);
    }
}
