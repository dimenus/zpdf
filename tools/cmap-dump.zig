//! Prints what zpdf's predefined CMaps select, for tools/cmap-oracle.py to compare with another
//! reader's: one line per code in a CMap's codespace that has a CID mapping.
//!
//!     cmap-dump <name>...
//!
//! For each name: a "<name> cs <length> <low, hex> <high, hex>" line per codespace range, then a
//! "<name> <code, hex> <length> <cid>" line per code with a mapping, and a
//! "<name> nd <code, hex> <length> <cid>" line per code with none but a notdef mapping.
//!
//! It reads the CMaps the way the text reader does (src/cmap.zig, the embedded blob), and lists
//! every code of every codespace range, byte by byte, so a code the source maps outside its
//! codespace is not listed (the reader never takes such a code from a string).

const std = @import("std");
const cmap = @import("cmap");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const w = &stdout.interface;
    for (args[1..]) |name| {
        const m = cmap.predefined(name) orelse {
            std.debug.print("cmap-dump: {s} is not a predefined CMap\n", .{name});
            std.process.exit(1);
        };
        var codes: u64 = 0;
        var it = m.codespaces();
        while (it.next()) |cs| {
            try w.print("{s} cs {d} {x} {x}\n", .{ name, cs.len, std.mem.readVarInt(u32, cs.lo[0..cs.len], .big), std.mem.readVarInt(u32, cs.hi[0..cs.len], .big) });
        }
        it = m.codespaces();
        while (it.next()) |cs| {
            var bytes: [4]u8 = cs.lo;
            while (true) {
                const s = bytes[0..cs.len];
                const code = m.split(s);
                if (code.valid and code.len == cs.len) {
                    if (m.cid(code)) |c| {
                        try w.print("{s} {x} {d} {d}\n", .{ name, std.mem.readVarInt(u32, s, .big), cs.len, c });
                        codes += 1;
                    } else if (m.notdef(code)) |c| {
                        try w.print("{s} nd {x} {d} {d}\n", .{ name, std.mem.readVarInt(u32, s, .big), cs.len, c });
                    }
                }
                // The next code of the range, last byte first.
                var i: usize = cs.len;
                while (i > 0) {
                    i -= 1;
                    if (bytes[i] < cs.hi[i]) {
                        bytes[i] += 1;
                        break;
                    }
                    bytes[i] = cs.lo[i];
                } else break;
            }
        }
        if (codes == 0) {
            std.debug.print("cmap-dump: {s} maps no code\n", .{name});
            std.process.exit(1);
        }
    }
    try w.flush();
}
