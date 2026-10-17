//! Compiles one of src/cid's CID-to-Unicode CMaps to a CidTable (src/read_text.zig says the
//! format), for build.zig to embed.
//!
//!     gen-cid-table <src/cid/Adobe-<ordering>-UCS2> <out>
//!
//! It parses the CMap with zpdf.read's own parseCMap and writes what CMap.lookup gives for each
//! two-byte code, so the table reads exactly as the CMap did. Built against src/read_text.zig
//! with no tables of its own (read_options.cid_tables false).

const std = @import("std");
const read_text = @import("read_text");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: gen-cid-table <cmap> <out>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 24));
    const table = try read_text.encodeCidTable(arena, text);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = table });
}
