//! Checks the PDFs `zig build golden` made against tests/golden/sha256.txt.
//!
//!   golden-check <sha256.txt> <name>=<pdf path>...
//!
//! sha256.txt is `shasum -a 256` output: "<hex>  <name>" per line. Every name
//! given must have a line and match it, and every line must have a name given,
//! so a case dropped from cases.tsv fails as loudly as a changed one. All
//! differences are printed before it fails, each with the path of the PDF it
//! made, so the old and new files can be compared (qpdf --qdf, or cmp on the
//! .plain cases, which are written without compression).
//!
//! It never writes sha256.txt. A changed output is either a defect or a change
//! someone means to make; for the second, they edit the line by hand, and the
//! diff shows it.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return fail("usage: golden-check <sha256.txt> <name>=<pdf>...\n", .{});

    const expected_text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
    var expected: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, expected_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOf(u8, line, "  ") orelse return fail("{s}: bad line: {s}\n", .{ args[1], line });
        const gop = try expected.getOrPut(arena, line[sep + 2 ..]);
        if (gop.found_existing) return fail("{s}: {s} listed twice\n", .{ args[1], line[sep + 2 ..] });
        gop.value_ptr.* = line[0..sep];
    }

    var bad: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (args[2..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return fail("argument is not name=path: {s}\n", .{arg});
        const name = arg[0..eq];
        const path = arg[eq + 1 ..];
        try seen.put(arena, name, {});
        const pdf = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pdf, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        const want = expected.get(name) orelse {
            std.debug.print("NEW  {s}: {s}  ({s})\n", .{ name, &got, path });
            bad += 1;
            continue;
        };
        if (!std.mem.eql(u8, want, &got)) {
            std.debug.print("DIFF {s}: want {s}, got {s}  ({s})\n", .{ name, want, &got, path });
            bad += 1;
        }
    }
    for (expected.keys()) |name| {
        if (!seen.contains(name)) {
            std.debug.print("GONE {s}: in sha256.txt, not made by any case\n", .{name});
            bad += 1;
        }
    }
    if (bad != 0) return fail("golden: {d} of {d} PDFs differ from tests/golden/sha256.txt\n", .{ bad, expected.count() });
}

fn fail(comptime fmt: []const u8, args: anytype) error{GoldenMismatch} {
    std.debug.print(fmt, args);
    return error.GoldenMismatch;
}
