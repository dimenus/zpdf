//! zpdf.read's reading of a CFF font program (Adobe Technical Note 5176): the glyph name each
//! code draws by the program's own encoding. A simple font whose /Encoding has no base encoding
//! falls back on its embedded program's built-in encoding (ISO 32000-1 9.6.6.1); this gives it for
//! a /FontFile3 of /Subtype /Type1C.
//!
//! How to use it:
//!   const names = cff.builtinEncoding(arena, program_bytes);  // null: none read
//!   // names[code] is a glyph name, or null when the code draws no glyph of the program
//!
//! It reads the header, the Name, Top DICT and String INDEXes, the Top DICT's charset, Encoding
//! and CharStrings, the charset (ISOAdobe, or formats 0 to 2) and the encoding (Standard, or
//! formats 0 and 1, with supplements). A code maps to a name only when the program has a glyph for
//! it: Standard encoding's name for a code whose glyph a subset dropped is not given. null, never
//! an error, for a program this does not read: a CID-keyed one (it has no encoding), the Expert
//! charset or encoding (no table here), or bytes that do not parse. The caller then has no base
//! encoding, and those codes have no character, which is counted, not guessed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("read_tables.zig");

const Index = struct {
    count: u32,
    off_size: u8,
    /// Where the offset array starts.
    offsets_at: usize,
    /// Where the data starts, minus 1 (offsets count from 1).
    data_at: usize,
    /// Just past the INDEX.
    end: usize,

    fn read(d: []const u8, at: usize) ?Index {
        if (at + 2 > d.len) return null;
        const count = std.mem.readInt(u16, d[at..][0..2], .big);
        if (count == 0) return .{ .count = 0, .off_size = 0, .offsets_at = at + 2, .data_at = at + 2, .end = at + 2 };
        if (at + 3 > d.len) return null;
        const off_size = d[at + 2];
        if (off_size < 1 or off_size > 4) return null;
        const offsets_at = at + 3;
        const data_at = offsets_at + (@as(usize, count) + 1) * off_size - 1;
        var idx: Index = .{ .count = count, .off_size = off_size, .offsets_at = offsets_at, .data_at = data_at, .end = 0 };
        const last = idx.offset(d, count) orelse return null;
        idx.end = data_at + last;
        if (idx.end > d.len) return null;
        return idx;
    }

    fn offset(self: Index, d: []const u8, i: usize) ?usize {
        const at = self.offsets_at + i * self.off_size;
        if (at + self.off_size > d.len) return null;
        const v = std.mem.readVarInt(u32, d[at..][0..self.off_size], .big);
        if (v < 1) return null;
        return v;
    }

    fn item(self: Index, d: []const u8, i: usize) ?[]const u8 {
        if (i >= self.count) return null;
        const lo = self.offset(d, i) orelse return null;
        const hi = self.offset(d, i + 1) orelse return null;
        if (hi < lo or self.data_at + hi > d.len) return null;
        return d[self.data_at + lo .. self.data_at + hi];
    }
};

/// The Top DICT entries this reads; offsets are from the program's start.
const TopDict = struct {
    charset: u32 = 0,
    encoding: u32 = 0,
    char_strings: ?u32 = null,
    cid_keyed: bool = false,
};

fn readTopDict(dict: []const u8) ?TopDict {
    var top: TopDict = .{};
    var operands: [48]i64 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < dict.len) {
        const b0 = dict[i];
        if (b0 <= 21) {
            var op: u16 = b0;
            i += 1;
            if (b0 == 12) {
                if (i >= dict.len) return null;
                op = 0x0C00 | @as(u16, dict[i]);
                i += 1;
            }
            const last: ?i64 = if (n > 0) operands[n - 1] else null;
            switch (op) {
                15 => top.charset = std.math.cast(u32, last orelse return null) orelse return null,
                16 => top.encoding = std.math.cast(u32, last orelse return null) orelse return null,
                17 => top.char_strings = std.math.cast(u32, last orelse return null) orelse return null,
                0x0C1E => top.cid_keyed = true, // ROS
                else => {},
            }
            n = 0;
            continue;
        }
        // An operand (TN 5176, Table 3); a real (30) counts as 0, as no entry read here is one.
        var v: i64 = 0;
        switch (b0) {
            28 => {
                if (i + 3 > dict.len) return null;
                v = std.mem.readInt(i16, dict[i + 1 ..][0..2], .big);
                i += 3;
            },
            29 => {
                if (i + 5 > dict.len) return null;
                v = std.mem.readInt(i32, dict[i + 1 ..][0..4], .big);
                i += 5;
            },
            30 => {
                i += 1;
                while (i < dict.len) : (i += 1) {
                    if (dict[i] & 0x0F == 0x0F or dict[i] >> 4 == 0x0F) break;
                }
                i += 1;
            },
            32...246 => {
                v = @as(i64, b0) - 139;
                i += 1;
            },
            247...250 => {
                if (i + 2 > dict.len) return null;
                v = (@as(i64, b0) - 247) * 256 + dict[i + 1] + 108;
                i += 2;
            },
            251...254 => {
                if (i + 2 > dict.len) return null;
                v = -(@as(i64, b0) - 251) * 256 - dict[i + 1] - 108;
                i += 2;
            },
            else => return null,
        }
        if (n == operands.len) return null;
        operands[n] = v;
        n += 1;
    }
    return top;
}

/// The glyph name of each code of the program's built-in encoding; null when none is read (the
/// module doc says when). A name is a slice of `d` or of a static table; `a` holds working memory
/// only.
pub fn builtinEncoding(a: Allocator, d: []const u8) Allocator.Error!?[256]?[]const u8 {
    if (d.len < 4 or d[0] != 1) return null;
    const names_index = Index.read(d, d[2]) orelse return null;
    const top_index = Index.read(d, names_index.end) orelse return null;
    const strings = Index.read(d, top_index.end) orelse return null;
    const top = readTopDict(top_index.item(d, 0) orelse return null) orelse return null;
    if (top.cid_keyed) return null;
    const char_strings = Index.read(d, top.char_strings orelse return null) orelse return null;
    const glyphs = char_strings.count;
    if (glyphs == 0) return null;

    // The SID of each glyph.
    const sids = try a.alloc(u16, glyphs);
    sids[0] = 0;
    switch (top.charset) {
        // ISOAdobe: glyph i is SID i, for SIDs up to 228.
        0 => {
            if (glyphs > 229) return null;
            for (sids, 0..) |*s, gid| s.* = @intCast(gid);
        },
        1, 2 => return null,
        else => if (!readCharset(d, top.charset, sids)) return null,
    }

    var names: [256]?[]const u8 = @splat(null);
    switch (top.encoding) {
        // Standard: a code names its glyph by StandardEncoding, if the program has a glyph by that
        // name.
        0 => {
            var present: std.StringHashMapUnmanaged(void) = .empty;
            for (sids) |sid| if (sidName(d, strings, sid)) |n| try present.put(a, n, {});
            for (0..256) |c| {
                const want = tables.standard_encoding[c] orelse continue;
                if (present.contains(want)) names[c] = want;
            }
        },
        1 => return null,
        else => {
            const at: usize = top.encoding;
            if (at >= d.len) return null;
            const format = d[at];
            var gid: usize = 1;
            switch (format & 0x7F) {
                0 => {
                    if (at + 2 > d.len) return null;
                    const n = d[at + 1];
                    if (at + 2 + n > d.len) return null;
                    for (d[at + 2 ..][0..n]) |code| {
                        if (gid >= glyphs) return null;
                        names[code] = sidName(d, strings, sids[gid]);
                        gid += 1;
                    }
                    if (format & 0x80 != 0) if (!supplements(d, at + 2 + n, strings, &names)) return null;
                },
                1 => {
                    if (at + 2 > d.len) return null;
                    const n = d[at + 1];
                    if (at + 2 + @as(usize, n) * 2 > d.len) return null;
                    for (0..n) |k| {
                        const first = d[at + 2 + k * 2];
                        const left = d[at + 3 + k * 2];
                        for (0..@as(usize, left) + 1) |j| {
                            const code = @as(usize, first) + j;
                            if (code > 255 or gid >= glyphs) return null;
                            names[code] = sidName(d, strings, sids[gid]);
                            gid += 1;
                        }
                    }
                    if (format & 0x80 != 0) if (!supplements(d, at + 2 + @as(usize, n) * 2, strings, &names)) return null;
                },
                else => return null,
            }
        },
    }
    return names;
}

/// A custom charset at `at` (formats 0, 1, 2): the SID of glyphs 1 and up, into sids[1..].
fn readCharset(d: []const u8, at: usize, sids: []u16) bool {
    if (at >= d.len) return false;
    var gid: usize = 1;
    var p = at + 1;
    switch (d[at]) {
        0 => while (gid < sids.len) : (gid += 1) {
            if (p + 2 > d.len) return false;
            sids[gid] = std.mem.readInt(u16, d[p..][0..2], .big);
            p += 2;
        },
        1, 2 => while (gid < sids.len) {
            const left_len: usize = if (d[at] == 1) 1 else 2;
            if (p + 2 + left_len > d.len) return false;
            const first = std.mem.readInt(u16, d[p..][0..2], .big);
            const left: usize = std.mem.readVarInt(u16, d[p + 2 ..][0..left_len], .big);
            p += 2 + left_len;
            for (0..left + 1) |j| {
                if (gid >= sids.len) break;
                sids[gid] = std.math.cast(u16, @as(usize, first) + j) orelse return false;
                gid += 1;
            }
        },
        else => return false,
    }
    return true;
}

/// An encoding's supplements at `at`: codes that also name a glyph, by SID.
fn supplements(d: []const u8, at: usize, strings: Index, names: *[256]?[]const u8) bool {
    if (at >= d.len) return false;
    const n = d[at];
    if (at + 1 + @as(usize, n) * 3 > d.len) return false;
    for (0..n) |k| {
        const p = at + 1 + k * 3;
        names[d[p]] = sidName(d, strings, std.mem.readInt(u16, d[p + 1 ..][0..2], .big));
    }
    return true;
}

fn sidName(d: []const u8, strings: Index, sid: u16) ?[]const u8 {
    if (sid < tables.cff_standard_strings.len) return tables.cff_standard_strings[sid];
    return strings.item(d, sid - tables.cff_standard_strings.len);
}

// ---- tests ----

const testing = std.testing;

test "each fixture's encoding reads as fontTools reads it back (tools/cff-fixtures.py)" {
    const gpa = testing.allocator;
    const dir = @import("build_options").read_fixtures;
    var checked: usize = 0;
    for ([_][]const u8{ "isoadobe-standard", "subset-standard", "custom-scattered", "custom-runs", "custom-long-charset" }) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: [512]u8 = undefined;
        const program = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.bufPrint(&buf, "{s}/cff/{s}.cff", .{ dir, name }), a, .limited(1 << 20));
        const json = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.bufPrint(&buf, "{s}/cff/{s}.json", .{ dir, name }), a, .limited(1 << 20));
        const want = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, json, .{});
        const got = (try builtinEncoding(a, program)) orelse return error.TestUnexpectedResult;
        for (0..256) |c| {
            const key = try std.fmt.allocPrint(a, "{d}", .{c});
            const expect = want.map.get(key);
            if (expect) |e| {
                try testing.expectEqualStrings(e, got[c] orelse return error.TestUnexpectedResult);
                checked += 1;
            } else try testing.expectEqual(@as(?[]const u8, null), got[c]);
        }
    }
    try testing.expectEqual(@as(usize, 59 + 5 + 4 + 20 + 199), checked);
}

/// A CFF program put together by hand: one glyph per name after .notdef, `top_extra` added to the
/// Top DICT, and `encoding` (if any) written at the end.
fn handMade(a: Allocator, sids: []const u16, encoding: ?[]const u8, top_extra: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 1, 0, 4, 1 }); // header
    try out.appendSlice(a, &.{ 0, 1, 1, 1, 2, 'A' }); // Name INDEX
    // Top DICT: charset, CharStrings and Encoding offsets as 5-byte integers (29), filled below.
    const top_len: u8 = @intCast(18 + top_extra.len);
    try out.appendSlice(a, &.{ 0, 1, 1, 1, 1 + top_len });
    const top_at = out.items.len;
    try out.appendNTimes(a, 0, 18);
    try out.appendSlice(a, top_extra);
    try out.appendSlice(a, &.{ 0, 0, 0, 0 }); // String INDEX and Global Subr INDEX, both empty
    const char_strings_at = out.items.len;
    const n: u16 = @intCast(sids.len + 1);
    try out.appendSlice(a, &.{ @intCast(n >> 8), @intCast(n & 0xFF), 1 });
    for (0..n + 1) |i| try out.append(a, @intCast(i + 1));
    try out.appendNTimes(a, 14, n); // endchar
    const charset_at = out.items.len;
    try out.append(a, 0);
    for (sids) |s| try out.appendSlice(a, &.{ @intCast(s >> 8), @intCast(s & 0xFF) });
    const encoding_at = out.items.len;
    if (encoding) |e| try out.appendSlice(a, e);
    for ([_]struct { usize, u8 }{ .{ charset_at, 15 }, .{ char_strings_at, 17 }, .{ if (encoding != null) encoding_at else 0, 16 } }, 0..) |entry, k| {
        const at = top_at + k * 6;
        out.items[at] = 29;
        std.mem.writeInt(i32, out.items[at + 1 ..][0..4], @intCast(entry[0]), .big);
        out.items[at + 5] = entry[1];
    }
    return out.items;
}

test "a supplement names a second code for a glyph; CID-keyed and damaged programs give null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Glyphs A (SID 34) and B (SID 35); encoding format 0 with supplements: 65 is A, 66 is B, and
    // 97 is A again.
    const p = try handMade(a, &.{ 34, 35 }, &.{ 0x80, 2, 65, 66, 1, 97, 0, 34 }, &.{});
    const names = (try builtinEncoding(a, p)).?;
    try testing.expectEqualStrings("A", names[65].?);
    try testing.expectEqualStrings("B", names[66].?);
    try testing.expectEqualStrings("A", names[97].?);
    try testing.expectEqual(@as(?[]const u8, null), names[67]);
    // Standard encoding (offset 0) over the same glyphs: A and B only.
    const std_names = (try builtinEncoding(a, try handMade(a, &.{ 34, 35 }, null, &.{}))).?;
    try testing.expectEqualStrings("A", std_names[65].?);
    try testing.expectEqual(@as(?[]const u8, null), std_names[67]);
    // ROS (12 30) makes it CID-keyed: no encoding.
    try testing.expectEqual(@as(?[256]?[]const u8, null), try builtinEncoding(a, try handMade(a, &.{ 34, 35 }, null, &.{ 139, 139, 139, 12, 30 })));
    // Every prefix of the program is refused or read, never a crash or an error.
    for (0..p.len) |len| _ = try builtinEncoding(a, p[0..len]);
    // An encoding that names more codes than there are glyphs is refused.
    try testing.expectEqual(@as(?[256]?[]const u8, null), try builtinEncoding(a, try handMade(a, &.{34}, &.{ 0, 2, 65, 66 }, &.{})));
}

test "Top DICT operands: each integer form at its bounds (TN 5176, Table 3)" {
    // Each operand, then the charset operator (15), which takes it as an offset.
    const cases = [_]struct { bytes: []const u8, want: u32 }{
        .{ .bytes = &.{ 139, 15 }, .want = 0 },
        .{ .bytes = &.{ 246, 15 }, .want = 107 },
        .{ .bytes = &.{ 247, 0, 15 }, .want = 108 },
        .{ .bytes = &.{ 250, 255, 15 }, .want = 1131 },
        .{ .bytes = &.{ 28, 0x27, 0x10, 15 }, .want = 10000 },
        .{ .bytes = &.{ 29, 0x00, 0x01, 0x86, 0xA0, 15 }, .want = 100000 },
        // A real is skipped whole: the integer after it is the operand.
        .{ .bytes = &.{ 30, 0x1A, 0x5F, 139, 15 }, .want = 0 },
    };
    for (cases) |c| try testing.expectEqual(c.want, readTopDict(c.bytes).?.charset);
    // Negative forms are not offsets.
    try testing.expectEqual(@as(?TopDict, null), readTopDict(&.{ 251, 0, 15 }));
    try testing.expectEqual(@as(?TopDict, null), readTopDict(&.{ 254, 255, 15 }));
}
