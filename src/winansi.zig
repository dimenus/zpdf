//! WinAnsiEncoding (ISO 32000-1 Annex D): the one-byte encoding zpdf's standard fonts draw with.
//!
//! It is code page 1252's characters: printable ASCII (0x20-0x7E), Latin-1 (0xA0-0xFF, the
//! same numbers as Unicode), and 27 characters cp1252 puts in 0x80-0x9F (the euro sign, curly
//! quotes, dashes, the bullet, a few letters such as Œ and Ž). C0 controls and DEL are left out:
//! cp1252 maps them to themselves, but the standard fonts have no glyph for them, so drawing one
//! would show nothing and report nothing. U+00A0 draws as a space and U+00AD as a hyphen.
//! tests/winansi/table.tsv (tools/winansi-oracle.py, from Python's cp1252 codec) is the oracle.

const std = @import("std");

/// The WinAnsi byte for `cp`, or null when the standard fonts cannot draw it.
pub fn encode(cp: u21) ?u8 {
    return switch (cp) {
        0x20...0x7E, 0xA0...0xFF => @intCast(cp),
        0x20AC => 0x80,
        0x201A => 0x82,
        0x0192 => 0x83,
        0x201E => 0x84,
        0x2026 => 0x85,
        0x2020 => 0x86,
        0x2021 => 0x87,
        0x02C6 => 0x88,
        0x2030 => 0x89,
        0x0160 => 0x8A,
        0x2039 => 0x8B,
        0x0152 => 0x8C,
        0x017D => 0x8E,
        0x2018 => 0x91,
        0x2019 => 0x92,
        0x201C => 0x93,
        0x201D => 0x94,
        0x2022 => 0x95,
        0x2013 => 0x96,
        0x2014 => 0x97,
        0x02DC => 0x98,
        0x2122 => 0x99,
        0x0161 => 0x9A,
        0x203A => 0x9B,
        0x0153 => 0x9C,
        0x017E => 0x9E,
        0x0178 => 0x9F,
        else => null,
    };
}

/// The character WinAnsi byte `b` stands for, or null for the five unused bytes (0x81, 0x8D,
/// 0x8F, 0x90, 0x9D) and the C0 controls and DEL, which `encode` does not produce. The inverse of
/// `encode` over the bytes it gives.
pub fn decode(b: u8) ?u21 {
    return switch (b) {
        0x20...0x7E, 0xA0...0xFF => b,
        0x80 => 0x20AC,
        0x82 => 0x201A,
        0x83 => 0x0192,
        0x84 => 0x201E,
        0x85 => 0x2026,
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02C6,
        0x89 => 0x2030,
        0x8A => 0x0160,
        0x8B => 0x2039,
        0x8C => 0x0152,
        0x8E => 0x017D,
        0x91 => 0x2018,
        0x92 => 0x2019,
        0x93 => 0x201C,
        0x94 => 0x201D,
        0x95 => 0x2022,
        0x96 => 0x2013,
        0x97 => 0x2014,
        0x98 => 0x02DC,
        0x99 => 0x2122,
        0x9A => 0x0161,
        0x9B => 0x203A,
        0x9C => 0x0153,
        0x9E => 0x017E,
        0x9F => 0x0178,
        else => null,
    };
}

/// `utf8` as WinAnsi bytes, allocated with `allocator`. error.NotWinAnsi when a character has
/// no WinAnsi byte (never a substitute), error.InvalidUtf8 for bad UTF-8.
pub fn encodeUtf8(allocator: std.mem.Allocator, utf8: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(utf8) catch return error.InvalidUtf8;
    var out: std.ArrayList(u8) = try .initCapacity(allocator, utf8.len);
    errdefer out.deinit(allocator);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| out.appendAssumeCapacity(encode(cp) orelse return error.NotWinAnsi);
    return out.toOwnedSlice(allocator);
}

test "encode equals Python's cp1252 table for every code point" {
    const options = @import("build_options");
    // The oracle file and a 1,114,112-entry table (2.2 MB, too big for the stack) live exactly as
    // long as the test: one arena, one free.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tsv = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.winansi_table, arena, .unlimited);
    const want = try arena.alloc(i16, 0x110000);
    @memset(want, -1);
    var rows = std.mem.splitScalar(u8, tsv, '\n');
    var n: usize = 0;
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        var cols = std.mem.splitScalar(u8, row, '\t');
        const cp = try std.fmt.parseInt(u21, cols.next().?, 16);
        want[cp] = try std.fmt.parseInt(u8, cols.next().?, 16);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 218), n);
    var cp: u21 = 0;
    while (cp < 0x110000) : (cp += 1) {
        const got: i16 = if (encode(cp)) |b| b else -1;
        if (got != want[cp]) {
            std.debug.print("U+{X:0>4}: zpdf {d}, cp1252 {d}\n", .{ cp, got, want[cp] });
            return error.TestUnexpectedResult;
        }
    }
}

test "decode is the inverse of encode on every byte" {
    var decoded: usize = 0;
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        if (decode(b)) |cp| {
            try std.testing.expectEqual(@as(?u8, b), encode(cp));
            decoded += 1;
        }
    }
    // Every byte encode produces is decoded: 218 code points, two of them (U+00A0, U+00AD) the
    // only ones mapped from 0xA0 and 0xAD.
    try std.testing.expectEqual(@as(usize, 218), decoded);
}

test "encodeUtf8 refuses a character outside WinAnsi and bad UTF-8" {
    const gpa = std.testing.allocator;
    const ok = try encodeUtf8(gpa, "Caf\u{e9} \u{20ac}5 \u{2014} \u{201c}ok\u{201d}");
    defer gpa.free(ok);
    try std.testing.expectEqualSlices(u8, "Caf\xe9 \x805 \x97 \x93ok\x94", ok);
    try std.testing.expectError(error.NotWinAnsi, encodeUtf8(gpa, "\u{0142}"));
    try std.testing.expectError(error.NotWinAnsi, encodeUtf8(gpa, "a\tb"));
    try std.testing.expectError(error.InvalidUtf8, encodeUtf8(gpa, "\xff"));
}
