//! zpdf.read's text: the text a page draws, as runs with positions (Reader.pageText).
//!
//! A run is one text-showing operator (Tj, TJ, ' or "), as drawn: its text in Unicode, where its
//! first glyph's origin is (after any TJ adjustment before it), its size and its advance. An
//! operator that shows no glyph makes no run. The glyphs inside a marked-content span with
//! /ActualText make one run whose text is the ActualText. Runs come in content-stream order, which
//! is not always reading order: readers that agree on the text disagree on its order (MuPDF
//! keeps content order, Poppler sorts by position), so ordering is left to the caller. No space
//! is invented between runs or for a large TJ gap; the caller decides what a gap means.
//!
//! Coordinates are default user space: points, y up, the page's own origin (a MediaBox need not
//! start at 0, 0), before /Rotate. Form XObjects are drawn into the page with their /Matrix.
//!
//! Characters come from the font's /ToUnicode CMap when it has one, else from its encoding
//! (/Encoding, /Differences, the Adobe Glyph List for glyph names, WinAnsi, MacRoman, Standard).
//! A Type0 font whose CIDFont has an Adobe character collection (Japan1, GB1, CNS1, Korea1, KR)
//! maps a code /ToUnicode does not have through Adobe's CID-to-Unicode CMap for that collection
//! (9.10.2; src/cid, compiled to a CidTable at build time). A code with none of these is U+FFFD
//! in the text and counted in `unmapped`. Widths come from
//! /Widths or /W, and for the 14 standard fonts with no /Widths from Adobe's AFM metrics
//! (read_tables.zig).
//!
//! Refused: a Type0 font whose /Encoding is not Identity-H (error.UnsupportedFont: without its
//! CMap the codes cannot even be split into characters), and anything zpdf.read refuses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const read = @import("read.zig");
const tables = @import("read_tables.zig");
const winansi = @import("winansi.zig");
const Reader = read.Reader;
const Object = read.Object;
const Dict = read.Dict;
const Error = read.Error;

pub const TextRun = struct {
    /// UTF-8.
    text: []const u8,
    /// The origin of the run's first glyph, in default user space.
    x: f64,
    y: f64,
    /// The text's height in user space: the font size scaled by the text and current matrices.
    size: f64,
    /// From the first glyph's origin to where the next glyph would start, in user space. null
    /// when a glyph's width is unknown (a font with no width for one of its codes).
    width: ?f64,
    /// The font's /BaseFont, or "" when it has none.
    font: []const u8,
    /// Codes with no Unicode mapping; each is U+FFFD in `text`.
    unmapped: u32,
    /// Each glyph's origin, in default user space, in drawing order.
    glyphs: []const Glyph,
    /// The text is a marked-content span's /ActualText (14.9.4), which replaces what its glyphs
    /// map to; the run covers every glyph drawn inside the span. zpdf writes one around each
    /// cluster whose glyphs are not in text order (Indic reordering, marks).
    actual_text: bool,
};

pub const Glyph = struct {
    x: f64,
    y: f64,
    /// Where this glyph's characters start in the run's text (bytes). In an ActualText run the
    /// text is not per glyph, and this is 0 for every glyph.
    text_at: u32,
};

/// One page's runs. Owns all their memory: deinit frees it.
pub const PageText = struct {
    arena: std.heap.ArenaAllocator,
    runs: []const TextRun,
    /// ActualText spans that drew no glyph (14.9.4 lets one stand for an image or a path).
    /// Their text has no glyph to place it by, so it is not in `runs`; this says it was there.
    unplaced_actual_text: u32,

    pub fn deinit(self: *PageText) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// [a b c d e f]: a point (x, y) maps to (a x + c y + e, b x + d y + f) (ISO 32000-1 8.3.4).
const Matrix = [6]f64;
const identity: Matrix = .{ 1, 0, 0, 1, 0, 0 };

/// m then n: the matrix of applying m first.
fn mul(m: Matrix, n: Matrix) Matrix {
    return .{
        m[0] * n[0] + m[1] * n[2],
        m[0] * n[1] + m[1] * n[3],
        m[2] * n[0] + m[3] * n[2],
        m[2] * n[1] + m[3] * n[3],
        m[4] * n[0] + m[5] * n[2] + n[4],
        m[4] * n[1] + m[5] * n[3] + n[5],
    };
}

/// A font as text extraction needs it. Lives in the reader's arena, cached by object number.
pub const Font = struct {
    base_font: []const u8,
    /// Two-byte codes (Type0 with Identity-H); else one byte.
    two_byte: bool,
    to_unicode: ?CMap,
    /// Type0 with an Adobe character collection: Adobe's CID-to-Unicode table for it, static
    /// data built from src/cid. With Identity-H the code is the CID.
    cid_unicode: ?CidTable,
    /// Simple fonts: the characters of each code from the encoding (null: none).
    encoding: [256]?[]const u21,
    /// Simple fonts: width in 1/1000 text space units per code, from /Widths or the standard
    /// font metrics (null: unknown).
    simple_widths: [256]?f64,
    /// Type0: /W, as sorted ranges, and /DW.
    cid_widths: []const CidRange,
    default_width: f64,

    const CidRange = struct { first: u32, last: u32, widths: []const f64 };

    fn width(self: *const Font, code: u32) ?f64 {
        if (!self.two_byte) return self.simple_widths[code];
        var lo: usize = 0;
        var hi: usize = self.cid_widths.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = self.cid_widths[mid];
            if (code < r.first) {
                hi = mid;
            } else if (code > r.last) {
                lo = mid + 1;
            } else return if (r.widths.len == 1) r.widths[0] else r.widths[code - r.first];
        }
        return self.default_width;
    }

    fn unicode(self: *const Font, code: u32, code_len: u8, buf: *[max_chars]u21) ?[]const u21 {
        if (self.to_unicode) |cm| {
            if (cm.lookup(code, code_len, buf)) |u| return u;
        }
        if (!self.two_byte) return self.encoding[code];
        // Comptime-false in zpdf.wasm, so the lookup is not compiled there.
        if (cid_tables) if (self.cid_unicode) |t| return t.lookup(code, buf);
        return null;
    }
};

/// The most characters one CMap destination may have. Real ones are a few (a ligature's); a
/// longer one is refused as UnsupportedFont rather than dropped, so a text never silently loses
/// it, and the bound keeps a small file from making a page's text huge.
const max_chars = 32;
/// The most ranges of more than 256 codes a CMap may have: each is scanned per code looked up.
const max_large_ranges = 4096;

/// A ToUnicode CMap's mappings (9.10.3): single codes and ranges, by code and code length, each
/// with the order it was defined in, since a later definition of a code replaces an earlier one.
pub const CMap = struct {
    chars: std.AutoHashMapUnmanaged(u64, Mapping) = .empty,
    ranges: []const Range = &.{},

    const Mapping = struct { seq: u32, chars: []const u21 };
    const Range = struct { lo: u32, hi: u32, len: u8, seq: u32, kind: union(enum) { start: []const u21, list: []const []const u21 } };

    fn key(code: u32, len: u8) u64 {
        return (@as(u64, len) << 32) | code;
    }

    /// The characters of `code`, from its latest definition; a range's are computed into `buf`.
    pub fn lookup(self: *const CMap, code: u32, len: u8, buf: *[max_chars]u21) ?[]const u21 {
        const single = self.chars.get(key(code, len));
        // The latest range holding the code: ranges are kept in definition order.
        var i = self.ranges.len;
        const range: ?Range = while (i > 0) {
            i -= 1;
            const r = self.ranges[i];
            if (r.len == len and code >= r.lo and code <= r.hi) break r;
        } else null;
        if (single) |s| {
            if (range == null or s.seq > range.?.seq) return s.chars;
        }
        const r = range orelse return null;
        switch (r.kind) {
            .list => |l| return if (code - r.lo < l.len) l[code - r.lo] else null,
            .start => |s| {
                // The last code point is raised by the code's offset in the range (9.10.3).
                const last = @as(u32, s[s.len - 1]) + (code - r.lo);
                if (last > 0x10FFFF) return null;
                @memcpy(buf[0..s.len], s);
                buf[s.len - 1] = @intCast(last);
                return buf[0..s.len];
            },
        }
    }
};

/// Parses a ToUnicode CMap stream into `arena` (its results are not single allocations). Tokens
/// live until their operator is done, in an arena on `gpa` that is reset after each one, so a
/// large CMap (Adobe's CID-to-Unicode ones are 150 to 300 KB) leaves only its mappings.
/// Unknown operators (begincodespacerange, usecmap...) are skipped: codes only an inherited CMap
/// maps stay unmapped, and are counted as such. bfchar and bfrange are read.
fn parseCMap(arena: Allocator, gpa: Allocator, data: []const u8, max_depth: u32) Error!CMap {
    const a = arena;
    var tokens: std.heap.ArenaAllocator = .init(gpa);
    defer tokens.deinit();
    const t_a = tokens.allocator();
    var cm: CMap = .{};
    var ranges: std.ArrayList(CMap.Range) = .empty;
    var seq: u32 = 0;
    var lx: read.Lexer = .{ .src = data, .pos = 0 };
    var operands: std.ArrayList(Object) = .empty;
    defer operands.deinit(gpa);
    var p: read.Parser = .{ .lx = &lx, .arena = t_a, .max_depth = max_depth };
    while (true) {
        const before = lx.pos;
        const t = lx.next(t_a) catch |err| switch (err) {
            // PostScript procedures in a CMap header ({ } blocks) are not PDF syntax; skip them.
            // A refusal that did not move on would repeat forever.
            error.Malformed => {
                if (lx.pos == before) lx.pos += 1;
                continue;
            },
            else => return err,
        };
        switch (t) {
            .eof => break,
            .keyword => |k| {
                if (std.mem.eql(u8, k, "endbfchar")) {
                    var i: usize = 0;
                    while (i + 1 < operands.items.len) : (i += 2) {
                        const src = stringOf(operands.items[i]) orelse continue;
                        const dst = stringOf(operands.items[i + 1]) orelse continue;
                        if (src.len == 0 or src.len > 4) continue;
                        const chars = try utf16be(a, dst);
                        if (chars.len > max_chars) return error.UnsupportedFont;
                        seq += 1;
                        try cm.chars.put(a, CMap.key(std.mem.readVarInt(u32, src, .big), @intCast(src.len)), .{ .seq = seq, .chars = chars });
                    }
                } else if (std.mem.eql(u8, k, "endbfrange")) {
                    var i: usize = 0;
                    while (i + 2 < operands.items.len) : (i += 3) {
                        const lo_s = stringOf(operands.items[i]) orelse continue;
                        const hi_s = stringOf(operands.items[i + 1]) orelse continue;
                        if (lo_s.len == 0 or lo_s.len > 4 or hi_s.len != lo_s.len) continue;
                        const lo = std.mem.readVarInt(u32, lo_s, .big);
                        const hi = std.mem.readVarInt(u32, hi_s, .big);
                        if (hi < lo) continue;
                        seq += 1;
                        switch (operands.items[i + 2]) {
                            .string => |s| {
                                const start = try utf16be(a, s);
                                if (start.len == 0) continue;
                                if (start.len > max_chars) return error.UnsupportedFont;
                                // Small ranges become single entries; a large one (an identity
                                // <0000> <FFFF> range is common) is computed at lookup. The
                                // offset is counted, not the code, which can be 0xFFFFFFFF.
                                if (hi - lo < 256) {
                                    var off: u32 = 0;
                                    while (off <= hi - lo) : (off += 1) {
                                        const last = @as(u32, start[start.len - 1]) + off;
                                        if (last > 0x10FFFF) break;
                                        const u = try a.dupe(u21, start);
                                        u[u.len - 1] = @intCast(last);
                                        try cm.chars.put(a, CMap.key(lo + off, @intCast(lo_s.len)), .{ .seq = seq, .chars = u });
                                    }
                                } else {
                                    if (ranges.items.len >= max_large_ranges) return error.TooLarge;
                                    try ranges.append(a, .{ .lo = lo, .hi = hi, .len = @intCast(lo_s.len), .seq = seq, .kind = .{ .start = start } });
                                }
                            },
                            .array => |arr| {
                                var list = try a.alloc([]const u21, arr.len);
                                for (arr, 0..) |d, j| {
                                    list[j] = if (stringOf(d)) |s| try utf16be(a, s) else &.{};
                                    if (list[j].len > max_chars) return error.UnsupportedFont;
                                }
                                if (ranges.items.len >= max_large_ranges) return error.TooLarge;
                                try ranges.append(a, .{ .lo = lo, .hi = hi, .len = @intCast(lo_s.len), .seq = seq, .kind = .{ .list = list } });
                            },
                            else => {},
                        }
                    }
                }
                operands.clearRetainingCapacity();
                _ = tokens.reset(.retain_capacity);
            },
            else => {
                if (operands.items.len >= 1 << 16) return error.TooLarge;
                try operands.append(gpa, p.fromToken(t, 0) catch |err| switch (err) {
                    error.Malformed => continue,
                    else => return err,
                });
            },
        }
    }
    cm.ranges = ranges.items;
    return cm;
}

fn stringOf(o: Object) ?[]const u8 {
    return if (o == .string) o.string else null;
}

/// UTF-16BE to code points; an unpaired surrogate half is kept (it becomes U+FFFD when written
/// through appendUtf8). Into `arena`: the result
/// is a list's items, not a single allocation a caller could free.
fn utf16be(arena: Allocator, bytes: []const u8) Error![]const u21 {
    const a = arena;
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const u = std.mem.readInt(u16, bytes[i..][0..2], .big);
        if (std.unicode.utf16IsHighSurrogate(u) and i + 3 < bytes.len) {
            const pair = [2]u16{ u, std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big) };
            if (std.unicode.utf16DecodeSurrogatePair(&pair)) |cp| {
                try out.append(a, cp);
                i += 2;
                continue;
            } else |_| {}
        }
        // A lone half is kept as it is: appendUtf8, which every caller writes through, turns
        // it into U+FFFD.
        try out.append(a, u);
    }
    return out.items;
}

/// The characters a glyph name stands for: the Adobe Glyph List, then uniXXXX (one or more
/// groups of four), uXXXX to uXXXXXX, then ligatures (a_b) and variants (a.sc) by their parts.
/// Into `arena`: the result is a list's items, and parts of a failed name are left there.
fn glyphNameChars(arena: Allocator, name: []const u8, depth: u32) Error!?[]const u21 {
    const a = arena;
    if (depth > 4) return null;
    if (aglLookup(name)) |cp| return try a.dupe(u21, &.{cp});
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        if (dot == 0) return null;
        return glyphNameChars(a, name[0..dot], depth + 1);
    }
    if (std.mem.indexOfScalar(u8, name, '_') != null) {
        var out: std.ArrayList(u21) = .empty;
        var parts = std.mem.splitScalar(u8, name, '_');
        while (parts.next()) |part| {
            const u = (try glyphNameChars(a, part, depth + 1)) orelse return null;
            try out.appendSlice(a, u);
        }
        return out.items;
    }
    if (std.mem.startsWith(u8, name, "uni") and name.len >= 7 and (name.len - 3) % 4 == 0) {
        var out: std.ArrayList(u21) = .empty;
        var i: usize = 3;
        while (i < name.len) : (i += 4) {
            if (!isUpperHex(name[i .. i + 4])) return null;
            const v = std.fmt.parseInt(u21, name[i .. i + 4], 16) catch return null;
            if (!std.unicode.utf8ValidCodepoint(v)) return null;
            try out.append(a, v);
        }
        return out.items;
    }
    if (name.len >= 5 and name.len <= 7 and name[0] == 'u' and isUpperHex(name[1..])) {
        const v = std.fmt.parseInt(u21, name[1..], 16) catch return null;
        if (!std.unicode.utf8ValidCodepoint(v)) return null;
        return try a.dupe(u21, &.{v});
    }
    return null;
}

fn isUpperHex(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isDigit(c) or (std.ascii.isHex(c) and std.ascii.isUpper(c)))) return false;
    return s.len > 0;
}

fn aglLookup(name: []const u8) ?u21 {
    var lo: usize = 0;
    var hi: usize = tables.glyph_names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, tables.glyph_names[mid].name, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return tables.glyph_names[mid].cp,
        }
    }
    return null;
}

/// The standard font a /BaseFont names: the 14 names, a subset tag (ABCDEF+) removed, and the
/// Arial, Times New Roman and Courier New names some writers use for them.
const StandardMetrics = union(enum) {
    text: []const tables.CodePointWidth,
    symbolic: *const @TypeOf(tables.symbolic_fonts[0]),
};

fn standardMetrics(base_font: []const u8) ?StandardMetrics {
    var name = base_font;
    if (name.len > 7 and name[6] == '+') name = name[7..];
    const aliases = [_][2][]const u8{
        .{ "Arial", "Helvetica" },                   .{ "Arial,Bold", "Helvetica-Bold" },
        .{ "Arial,Italic", "Helvetica-Oblique" },    .{ "Arial,BoldItalic", "Helvetica-BoldOblique" },
        .{ "ArialMT", "Helvetica" },                 .{ "Arial-BoldMT", "Helvetica-Bold" },
        .{ "Arial-ItalicMT", "Helvetica-Oblique" },  .{ "Arial-BoldItalicMT", "Helvetica-BoldOblique" },
        .{ "TimesNewRoman", "Times-Roman" },         .{ "TimesNewRoman,Bold", "Times-Bold" },
        .{ "TimesNewRoman,Italic", "Times-Italic" }, .{ "TimesNewRoman,BoldItalic", "Times-BoldItalic" },
        .{ "TimesNewRomanPSMT", "Times-Roman" },     .{ "CourierNew", "Courier" },
        .{ "CourierNew,Bold", "Courier-Bold" },      .{ "CourierNewPSMT", "Courier" },
    };
    for (aliases) |al| {
        if (std.mem.eql(u8, name, al[0])) name = al[1];
    }
    for (&tables.text_font_widths) |*f| {
        if (std.mem.eql(u8, f.name, name)) return .{ .text = f.widths };
    }
    for (&tables.symbolic_fonts) |*f| {
        if (std.mem.eql(u8, f.name, name)) return .{ .symbolic = f };
    }
    return null;
}

fn symbolicWidth(s: *const @TypeOf(tables.symbolic_fonts[0]), name: []const u8) ?u16 {
    for (s.names, s.widths) |n, w| {
        if (n) |glyph| if (std.mem.eql(u8, glyph, name)) return w;
    }
    return null;
}

fn textWidth(widths: []const tables.CodePointWidth, cp: u21) ?f64 {
    var lo: usize = 0;
    var hi: usize = widths.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (widths[mid].cp < cp) {
            lo = mid + 1;
        } else if (widths[mid].cp > cp) {
            hi = mid;
        } else return @floatFromInt(widths[mid].width);
    }
    return null;
}

/// Font `ref` (a font dictionary, usually a reference), parsed once per reader.
pub fn loadFont(r: *Reader, ref: Object) Error!*const Font {
    if (ref == .ref) {
        if (r.fonts.get(ref.ref.num)) |f| return f;
    }
    const a = r.arenaAllocator();
    const dict = switch (try r.resolve(ref)) {
        .dict => |d| d,
        else => return error.Malformed,
    };
    const f = try a.create(Font);
    f.* = .{
        .base_font = if (try r.getResolved(dict, "BaseFont")) |b| (if (b == .name) b.name else "") else "",
        .two_byte = false,
        .to_unicode = null,
        .cid_unicode = null,
        .encoding = @splat(null),
        .simple_widths = @splat(null),
        .cid_widths = &.{},
        .default_width = 1000,
    };
    if (try r.getResolved(dict, "ToUnicode")) |tu| switch (tu) {
        .stream => |s| f.to_unicode = try parseCMap(a, r.arena_state.child_allocator, try r.streamData(s), r.options.max_depth),
        // /ToUnicode /Identity-H and other names are not mappings.
        else => {},
    };
    const subtype = if (try r.getResolved(dict, "Subtype")) |s| (if (s == .name) s.name else "") else "";
    if (std.mem.eql(u8, subtype, "Type0")) {
        try loadType0(r, f, dict);
    } else {
        try loadSimple(r, f, dict, std.mem.eql(u8, subtype, "Type3"));
    }
    if (ref == .ref) try r.fonts.put(a, ref.ref.num, f);
    return f;
}

/// The character collections src/cid has Adobe's CID-to-Unicode CMap for. build.zig compiles
/// src/cid/Adobe-<ordering>-UCS2 to a CidTable, the import "cid_<ordering>", in this order.
pub const cid_orderings = [_][]const u8{ "Japan1", "GB1", "CNS1", "Korea1", "KR" };

/// False in zpdf.wasm (build.zig, addCidMaps): its CID fonts with a collection read as unmapped.
const cid_tables = @import("read_options").cid_tables;

const cid_table_data = if (cid_tables) blk: {
    var data: [cid_orderings.len][]const u8 = undefined;
    for (cid_orderings, &data) |ordering, *d| d.* = @embedFile("cid_" ++ ordering);
    break :blk data;
} else undefined;

/// A CID-to-Unicode map compiled at build time (tools/gen-cid-table.zig), read in place: a
/// lookup allocates nothing, and the data is the binary's, so a file that uses it costs nothing.
///
/// Format, little-endian, at no particular alignment:
///   u32 run_count, u32 multi_count, u32 pool_len
///   run_count runs {u16 first_cid, u16 count, u32 first_cp}: CID first_cid + i is the one code
///     point first_cp + i, for i below count. Sorted by first_cid, not overlapping.
///   multi_count multis {u16 cid, u16 len, u32 pool_at}: a CID that is len code points, from
///     the pool. Sorted by cid; no CID is in both.
///   pool_len u32 code points.
/// It holds exactly what CMap.lookup gives for each two-byte code of the source CMap
/// (encodeCidTable asks it for every one).
pub const CidTable = struct {
    bytes: []const u8,

    const header_len = 12;
    const record_len = 8;

    fn int(self: CidTable, comptime T: type, at: usize) T {
        return std.mem.readInt(T, self.bytes[at..][0..@sizeOf(T)], .little);
    }

    /// The code points of `cid`, in `buf` (or null when the table has none).
    pub fn lookup(self: CidTable, cid: u32, buf: *[max_chars]u21) ?[]const u21 {
        const runs = self.int(u32, 0);
        const multis = self.int(u32, 4);
        // The last run starting at or before cid.
        var lo: usize = 0;
        var hi: usize = runs;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.int(u16, header_len + mid * record_len) <= cid) lo = mid + 1 else hi = mid;
        }
        if (lo > 0) {
            const at = header_len + (lo - 1) * record_len;
            const first = self.int(u16, at);
            if (cid - first < self.int(u16, at + 2)) {
                buf[0] = @intCast(self.int(u32, at + 4) + (cid - first));
                return buf[0..1];
            }
        }
        const multis_at = header_len + runs * record_len;
        lo = 0;
        hi = multis;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const at = multis_at + mid * record_len;
            const c = self.int(u16, at);
            if (c == cid) {
                const len = self.int(u16, at + 2);
                const pool_at = multis_at + multis * record_len + @as(usize, self.int(u32, at + 4)) * 4;
                for (buf[0..len], 0..) |*cp, k| cp.* = @intCast(self.int(u32, pool_at + k * 4));
                return buf[0..len];
            }
            if (c < cid) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// Compiles a CID-to-Unicode CMap (bfchar/bfrange over two-byte codes) to a CidTable's bytes,
/// owned by `gpa`. Run at build time by tools/gen-cid-table.zig.
pub fn encodeCidTable(gpa: Allocator, cmap_text: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cm = try parseCMap(a, gpa, cmap_text, 64);
    const Run = struct { first: u16, count: u16, cp: u32 };
    const Multi = struct { cid: u16, len: u16, at: u32 };
    var runs: std.ArrayList(Run) = .empty;
    var multis: std.ArrayList(Multi) = .empty;
    var pool: std.ArrayList(u32) = .empty;
    var buf: [max_chars]u21 = undefined;
    for (0..0x10000) |i| {
        const cid: u16 = @intCast(i);
        const chars = cm.lookup(cid, 2, &buf) orelse continue;
        if (chars.len == 1) {
            if (runs.items.len > 0) {
                const last = &runs.items[runs.items.len - 1];
                if (last.count < 0xFFFF and @as(u32, last.first) + last.count == cid and last.cp + last.count == chars[0]) {
                    last.count += 1;
                    continue;
                }
            }
            try runs.append(a, .{ .first = cid, .count = 1, .cp = chars[0] });
        } else {
            try multis.append(a, .{ .cid = cid, .len = @intCast(chars.len), .at = @intCast(pool.items.len) });
            for (chars) |cp| try pool.append(a, cp);
        }
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeInt(u32, @intCast(runs.items.len), .little);
    try w.writeInt(u32, @intCast(multis.items.len), .little);
    try w.writeInt(u32, @intCast(pool.items.len), .little);
    for (runs.items) |r| {
        try w.writeInt(u16, r.first, .little);
        try w.writeInt(u16, r.count, .little);
        try w.writeInt(u32, r.cp, .little);
    }
    for (multis.items) |m| {
        try w.writeInt(u16, m.cid, .little);
        try w.writeInt(u16, m.len, .little);
        try w.writeInt(u32, m.at, .little);
    }
    for (pool.items) |cp| try w.writeInt(u32, cp, .little);
    return out.toOwnedSlice();
}

/// Adobe's CID-to-Unicode table for a CIDSystemInfo, or null when zpdf has none for it.
fn orderingTable(r: *Reader, info: Dict) Error!?CidTable {
    if (!cid_tables) return null;
    const registry = stringOf(try r.resolve(info.get("Registry") orelse return null)) orelse return null;
    const ordering = stringOf(try r.resolve(info.get("Ordering") orelse return null)) orelse return null;
    if (!std.mem.eql(u8, registry, "Adobe")) return null;
    for (cid_orderings, 0..) |o, i| {
        if (std.mem.eql(u8, o, ordering)) return .{ .bytes = cid_table_data[i] };
    }
    return null;
}

fn loadType0(r: *Reader, f: *Font, dict: Dict) Error!void {
    const a = r.arenaAllocator();
    const enc = (try r.getResolved(dict, "Encoding")) orelse return error.Malformed;
    if (!(enc == .name and std.mem.eql(u8, enc.name, "Identity-H"))) return error.UnsupportedFont;
    f.two_byte = true;
    const descendants = switch ((try r.getResolved(dict, "DescendantFonts")) orelse return error.Malformed) {
        .array => |arr| arr,
        else => return error.Malformed,
    };
    if (descendants.len != 1) return error.Malformed;
    const cid = switch (try r.resolve(descendants[0])) {
        .dict => |d| d,
        else => return error.Malformed,
    };
    if (try r.getResolved(cid, "CIDSystemInfo")) |info| switch (info) {
        .dict => |d| f.cid_unicode = try orderingTable(r, d),
        else => return error.Malformed,
    };
    if (try r.getResolved(cid, "DW")) |dw| f.default_width = dw.number() orelse return error.Malformed;
    const w = switch ((try r.getResolved(cid, "W")) orelse return) {
        .array => |arr| arr,
        else => return error.Malformed,
    };
    var ranges: std.ArrayList(Font.CidRange) = .empty;
    var i: usize = 0;
    while (i < w.len) {
        const first = try cidOf(r, w[i]);
        if (i + 1 >= w.len) return error.Malformed;
        switch (try r.resolve(w[i + 1])) {
            .array => |list| {
                if (list.len == 0) {
                    i += 2;
                    continue;
                }
                if (@as(u64, first) + list.len - 1 > 0xFFFF) return error.Malformed;
                const ws = try a.alloc(f64, list.len);
                for (list, 0..) |v, k| ws[k] = (try r.resolve(v)).number() orelse return error.Malformed;
                try ranges.append(a, .{ .first = first, .last = first + @as(u32, @intCast(list.len)) - 1, .widths = ws });
                i += 2;
            },
            else => {
                const last = try cidOf(r, w[i + 1]);
                if (i + 2 >= w.len or last < first) return error.Malformed;
                const v = (try r.resolve(w[i + 2])).number() orelse return error.Malformed;
                try ranges.append(a, .{ .first = first, .last = last, .widths = try a.dupe(f64, &.{v}) });
                i += 3;
            },
        }
    }
    std.mem.sort(Font.CidRange, ranges.items, {}, struct {
        fn lt(_: void, x: Font.CidRange, y: Font.CidRange) bool {
            return x.first < y.first;
        }
    }.lt);
    f.cid_widths = ranges.items;
}

fn cidOf(r: *Reader, o: Object) Error!u32 {
    return switch (try r.resolve(o)) {
        .integer => |n| if (n < 0 or n > 0xFFFF) error.Malformed else @intCast(n),
        else => error.Malformed,
    };
}

/// Whether the font's descriptor says Symbolic (/Flags bit 3, 9.8.2).
fn isSymbolic(r: *Reader, dict: Dict) Error!bool {
    const fd = (try r.getResolved(dict, "FontDescriptor")) orelse return false;
    if (fd != .dict) return error.Malformed;
    const flags = (try r.getResolved(fd.dict, "Flags")) orelse return false;
    if (flags != .integer) return error.Malformed;
    return flags.integer & 4 != 0;
}

/// Whether the font's descriptor carries a font program (FontFile, FontFile2 or FontFile3).
fn isEmbedded(r: *Reader, dict: Dict) Error!bool {
    const fd = (try r.getResolved(dict, "FontDescriptor")) orelse return false;
    if (fd != .dict) return error.Malformed;
    for ([_][]const u8{ "FontFile", "FontFile2", "FontFile3" }) |k| {
        if (fd.dict.get(k) != null) return true;
    }
    return false;
}

/// The built-in encoding of an embedded Type 1 font program (/FontFile): the glyph name of each
/// code, from the /Encoding in its cleartext part, `StandardEncoding` or the `dup <code> /<name>
/// put` entries of an array (Adobe Type 1 Font Format, 2.3). null when the font has no Type 1
/// program or the program names no encoding. The names are copied into the reader's arena.
fn type1Encoding(r: *Reader, dict: Dict) Error!?[256]?[]const u8 {
    const fd = (try r.getResolved(dict, "FontDescriptor")) orelse return null;
    if (fd != .dict) return error.Malformed;
    const program = switch ((try r.getResolved(fd.dict, "FontFile")) orelse return null) {
        .stream => |s| s,
        else => return error.Malformed,
    };
    const data = try r.streamData(program);
    // The cleartext part is the first /Length1 bytes (9.9), and ends at eexec in any case.
    var clear = data[0 .. std.mem.indexOf(u8, data, "eexec") orelse data.len];
    if (try r.getResolved(program.dict, "Length1")) |n| {
        if (n == .integer and n.integer > 0 and n.integer < clear.len) clear = clear[0..@intCast(n.integer)];
    }
    const at = std.mem.indexOf(u8, clear, "/Encoding") orelse return null;
    var tokens: std.heap.ArenaAllocator = .init(r.arena_state.child_allocator);
    defer tokens.deinit();
    var lx: read.Lexer = .{ .src = clear, .pos = at + "/Encoding".len };
    var names: [256]?[]const u8 = @splat(null);
    var found = false;
    // `dup <code> /<name> put`, token by token; anything else between resets it (the
    // `{1 index exch /.notdef put} for` that fills the array first is not an entry).
    var step: enum { none, dup, code, name } = .none;
    var code: i64 = 0;
    var name: []const u8 = "";
    while (true) {
        const before = lx.pos;
        // PostScript procedures ({ }) are not PDF syntax: step over what the lexer refuses.
        const t = lx.next(tokens.allocator()) catch |err| switch (err) {
            error.Malformed => {
                if (lx.pos == before) lx.pos += 1;
                step = .none;
                continue;
            },
            else => return err,
        };
        switch (t) {
            .eof => break,
            .keyword => |k| {
                if (!found and step == .none and std.mem.eql(u8, k, "StandardEncoding")) return tables.standard_encoding;
                if (std.mem.eql(u8, k, "put") and step == .name) {
                    if (code >= 0 and code < 256) {
                        names[@intCast(code)] = try r.arenaAllocator().dupe(u8, name);
                    }
                    found = true;
                }
                step = if (std.mem.eql(u8, k, "dup")) .dup else .none;
            },
            .integer => |n| {
                step = if (step == .dup) .code else .none;
                code = n;
            },
            .name => |n| {
                step = if (step == .code) .name else .none;
                name = n;
            },
            else => step = .none,
        }
    }
    return if (found) names else null;
}

fn loadSimple(r: *Reader, f: *Font, dict: Dict, type3: bool) Error!void {
    const a = r.arenaAllocator();
    const std_metrics = standardMetrics(f.base_font);
    // Base encoding: /Encoding's name or /BaseEncoding, else the font's built-in one (9.6.6.1):
    // for a standard font that is not embedded, Standard (or the symbol fonts' own); for an
    // embedded Type 1 program, the /Encoding in its cleartext. Other embedded programs (CFF,
    // TrueType) are not read yet, and Standard is not guessed for them: Ghostscript re-encodes
    // its subsets, so the guess gives wrong letters with no sign of it. Such codes get no base:
    // unmapped unless /ToUnicode or /Differences says.
    var names: [256]?[]const u8 = @splat(null);
    var is_winansi = false;
    var base: ?[]const u8 = null;
    var differences: []const Object = &.{};
    if (try r.getResolved(dict, "Encoding")) |enc| switch (enc) {
        .name => |n| base = n,
        .dict => |d| {
            if (try r.getResolved(d, "BaseEncoding")) |b| base = if (b == .name) b.name else return error.Malformed;
            if (try r.getResolved(d, "Differences")) |diff| differences = if (diff == .array) diff.array else return error.Malformed;
        },
        else => return error.Malformed,
    };
    if (base) |b| {
        if (std.mem.eql(u8, b, "WinAnsiEncoding")) {
            is_winansi = true;
        } else if (std.mem.eql(u8, b, "MacRomanEncoding")) {
            names = tables.mac_roman_encoding;
        } else if (std.mem.eql(u8, b, "StandardEncoding")) {
            names = tables.standard_encoding;
        }
        // MacExpertEncoding and unknown names: no base; /Differences may still say.
    } else if (try isEmbedded(r, dict)) {
        if (try type1Encoding(r, dict)) |builtin| names = builtin;
    } else if (std_metrics == null and try isSymbolic(r, dict)) {
        // A symbolic font's built-in encoding is its own (9.6.6.2), not Standard: unknown too.
    } else if (std_metrics) |m| switch (m) {
        .symbolic => |s| names = s.names,
        .text => names = tables.standard_encoding,
    } else if (!type3) names = tables.standard_encoding;

    if (is_winansi) {
        for (0..256) |c| {
            const cp = winansi.decode(@intCast(c)) orelse continue;
            // WinAnsiEncoding draws 0xA0 with the glyph "space" and 0xAD with "hyphen" (Annex D,
            // its notes 6 and 7), and a glyph's name is what says its character (9.10.2): so
            // U+0020 and U+002D, not cp1252's U+00A0 and U+00AD.
            const char: u21 = switch (cp) {
                0xA0 => 0x20,
                0xAD => 0x2D,
                else => cp,
            };
            f.encoding[c] = try a.dupe(u21, &.{char});
        }
    }
    var code: i64 = -1;
    for (differences) |d| switch (try r.resolve(d)) {
        .integer => |n| code = n,
        .name => |n| {
            if (code < 0 or code > 255) return error.Malformed;
            names[@intCast(code)] = n;
            f.encoding[@intCast(code)] = null;
            code += 1;
        },
        else => return error.Malformed,
    };
    for (0..256) |c| {
        if (names[c]) |n| f.encoding[c] = try glyphNameChars(a, n, 0);
    }

    // Widths: /Widths from /FirstChar, scaled by /FontMatrix for Type3; else the standard
    // font's metrics.
    if (try r.getResolved(dict, "Widths")) |w_obj| {
        const ws = switch (w_obj) {
            .array => |arr| arr,
            else => return error.Malformed,
        };
        const first = switch ((try r.getResolved(dict, "FirstChar")) orelse return error.Malformed) {
            .integer => |n| n,
            else => return error.Malformed,
        };
        if (first < 0 or first > 255) return error.Malformed;
        var scale: f64 = 1;
        if (type3) {
            const m = switch ((try r.getResolved(dict, "FontMatrix")) orelse return error.Malformed) {
                .array => |arr| arr,
                else => return error.Malformed,
            };
            if (m.len != 6) return error.Malformed;
            scale = 1000 * ((try r.resolve(m[0])).number() orelse return error.Malformed);
        }
        var missing: f64 = 0;
        if (try r.getResolved(dict, "FontDescriptor")) |fd| {
            if (fd == .dict) {
                if (try r.getResolved(fd.dict, "MissingWidth")) |mw| missing = mw.number() orelse return error.Malformed;
            }
        }
        for (0..256) |c| f.simple_widths[c] = missing * scale;
        for (ws, 0..) |w, k| {
            const c = first + @as(i64, @intCast(k));
            if (c > 255) break;
            f.simple_widths[@intCast(c)] = ((try r.resolve(w)).number() orelse return error.Malformed) * scale;
        }
    } else if (std_metrics) |m| switch (m) {
        // By glyph name, so a code /Differences moved to another glyph gets that glyph's width.
        .symbolic => |s| for (0..256) |c| {
            const w = if (names[c]) |n| symbolicWidth(s, n) else s.widths[c];
            f.simple_widths[c] = if (w) |v| @floatFromInt(v) else null;
        },
        .text => |t| for (0..256) |c| {
            const chars = f.encoding[c] orelse continue;
            if (chars.len != 1) continue;
            f.simple_widths[c] = textWidth(t, chars[0]);
        },
    };
}

const GState = struct {
    ctm: Matrix = identity,
    font: ?*const Font = null,
    size: f64 = 0,
    char_spacing: f64 = 0,
    word_spacing: f64 = 0,
    /// Tz / 100.
    h_scale: f64 = 1,
    leading: f64 = 0,
    rise: f64 = 0,
};

const Interp = struct {
    r: *Reader,
    /// Where the runs' text and each font's name go. pageRuns passes the reader's work arena
    /// for both this and `scratch`; pageText copies the runs out of it.
    out: Allocator,
    /// The page's work: decoded streams, stacks, the runs as they are built. Reset by the next
    /// page or endPageRuns, so a PageText does not keep its page's work alive.
    scratch: Allocator,
    /// What each `run` makes its per-operator token arena from.
    gpa: Allocator,
    runs: std.ArrayList(TextRun) = .empty,
    gs: GState = .{},
    stack: std.ArrayList(GState) = .empty,
    tm: Matrix = identity,
    tlm: Matrix = identity,
    /// Forms being drawn, to refuse a form that draws itself.
    forms: std.ArrayList(u32) = .empty,
    /// Where each run ends (the next glyph's origin), by index into `runs`.
    ends: std.ArrayList([2]f64) = .empty,
    /// Open marked-content sequences (BMC, BDC), innermost last.
    marked: std.ArrayList(Marked) = .empty,
    /// The stack and marked-content depths the stream being run started at: a form's Q or EMC
    /// cannot reach below them into the page's (8.10.1, 14.6).
    stack_floor: usize = 0,
    marked_floor: usize = 0,
    /// Each form's decoded content, by object number, decoded once per page.
    form_data: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Each font's /BaseFont, copied into the PageText's arena once.
    font_names: std.AutoHashMapUnmanaged(*const Font, []const u8) = .empty,
    operations: u32 = 0,
    glyph_count: u32 = 0,
    unplaced_actual_text: u32 = 0,

    const Marked = struct {
        /// The span's /ActualText, as UTF-8, when it has one.
        actual: ?[]const u8,
        /// The first run drawn inside it.
        first_run: usize,
    };

    fn run(self: *Interp, content: []const u8, resources: Dict, depth: u32) Error!void {
        // Tokens and operands live until their operator returns: the arena is reset after each
        // one, so a page's work does not grow with its operators. Each run has its own, because
        // a form runs inside the Do operator of the stream that draws it.
        var tokens: std.heap.ArenaAllocator = .init(self.gpa);
        defer tokens.deinit();
        const a = tokens.allocator();
        var lx: read.Lexer = .{ .src = content, .pos = 0 };
        var p: read.Parser = .{ .lx = &lx, .arena = a, .max_depth = self.r.options.max_depth };
        var operands: std.ArrayList(Object) = .empty;
        while (true) {
            const t = try lx.next(a);
            switch (t) {
                .eof => break,
                .keyword => |op| {
                    const eql = std.mem.eql;
                    if (eql(u8, op, "true") or eql(u8, op, "false") or eql(u8, op, "null")) {
                        try operands.append(self.scratch, try p.fromToken(t, 0));
                        continue;
                    }
                    self.operations += 1;
                    if (self.operations > self.r.options.max_operations) return error.TooLarge;
                    if (eql(u8, op, "BI")) {
                        try skipInlineImage(&lx, a, self.r.options.max_depth);
                    } else try self.operator(op, operands.items, resources, depth);
                    operands.clearRetainingCapacity();
                    _ = tokens.reset(.retain_capacity);
                },
                else => {
                    if (operands.items.len >= 1 << 16) return error.TooLarge;
                    try operands.append(self.scratch, try p.fromToken(t, 0));
                },
            }
        }
    }

    fn num(ops: []const Object, i: usize) Error!f64 {
        if (i >= ops.len) return error.Malformed;
        const v = ops[i].number() orelse return error.Malformed;
        if (!std.math.isFinite(v)) return error.Malformed;
        return v;
    }

    fn operator(self: *Interp, op: []const u8, ops: []const Object, resources: Dict, depth: u32) Error!void {
        const eql = std.mem.eql;
        if (eql(u8, op, "q")) {
            if (self.stack.items.len >= 1024) return error.TooDeep;
            try self.stack.append(self.scratch, self.gs);
        } else if (eql(u8, op, "Q")) {
            // An unbalanced Q is common and harmless: the state stays. A form's Q cannot pop
            // what the page saved.
            if (self.stack.items.len > self.stack_floor) self.gs = self.stack.pop().?;
        } else if (eql(u8, op, "cm")) {
            if (ops.len != 6) return error.Malformed;
            var m: Matrix = undefined;
            for (0..6) |i| m[i] = try num(ops, i);
            self.gs.ctm = mul(m, self.gs.ctm);
        } else if (eql(u8, op, "BT")) {
            self.tm = identity;
            self.tlm = identity;
        } else if (eql(u8, op, "Tf")) {
            if (ops.len != 2 or ops[0] != .name) return error.Malformed;
            const fonts = switch ((try self.r.getResolved(resources, "Font")) orelse return error.Malformed) {
                .dict => |d| d,
                else => return error.Malformed,
            };
            self.gs.font = try loadFont(self.r, fonts.get(ops[0].name) orelse return error.Malformed);
            self.gs.size = try num(ops, 1);
        } else if (eql(u8, op, "Tc")) {
            self.gs.char_spacing = try num(ops, 0);
        } else if (eql(u8, op, "Tw")) {
            self.gs.word_spacing = try num(ops, 0);
        } else if (eql(u8, op, "Tz")) {
            self.gs.h_scale = try num(ops, 0) / 100;
        } else if (eql(u8, op, "TL")) {
            self.gs.leading = try num(ops, 0);
        } else if (eql(u8, op, "Ts")) {
            self.gs.rise = try num(ops, 0);
        } else if (eql(u8, op, "Td")) {
            self.moveLine(try num(ops, 0), try num(ops, 1));
        } else if (eql(u8, op, "TD")) {
            self.gs.leading = -(try num(ops, 1));
            self.moveLine(try num(ops, 0), try num(ops, 1));
        } else if (eql(u8, op, "Tm")) {
            if (ops.len != 6) return error.Malformed;
            for (0..6) |i| self.tm[i] = try num(ops, i);
            self.tlm = self.tm;
        } else if (eql(u8, op, "T*")) {
            self.moveLine(0, -self.gs.leading);
        } else if (eql(u8, op, "Tj")) {
            if (ops.len != 1 or ops[0] != .string) return error.Malformed;
            try self.show(&.{ops[0]});
        } else if (eql(u8, op, "TJ")) {
            if (ops.len != 1 or ops[0] != .array) return error.Malformed;
            try self.show(ops[0].array);
        } else if (eql(u8, op, "'")) {
            if (ops.len != 1 or ops[0] != .string) return error.Malformed;
            self.moveLine(0, -self.gs.leading);
            try self.show(&.{ops[0]});
        } else if (eql(u8, op, "\"")) {
            if (ops.len != 3 or ops[2] != .string) return error.Malformed;
            self.gs.word_spacing = try num(ops, 0);
            self.gs.char_spacing = try num(ops, 1);
            self.moveLine(0, -self.gs.leading);
            try self.show(&.{ops[2]});
        } else if (eql(u8, op, "Do")) {
            if (ops.len != 1 or ops[0] != .name) return error.Malformed;
            try self.drawXObject(ops[0].name, resources, depth);
        } else if (eql(u8, op, "gs")) {
            // An ExtGState can set the font and size, as Tf does (8.4.5, /Font).
            if (ops.len != 1 or ops[0] != .name) return error.Malformed;
            const states = (try self.r.getResolved(resources, "ExtGState")) orelse return error.Malformed;
            if (states != .dict) return error.Malformed;
            const state = (try self.r.getResolved(states.dict, ops[0].name)) orelse return error.Malformed;
            if (state != .dict) return error.Malformed;
            if (try self.r.getResolved(state.dict, "Font")) |f| {
                if (f != .array or f.array.len != 2) return error.Malformed;
                self.gs.font = try loadFont(self.r, f.array[0]);
                self.gs.size = (try self.r.resolve(f.array[1])).number() orelse return error.Malformed;
            }
        } else if (eql(u8, op, "BMC")) {
            try self.beginMarked(null);
        } else if (eql(u8, op, "BDC")) {
            if (ops.len != 2) return error.Malformed;
            const props: ?Dict = switch (ops[1]) {
                .dict => |d| d,
                // A name is a key in the resources' /Properties (14.6.2).
                .name => |n| blk: {
                    const all = (try self.r.getResolved(resources, "Properties")) orelse break :blk null;
                    if (all != .dict) return error.Malformed;
                    const v = (try self.r.getResolved(all.dict, n)) orelse break :blk null;
                    break :blk if (v == .dict) v.dict else null;
                },
                else => return error.Malformed,
            };
            var actual: ?[]const u8 = null;
            if (props) |d| {
                if (try self.r.getResolved(d, "ActualText")) |at| {
                    if (at != .string) return error.Malformed;
                    actual = try textString(self.scratch, at.string);
                }
            }
            try self.beginMarked(actual);
        } else if (eql(u8, op, "EMC")) {
            // An unbalanced EMC is ignored, as an unbalanced Q is, and a form's cannot close
            // what the page opened.
            if (self.marked.items.len <= self.marked_floor) return;
            const m = self.marked.pop().?;
            const actual = m.actual orelse return;
            // A nested span merges first; an enclosing one then merges that run with the rest,
            // so the outermost ActualText is the text.
            try self.mergeActual(m.first_run, actual);
        }
        // Every other operator (paths, colour, images, marked content) draws no text.
    }

    fn beginMarked(self: *Interp, actual: ?[]const u8) Error!void {
        if (self.marked.items.len >= 1024) return error.TooDeep;
        try self.marked.append(self.scratch, .{ .actual = actual, .first_run = self.runs.items.len });
    }

    /// The runs from `first` on become one run with `actual` as its text, from the first
    /// glyph's origin to the last glyph's end. No run (the span drew no text): nothing, since
    /// the text has no position.
    fn mergeActual(self: *Interp, first: usize, actual: []const u8) Error!void {
        if (first >= self.runs.items.len) {
            self.unplaced_actual_text += 1;
            return;
        }
        const runs = self.runs.items[first..];
        var merged = runs[0];
        merged.text = actual;
        merged.unmapped = 0;
        merged.actual_text = true;
        var glyphs: std.ArrayList(Glyph) = .empty;
        for (runs) |r| for (r.glyphs) |g| try glyphs.append(self.scratch, .{ .x = g.x, .y = g.y, .text_at = 0 });
        merged.glyphs = glyphs.items;
        const end = self.ends.items[self.ends.items.len - 1];
        merged.width = null;
        var known = true;
        for (runs) |r| known = known and r.width != null;
        if (known) merged.width = std.math.hypot(end[0] - merged.x, end[1] - merged.y);
        self.runs.shrinkRetainingCapacity(first);
        self.ends.shrinkRetainingCapacity(first);
        try self.runs.append(self.scratch, merged);
        try self.ends.append(self.scratch, end);
    }

    fn moveLine(self: *Interp, tx: f64, ty: f64) void {
        self.tlm = mul(.{ 1, 0, 0, 1, tx, ty }, self.tlm);
        self.tm = self.tlm;
    }

    fn drawXObject(self: *Interp, name: []const u8, resources: Dict, depth: u32) Error!void {
        const xobjects = switch ((try self.r.getResolved(resources, "XObject")) orelse return error.Malformed) {
            .dict => |d| d,
            else => return error.Malformed,
        };
        const ref = xobjects.get(name) orelse return error.Malformed;
        const s = switch (try self.r.resolve(ref)) {
            .stream => |s| s,
            else => return error.Malformed,
        };
        const subtype = (try self.r.getResolved(s.dict, "Subtype")) orelse return error.Malformed;
        if (!(subtype == .name and std.mem.eql(u8, subtype.name, "Form"))) return;
        if (depth >= 16) return error.TooDeep;
        if (ref == .ref) {
            for (self.forms.items) |n| if (n == ref.ref.num) return error.Malformed;
            try self.forms.append(self.scratch, ref.ref.num);
        }
        defer if (ref == .ref) {
            _ = self.forms.pop();
        };
        // A form runs in its own copy of the graphics state, with its /Matrix (8.10.1); the
        // text state outside is untouched.
        const saved_gs = self.gs;
        const saved_tm = self.tm;
        const saved_tlm = self.tlm;
        defer {
            self.gs = saved_gs;
            self.tm = saved_tm;
            self.tlm = saved_tlm;
        }
        if (try self.r.getResolved(s.dict, "Matrix")) |m_obj| {
            const m = switch (m_obj) {
                .array => |arr| arr,
                else => return error.Malformed,
            };
            if (m.len != 6) return error.Malformed;
            var mat: Matrix = undefined;
            for (0..6) |i| mat[i] = (try self.r.resolve(m[i])).number() orelse return error.Malformed;
            self.gs.ctm = mul(mat, self.gs.ctm);
        }
        const form_resources = if (try self.r.getResolved(s.dict, "Resources")) |res| switch (res) {
            .dict => |d| d,
            else => return error.Malformed,
        } else resources;
        const data = if (ref == .ref) self.form_data.get(ref.ref.num) orelse blk: {
            const d = try self.r.decodeStream(self.scratch, s);
            try self.form_data.put(self.scratch, ref.ref.num, d);
            break :blk d;
        } else try self.r.decodeStream(self.scratch, s);
        // The form's own q/Q and BMC/EMC stay inside it: an unbalanced Q cannot pop the page's
        // state, and what the form leaves open is closed (not merged) when it ends.
        const saved_floors = .{ self.stack_floor, self.marked_floor };
        self.stack_floor = self.stack.items.len;
        self.marked_floor = self.marked.items.len;
        defer {
            self.stack.shrinkRetainingCapacity(self.stack_floor);
            self.marked.shrinkRetainingCapacity(self.marked_floor);
            self.stack_floor, self.marked_floor = saved_floors;
        }
        try self.run(data, form_resources, depth + 1);
    }

    /// One text-showing operator: strings and TJ adjustments, as one run.
    fn show(self: *Interp, parts: []const Object) Error!void {
        const font = self.gs.font orelse return error.Malformed;
        const a = self.scratch;
        var text: std.ArrayList(u8) = .empty;
        var unmapped: u32 = 0;
        var width_known = true;
        var glyphs: std.ArrayList(Glyph) = .empty;
        for (parts) |part| switch (part) {
            .string => |bytes| {
                const step: usize = if (font.two_byte) 2 else 1;
                // A two-byte font's string holds whole codes: a last half code is refused,
                // not dropped.
                if (bytes.len % step != 0) return error.Malformed;
                var i: usize = 0;
                while (i + step <= bytes.len) : (i += step) {
                    const at = self.origin();
                    self.glyph_count += 1;
                    if (self.glyph_count > self.r.options.max_page_glyphs) return error.TooLarge;
                    const text_at = std.math.cast(u32, text.items.len) orelse return error.TooLarge;
                    try glyphs.append(a, .{ .x = at[0], .y = at[1], .text_at = text_at });
                    const code: u32 = if (font.two_byte) (@as(u32, bytes[i]) << 8) | bytes[i + 1] else bytes[i];
                    var buf: [max_chars]u21 = undefined;
                    if (font.unicode(code, @intCast(step), &buf)) |chars| {
                        for (chars) |cp| try appendUtf8(a, &text, cp);
                    } else {
                        try appendUtf8(a, &text, std.unicode.replacement_character);
                        unmapped += 1;
                    }
                    const w0 = font.width(code) orelse blk: {
                        width_known = false;
                        break :blk 0;
                    };
                    const word: f64 = if (step == 1 and code == 32) self.gs.word_spacing else 0;
                    self.advance((w0 / 1000 * self.gs.size + self.gs.char_spacing + word) * self.gs.h_scale);
                }
            },
            .integer, .real => self.advance(-(part.number().?) / 1000 * self.gs.size * self.gs.h_scale),
            else => return error.Malformed,
        };
        // The run starts at its first glyph, so a TJ adjustment before that glyph moves the start.
        if (glyphs.items.len == 0) return;
        const first: [2]f64 = .{ glyphs.items[0].x, glyphs.items[0].y };
        const end = self.origin();
        const m = mul(self.tm, self.gs.ctm);
        const size = self.gs.size * std.math.hypot(m[2], m[3]);
        const width = std.math.hypot(end[0] - first[0], end[1] - first[1]);
        // Finite operands can still multiply past f64's range. A glyph origin that did ends the
        // run there too, so the width (infinite or NaN) catches it: refused, not returned.
        if (!std.math.isFinite(size) or !std.math.isFinite(width)) return error.Malformed;
        // The name lives in the reader (or the file); the run is the PageText's, so it gets a
        // copy, made once per font.
        const gop = try self.font_names.getOrPut(a, font);
        if (!gop.found_existing) gop.value_ptr.* = try self.out.dupe(u8, font.base_font);
        try self.ends.append(a, end);
        try self.runs.append(a, .{
            .text = text.items,
            .x = first[0],
            .y = first[1],
            .size = size,
            .width = if (width_known) width else null,
            .font = gop.value_ptr.*,
            .unmapped = unmapped,
            .glyphs = glyphs.items,
            .actual_text = false,
        });
    }

    fn advance(self: *Interp, tx: f64) void {
        self.tm = mul(.{ 1, 0, 0, 1, tx, 0 }, self.tm);
    }

    /// Where the next glyph's origin is, in user space: (0, rise) in text space (9.4.4).
    fn origin(self: *const Interp) [2]f64 {
        const m = mul(.{ 1, 0, 0, 1, 0, self.gs.rise }, mul(self.tm, self.gs.ctm));
        return .{ m[4], m[5] };
    }
};

/// A PDF text string (7.9.2.2) as UTF-8: UTF-16BE after FE FF, UTF-8 after EF BB BF, else
/// PDFDocEncoding. Characters it cannot give are U+FFFD. Into `arena`: the result is a list's
/// items, and the UTF-16 step's buffer is left there.
fn textString(arena: Allocator, bytes: []const u8) Error![]const u8 {
    const a = arena;
    var out: std.ArrayList(u8) = .empty;
    if (bytes.len >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF) {
        for (try utf16be(a, bytes[2..])) |cp| try appendUtf8(a, &out, cp);
    } else if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xEF\xBB\xBF")) {
        const rest = bytes[3..];
        if (std.unicode.utf8ValidateSlice(rest)) return a.dupe(u8, rest);
        try appendUtf8(a, &out, std.unicode.replacement_character);
    } else for (bytes) |b| try appendUtf8(a, &out, pdfDocEncoding(b) orelse std.unicode.replacement_character);
    return out.items;
}

/// PDFDocEncoding (Annex D.2): Latin-1 except 0x18 to 0x1F and 0x7F to 0xA0, and 0xAD.
fn pdfDocEncoding(b: u8) ?u21 {
    const low = [8]u21{ 0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC };
    const high = [33]u21{
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203A, 0x2212,
        0x2030, 0x201E, 0x201C, 0x201D, 0x2018, 0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141,
        0x0152, 0x0160, 0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0,      0x20AC,
    };
    return switch (b) {
        0x18...0x1F => low[b - 0x18],
        0x7F, 0xAD => null,
        0x80...0xA0 => if (high[b - 0x80] == 0) null else high[b - 0x80],
        else => b,
    };
}

fn appendUtf8(a: Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(std.unicode.replacement_character, &buf) catch unreachable;
    try out.appendSlice(a, buf[0..n]);
}

/// Skips an inline image (8.9.7): its dictionary up to ID, then its data, then EI. Where the data
/// ends: /L or /Length when given (PDF 2.0); else, with no filter and a known colour space, its
/// size from /W, /H, /BPC and the colour count; else the first "EI" with white space on both
/// sides, which image data can contain (a filtered image without /L is the one case left to
/// that guess). Either way EI must follow, or the page is refused.
fn skipInlineImage(lx: *read.Lexer, arena: Allocator, max_depth: u32) Error!void {
    var p: read.Parser = .{ .lx = lx, .arena = arena, .max_depth = max_depth };
    var length: ?u64 = null;
    var w: ?i64 = null;
    var h: ?i64 = null;
    var bpc: i64 = 8;
    var colors: ?i64 = null;
    var mask = false;
    var filtered = false;
    while (true) {
        const t = try lx.next(arena);
        switch (t) {
            .eof => return error.Malformed,
            .keyword => |k| if (std.mem.eql(u8, k, "ID")) break else return error.Malformed,
            .name => |key| {
                const v = try p.parseValue(0);
                const eql = std.mem.eql;
                const int: ?i64 = if (v == .integer) v.integer else null;
                if (eql(u8, key, "L") or eql(u8, key, "Length")) {
                    if (int == null or int.? < 0) return error.Malformed;
                    length = @intCast(int.?);
                } else if (eql(u8, key, "W") or eql(u8, key, "Width")) {
                    w = int;
                } else if (eql(u8, key, "H") or eql(u8, key, "Height")) {
                    h = int;
                } else if (eql(u8, key, "BPC") or eql(u8, key, "BitsPerComponent")) {
                    bpc = int orelse return error.Malformed;
                } else if (eql(u8, key, "IM") or eql(u8, key, "ImageMask")) {
                    mask = v == .boolean and v.boolean;
                } else if (eql(u8, key, "F") or eql(u8, key, "Filter")) {
                    filtered = !(v == .array and v.array.len == 0);
                } else if (eql(u8, key, "CS") or eql(u8, key, "ColorSpace")) {
                    colors = switch (v) {
                        .name => |n| if (eql(u8, n, "G") or eql(u8, n, "DeviceGray") or eql(u8, n, "I") or eql(u8, n, "Indexed"))
                            1
                        else if (eql(u8, n, "RGB") or eql(u8, n, "DeviceRGB"))
                            3
                        else if (eql(u8, n, "CMYK") or eql(u8, n, "DeviceCMYK"))
                            4
                        else
                            null, // a named resource: its colour count is not looked up
                        .array => |arr| if (arr.len > 0 and arr[0] == .name and (eql(u8, arr[0].name, "I") or eql(u8, arr[0].name, "Indexed"))) 1 else null,
                        else => null,
                    };
                }
            },
            else => return error.Malformed,
        }
    }
    if (length == null and !filtered) {
        if (mask) {
            bpc = 1;
            colors = 1;
        }
        if (w != null and h != null and colors != null) {
            const ww = w.?;
            const hh = h.?;
            if (ww < 0 or hh < 0 or ww > 1 << 24 or hh > 1 << 24 or bpc < 1 or bpc > 16) return error.Malformed;
            const row: u64 = (@as(u64, @intCast(ww)) * @as(u64, @intCast(bpc)) * @as(u64, @intCast(colors.?)) + 7) / 8;
            length = row * @as(u64, @intCast(hh));
        }
    }
    // One white-space byte follows ID.
    if (lx.pos >= lx.src.len or !read.isWhite(lx.src[lx.pos])) return error.Malformed;
    lx.pos += 1;
    if (length) |l| {
        if (l > lx.src.len - lx.pos) return error.Malformed;
        lx.pos += @intCast(l);
    } else {
        var i = lx.pos;
        while (i + 1 < lx.src.len) : (i += 1) {
            if (lx.src[i] == 'E' and lx.src[i + 1] == 'I' and i > 0 and read.isWhite(lx.src[i - 1]) and
                (i + 2 == lx.src.len or read.isWhite(lx.src[i + 2]))) break;
        } else return error.Malformed;
        lx.pos = i;
    }
    const ei = try lx.next(arena);
    if (!(ei == .keyword and std.mem.eql(u8, ei.keyword, "EI"))) return error.Malformed;
}

/// A page's runs as Reader.pageRuns leaves them, in the reader's work memory.
pub const PageRuns = struct {
    runs: []const TextRun,
    unplaced_actual_text: u32,
};

/// Reader.pageRuns's work.
pub fn pageRuns(r: *Reader, index: usize) Error!PageRuns {
    // A previous page's runs, if its caller did not end them, go first: the reader holds at most
    // one page's work.
    endPageRuns(r);
    errdefer endPageRuns(r);
    const work = r.work_state.allocator();
    const page = r.page(index);
    var interp: Interp = .{ .r = r, .out = work, .scratch = work, .gpa = r.arena_state.child_allocator };
    if (try r.pageContentsIn(work, page)) |content| try interp.run(content, page.resources, 0);
    return .{ .runs = interp.runs.items, .unplaced_actual_text = interp.unplaced_actual_text };
}

/// Reader.endPageRuns's work: the work arena reset down to max_retained_work (Options says why).
pub fn endPageRuns(r: *Reader) void {
    _ = r.work_state.reset(.{ .retain_with_limit = r.options.max_retained_work });
}

/// Reader.pageText's work: pageRuns, copied out at their size into the result's arena.
pub fn pageText(r: *Reader, gpa: Allocator, index: usize) Error!PageText {
    const page_runs = try pageRuns(r, index);
    defer endPageRuns(r);
    var result: PageText = .{ .arena = .init(gpa), .runs = &.{}, .unplaced_actual_text = page_runs.unplaced_actual_text };
    errdefer result.arena.deinit();
    const out = result.arena.allocator();
    const runs = try out.alloc(TextRun, page_runs.runs.len);
    // All of a font's runs share one name slice (Interp.font_names), so it is copied once.
    var names: std.AutoHashMapUnmanaged([*]const u8, []const u8) = .empty;
    const work = r.work_state.allocator();
    for (runs, page_runs.runs) |*o, run| {
        o.* = run;
        o.text = try out.dupe(u8, run.text);
        o.glyphs = try out.dupe(Glyph, run.glyphs);
        const name = try names.getOrPut(work, run.font.ptr);
        if (!name.found_existing) name.value_ptr.* = try out.dupe(u8, run.font);
        o.font = name.value_ptr.*;
    }
    result.runs = runs;
    return result;
}

// ---- tests ----

const testing = std.testing;

fn loadFixture(name: []const u8) ![]u8 {
    const options = @import("build_options");
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ options.read_fixtures, name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 24));
}

test "the fixtures' pages read as zpdf drew them: text, origin and size of each run" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "base.pdf", "objstm.pdf", "linear.pdf" }) |name| {
        const bytes = try loadFixture(name);
        defer gpa.free(bytes);
        var r = try Reader.open(gpa, bytes, .{});
        defer r.deinit();
        for (0..3) |i| {
            var pt = try r.pageText(gpa, i);
            defer pt.deinit();
            var want_buf: [3][64]u8 = undefined;
            const want = [3]struct { text: []const u8, x: f64, y: f64, size: f64, font: []const u8 }{
                .{ .text = try std.fmt.bufPrint(&want_buf[0], "Report page {d}: office caf\u{e9}", .{i + 1}), .x = 76, .y = 706, .size = 14, .font = "Roboto-Regular" },
                .{ .text = try std.fmt.bufPrint(&want_buf[1], "Helvetica (parens) \\ caf\u{e9} \u{20ac}{d}", .{i + 1}), .x = 76, .y = 670, .size = 10, .font = "Helvetica" },
                .{ .text = try std.fmt.bufPrint(&want_buf[2], "Page {d} of 3", .{i + 1}), .x = 270, .y = 30, .size = 9, .font = "Helvetica" },
            };
            try testing.expectEqual(@as(usize, 3), pt.runs.len);
            for (want, pt.runs) |w, run| {
                try testing.expectEqualStrings(w.text, run.text);
                try testing.expectApproxEqAbs(w.x, run.x, 1e-9);
                try testing.expectApproxEqAbs(w.y, run.y, 1e-9);
                try testing.expectApproxEqAbs(w.size, run.size, 1e-9);
                try testing.expect(std.mem.endsWith(u8, run.font, w.font));
                try testing.expectEqual(@as(u32, 0), run.unmapped);
                try testing.expect(run.width.? > 0);
            }
        }
    }
}

fn streamObject(comptime dict: []const u8, comptime data: []const u8) []const u8 {
    return std.fmt.comptimePrint("<< {s} /Length {d} >>\nstream\n{s}\nendstream", .{ dict, data.len, data });
}

test "text state, matrices, encodings, CMaps, inline images and forms give the runs ISO 32000-1 9.4 says" {
    const gpa = testing.allocator;
    const page1 =
        \\q 2 0 0 2 10 20 cm
        \\BT /F1 10 Tf 1 0 0 1 5 6 Tm (AB) Tj ET
        \\Q
        \\BT /F1 10 Tf 200 Tz 2 Tc 3 Tw 4 Ts 100 700 Td [(A) -500 ( A)] TJ 15 TL T* (C) ' ET
        \\BT 0 Tc 0 Tw 100 Tz 0 Ts /F2 12 Tf 50 400 Td <00010002000A01010020002100050003> Tj ET
        \\BI /W 11 /H 1 /BPC 8 /CS /G ID
    ++ "\x00EI (Z) Tj \nEI\n/X1 Do\nBT 10 30 TD T* <0001> Tj ET";
    const cmap =
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\2 beginbfchar <0001> <0041> <0003> <D83DDE00> endbfchar
        \\3 beginbfrange
        \\<000A> <0014> <0061>
        \\<0100> <FFFF> <4E00>
        \\<0020> <0021> [<0058> <00590059>]
        \\endbfrange endcmap CMapName currentdict /CMap defineresource pop end end
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R /F2 8 0 R /F3 9 0 R >> /XObject << /X1 10 0 R /X2 11 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 12 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents 13 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents 14 0 R >>",
        "<< /Type /Page /Parent 2 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /uni00C5 /f_i /eacute.sc 128 /bogusname] >> >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /Test /Encoding /Identity-H /DescendantFonts [15 0 R] /ToUnicode 16 0 R >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /V /Encoding /Identity-V /DescendantFonts [15 0 R] >>",
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 300 0]", "BT /F1 8 Tf 0 0 Td (A\x80) Tj ET"),
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /X2 11 0 R >> >>", "/X2 Do"),
        streamObject("", page1),
        streamObject("", "BT /F3 12 Tf <0001> Tj ET"),
        streamObject("", "/X2 Do"),
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Test /W [1 [500 600] 10 20 250] /DW 1000 >>",
        streamObject("", cmap),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();

    const Want = struct { text: []const u8, x: f64, y: f64, size: f64, width: ?f64, unmapped: u32 };
    const want = [_]Want{
        // cm scales by 2 and moves by (10, 20): Tm's (5, 6) lands at (20, 32), size 20. "fi" is
        // two characters, so its width is not in the AFM table: width unknown.
        .{ .text = "\u{c5}fi", .x = 20, .y = 32, .size = 20, .width = null, .unmapped = 0 },
        // Rise 4. Each glyph advances (w / 1000 * 10 + Tc 2 [+ Tw 3 for a space]) * Tz 2;
        // the -500 adjustment moves +500 / 1000 * 10 * 2. Å 667, space 278:
        // 17.34 + 10 + 15.56 + 17.34 = 60.24. No space is invented for the gap.
        .{ .text = "\u{c5} \u{c5}", .x = 100, .y = 704, .size = 10, .width = 60.24, .unmapped = 0 },
        // TL 15: T* to 685, then ' to 670 (rise 4). é 556: (5.56 + 2) * 2.
        .{ .text = "\u{e9}", .x = 100, .y = 674, .size = 10, .width = 15.12, .unmapped = 0 },
        // Identity-H: 0001 bfchar A; 0002 none; 000A small range a; 0101 large range U+4E01;
        // 0020 and 0021 an array range; 0005 none; 0003 a surrogate pair. /W: 500 600 for 1
        // and 2, 250 for 10 to 20, /DW 1000 else: 6350 / 1000 * 12.
        .{ .text = "A\u{fffd}a\u{4e01}XYY\u{fffd}\u{1f600}", .x = 50, .y = 400, .size = 12, .width = 76.2, .unmapped = 2 },
        // The inline image's data holds "EI" with white space on both sides, then "(Z) Tj": its
        // /W, /H and /BPC say where the data really ends, so no Z is drawn.
        // The form, moved by its /Matrix to x 300; code 0x80 is in /Differences as an unknown
        // name, so it is unmapped and has no width.
        .{ .text = "\u{c5}\u{fffd}", .x = 300, .y = 0, .size = 8, .width = null, .unmapped = 1 },
        // After the form, its F1 8 is gone and the page's F2 12 is back. TD sets the leading to
        // -30, so T* moves up 30 from (10, 30).
        .{ .text = "A", .x = 10, .y = 60, .size = 12, .width = 6, .unmapped = 0 },
    };
    try testing.expectEqual(want.len, pt.runs.len);
    for (want, pt.runs) |w, run| {
        try testing.expectEqualStrings(w.text, run.text);
        try testing.expectApproxEqAbs(w.x, run.x, 1e-9);
        try testing.expectApproxEqAbs(w.y, run.y, 1e-9);
        try testing.expectApproxEqAbs(w.size, run.size, 1e-9);
        if (w.width) |ww| try testing.expectApproxEqAbs(ww, run.width.?, 1e-9) else try testing.expectEqual(@as(?f64, null), run.width);
        try testing.expectEqual(w.unmapped, run.unmapped);
    }
    // Glyph origins of the TJ run: Å at 100; after 17.34 and the +10 adjustment the space at
    // 127.34; after the space's 15.56 the second Å at 142.9. Å is two UTF-8 bytes.
    const tj = pt.runs[1].glyphs;
    try testing.expectEqual(@as(usize, 3), tj.len);
    for ([_]f64{ 100, 127.34, 142.9 }, tj) |x, g| {
        try testing.expectApproxEqAbs(x, g.x, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 704), g.y, 1e-9);
    }
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, &.{ tj[0].text_at, tj[1].text_at, tj[2].text_at });
    try testing.expectError(error.UnsupportedFont, r.pageText(gpa, 1));
    try testing.expectError(error.Malformed, r.pageText(gpa, 2));
    var blank = try r.pageText(gpa, 3);
    defer blank.deinit();
    try testing.expectEqual(@as(usize, 0), blank.runs.len);
}

test "ActualText replaces its span's text: inline, by /Properties name, nested, and an unbalanced EMC" {
    const gpa = testing.allocator;
    const content =
        \\BT /F1 10 Tf 10 10 Td
        \\/Span << /ActualText (xy\200) >> BDC (C) Tj [(D) 100 (C)] TJ EMC
        \\(D) Tj
        \\/Span /P1 BDC /Span << /ActualText (inner) >> BDC (C) Tj EMC (D) Tj EMC
        \\/Span << /ActualText (nothing drawn) >> BDC EMC
        \\EMC (C) Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /Properties << /P1 << /ActualText <FEFF00E9D83DDE00> >> >> >> >>",
        streamObject("", content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    // Helvetica: C 722, D 722. The first span: C at 10, D at 17.22, the 100 adjustment moves
    // back 1, C at 23.44, ending at 30.66. Its text is PDFDocEncoding: \200 is U+2022.
    try testing.expectEqual(@as(usize, 4), pt.runs.len);
    const span = pt.runs[0];
    try testing.expectEqualStrings("xy\u{2022}", span.text);
    try testing.expect(span.actual_text);
    try testing.expectApproxEqAbs(@as(f64, 10), span.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20.66), span.width.?, 1e-9);
    try testing.expectEqual(@as(usize, 3), span.glyphs.len);
    for ([_]f64{ 10, 17.22, 23.44 }, span.glyphs) |x, g| {
        try testing.expectApproxEqAbs(x, g.x, 1e-9);
        try testing.expectEqual(@as(u32, 0), g.text_at);
    }
    try testing.expectEqualStrings("D", pt.runs[1].text);
    try testing.expect(!pt.runs[1].actual_text);
    // The named span's UTF-16 text (with a surrogate pair) replaces both its runs and the inner
    // span's text.
    try testing.expectEqualStrings("\u{e9}\u{1f600}", pt.runs[2].text);
    try testing.expectEqual(@as(usize, 2), pt.runs[2].glyphs.len);
    // A span that draws nothing adds no run, but is counted; the extra EMC is ignored.
    try testing.expectEqualStrings("C", pt.runs[3].text);
    try testing.expectEqual(@as(u32, 1), pt.unplaced_actual_text);
}

test "PDFDocEncoding decodes as pdfminer's table does at the bytes that differ from Latin-1" {
    const cases = [_]struct { b: u8, cp: ?u21 }{
        .{ .b = 0x18, .cp = 0x02D8 }, .{ .b = 0x1F, .cp = 0x02DC }, .{ .b = 0x41, .cp = 'A' },
        .{ .b = 0x80, .cp = 0x2022 }, .{ .b = 0x8A, .cp = 0x2212 }, .{ .b = 0x93, .cp = 0xFB01 },
        .{ .b = 0x9E, .cp = 0x017E }, .{ .b = 0x9F, .cp = null },   .{ .b = 0xA0, .cp = 0x20AC },
        .{ .b = 0xAD, .cp = null },   .{ .b = 0xE9, .cp = 0xE9 },
    };
    for (cases) |c| try testing.expectEqual(c.cp, pdfDocEncoding(c.b));
}

test "a run starts at its first glyph; no glyph, no run; U+00A0's width; no guessed encoding for an embedded font" {
    const gpa = testing.allocator;
    const content =
        \\BT /F1 10 Tf 100 100 Td [-500 (A)] TJ [-300 200] TJ ET
        \\BT /F1 10 Tf 100 80 Td (\240A) Tj ET
        \\BT /F2 10 Tf 100 60 Td (\255A) Tj ET
        \\BT /F3 10 Tf 100 40 Td (\255A) Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >> >> >>",
        streamObject("", content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>",
        // The same subset name, with and without a font program, and no /Encoding.
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Times-Roman /FirstChar 65 /Widths [722] /FontDescriptor 8 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>",
        "<< /Type /FontDescriptor /FontName /ABCDEF+Times-Roman /FontFile3 9 0 R >>",
        streamObject("/Subtype /Type1C", "not read"),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 4), pt.runs.len);
    // -500 moves +5 before the first glyph: the run starts at 105, not 100. The TJ of numbers
    // only made no run.
    try testing.expectEqualStrings("A", pt.runs[0].text);
    try testing.expectApproxEqAbs(@as(f64, 105), pt.runs[0].x, 1e-9);
    // WinAnsi 0xA0 is the glyph "space": U+0020, Courier's 600, so A is at 106.
    try testing.expectEqualStrings(" A", pt.runs[1].text);
    try testing.expectApproxEqAbs(@as(f64, 106), pt.runs[1].glyphs[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 12), pt.runs[1].width.?, 1e-9);
    // Embedded with no /Encoding: its built-in encoding is not read, so \255 and A are both
    // unmapped rather than StandardEncoding's guesses (\255 there is "guilsinglright").
    try testing.expectEqualStrings("\u{fffd}\u{fffd}", pt.runs[2].text);
    try testing.expectEqual(@as(u32, 2), pt.runs[2].unmapped);
    // Not embedded: StandardEncoding, where \255 is "guilsinglright" (the letter the
    // Ghostscript files read wrongly when zpdf guessed this encoding for embedded fonts).
    try testing.expectEqualStrings("\u{203a}A", pt.runs[3].text);
}

test "a CMap with tokens the lexer refuses (a stray >, braces) is still read, and ends" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Found by tools/read-fuzz.py: a lone '>' made the lexer refuse without moving on, and the
    // CMap parser, which skips refused tokens, looped forever.
    const cm = try parseCMap(a, testing.allocator, "/CIDInit { pop } bind 1 beginbfchar <0001> > <0041> endbfchar >", 16);
    var buf: [max_chars]u21 = undefined;
    try testing.expectEqualSlices(u21, &.{0x41}, cm.lookup(1, 2, &buf).?);
}

test "CMaps: codes up to 0xFFFFFFFF, the latest definition wins, and limits are errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [max_chars]u21 = undefined;
    // A one-code range at the top of the 4-byte space: its loop must not step past it.
    const top = try parseCMap(a, testing.allocator, "1 beginbfrange <FFFFFFFF> <FFFFFFFF> <0041> endbfrange", 16);
    try testing.expectEqualSlices(u21, &.{'A'}, top.lookup(0xFFFFFFFF, 4, &buf).?);
    // A large range defined after a bfchar replaces it; a bfchar after a range replaces that.
    const later_range = try parseCMap(a, testing.allocator, "1 beginbfchar <0001> <0041> endbfchar 1 beginbfrange <0000> <FFFF> <0061> endbfrange", 16);
    try testing.expectEqualSlices(u21, &.{'b'}, later_range.lookup(1, 2, &buf).?);
    const later_char = try parseCMap(a, testing.allocator, "1 beginbfrange <0000> <FFFF> <0061> endbfrange 1 beginbfchar <0001> <0041> endbfchar", 16);
    try testing.expectEqualSlices(u21, &.{'A'}, later_char.lookup(1, 2, &buf).?);
    // A destination of 33 characters is refused, not dropped.
    const long = comptime l: {
        const codes: [33][4]u8 = @splat("0041".*);
        break :l "1 beginbfchar <0001> <" ++ @as(*const [132]u8, @ptrCast(&codes)) ++ "> endbfchar";
    };
    try testing.expectError(error.UnsupportedFont, parseCMap(a, testing.allocator, long, 16));
    // More large ranges than max_large_ranges.
    var many: std.Io.Writer.Allocating = .init(a);
    try many.writer.writeAll("4097 beginbfrange\n");
    for (0..max_large_ranges + 1) |i| try many.writer.print("<{X:0>8}> <{X:0>8}> <0041>\n", .{ i * 1000, i * 1000 + 999 });
    try many.writer.writeAll("endbfrange");
    try testing.expectError(error.TooLarge, parseCMap(a, testing.allocator, many.written(), 16));
}

test "fonts: /FirstChar out of range, Symbol widths by glyph name, no guessed encoding for a symbolic font" {
    const gpa = testing.allocator;
    const content =
        \\BT /F1 10 Tf 0 100 Td (AB) Tj ET
        \\BT /F2 10 Tf 0 80 Td (A) Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 8 0 R] /Count 2 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >> >> >>",
        streamObject("", content),
        // Code 65 drawn with Symbol's "space" (250), not "Alpha" (722).
        "<< /Type /Font /Subtype /Type1 /BaseFont /Symbol /Encoding << /Differences [65 /space] >> >>",
        // Not standard, not embedded, Symbolic flag: its built-in encoding is unknown.
        "<< /Type /Font /Subtype /Type1 /BaseFont /Wingish /FontDescriptor 9 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 9223372036854775807 /Widths [1 2] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 10 0 R /Resources << /Font << /F3 7 0 R >> >> >>",
        "<< /Type /FontDescriptor /FontName /Wingish /Flags 4 >>",
        streamObject("", "BT /F3 10 Tf (A) Tj ET"),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    // Symbol: code 65 is "space" (250), code 66 its own "Beta" (667): (0.25 + 0.667) * 10.
    try testing.expectEqualStrings(" \u{392}", pt.runs[0].text);
    try testing.expectApproxEqAbs(@as(f64, 2.5), pt.runs[0].glyphs[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 9.17), pt.runs[0].width.?, 1e-9);
    try testing.expectEqualStrings("\u{fffd}", pt.runs[1].text);
    try testing.expectEqual(@as(u32, 1), pt.runs[1].unmapped);
    // /FirstChar past 255: refused, not an overflow.
    try testing.expectError(error.Malformed, r.pageText(gpa, 1));
}

test "the interpreter: budgets, finite results, forms keep their q/Q and BMC/EMC, gs sets the font" {
    const gpa = testing.allocator;
    // 1e308 written out: PDF numbers have no exponent form.
    const big = "1" ++ @as([308]u8, @splat('0'));
    const page0 =
        \\q 1 0 0 1 100 0 cm /X1 Do Q
        \\BT /F1 10 Tf 0 0 Td (A) Tj ET
        \\/Span << /ActualText (z) >> BDC /X1 Do BT /F1 10 Tf 0 20 Td (A) Tj ET EMC
        \\BT /GS1 gs 0 40 Td (A) Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 6 0 R 9 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R /F2 10 0 R >> /XObject << /X1 7 0 R >> /ExtGState << /GS1 << /Font [5 0 R 12] >> >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        streamObject("", page0),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>",
        // A form whose Q and EMC have nothing of its own to close.
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 1 1]", "Q EMC"),
        // The text matrix's scale is finite, the size it gives is not; the origin stays 0, 0.
        streamObject("", "BT /F1 10 Tf 1 0 " ++ big ++ " " ++ big ++ " 0 0 Tm (A) Tj ET"),
        "<< /Type /Page /Parent 2 0 R /Contents 11 0 R >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /T /Encoding /Identity-H /DescendantFonts [12 0 R] >>",
        streamObject("", "BT /F2 10 Tf <000100> Tj ET"),
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /T >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 3), pt.runs.len);
    // The form's Q could not pop the page's q: the page's Q restores, and A is at 0.
    try testing.expectApproxEqAbs(@as(f64, 0), pt.runs[0].x, 1e-9);
    // The form's EMC could not close the page's span: A is replaced by "z".
    try testing.expectEqualStrings("z", pt.runs[1].text);
    // gs /GS1 set Helvetica at 12.
    try testing.expectApproxEqAbs(@as(f64, 12), pt.runs[2].size, 1e-9);
    // Matrices of finite numbers whose product is not finite: refused, for the size here and
    // for the origin below.
    try testing.expectError(error.Malformed, r.pageText(gpa, 1));
    const far = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        // The origin is 1e308 * 10: past f64; the size (10, by an unscaled matrix) is finite.
        streamObject("", "10 0 0 1 0 0 cm BT /F1 1 Tf 1 0 0 1 " ++ big ++ " 0 Tm (A) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    }, "");
    defer gpa.free(far);
    var rf = try Reader.open(gpa, far, .{});
    defer rf.deinit();
    try testing.expectError(error.Malformed, rf.pageText(gpa, 0));
    // An odd byte at the end of a two-byte font's string: refused.
    try testing.expectError(error.Malformed, r.pageText(gpa, 2));
    var few_ops = try Reader.open(gpa, pdf, .{ .max_operations = 5 });
    defer few_ops.deinit();
    try testing.expectError(error.TooLarge, few_ops.pageText(gpa, 0));
    var few_glyphs = try Reader.open(gpa, pdf, .{ .max_page_glyphs = 2 });
    defer few_glyphs.deinit();
    try testing.expectError(error.TooLarge, few_glyphs.pageText(gpa, 0));
}

test "a PageText outlives its reader and the file's bytes" {
    const gpa = testing.allocator;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        streamObject("", "BT /F1 10 Tf (A) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    }, "");
    var r = try Reader.open(gpa, pdf, .{});
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    // The font name came from the file, through the reader; both are gone now. A name still
    // pointing there would read freed memory, which the testing allocator overwrites.
    r.deinit();
    gpa.free(pdf);
    try testing.expectEqualStrings("Helvetica", pt.runs[0].font);
    try testing.expectEqualStrings("A", pt.runs[0].text);
}

test "a PageText holds its result, not the page's work" {
    // A page whose work far outweighs its text: 5000 dash-pattern operators (about 110 KB of
    // content, each an array) and one short line. The content, tokens and lists are freed when
    // pageText returns, so the arena holds the run, its text and glyphs and the font name. Kept,
    // the work would be at least the content's 110 KB. The bound does not depend on how the
    // arena sizes its blocks, which changed between Zig 0.16 and 0.17.
    const gpa = testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    for (0..5000) |_| try content.appendSlice(gpa, "[1 2 3 4 5 6 7 8] 0 d\n");
    try content.appendSlice(gpa, "BT /F1 12 Tf 72 720 Td (Hello) Tj ET\n");
    const stream = try std.fmt.allocPrint(gpa, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ content.items.len, content.items });
    defer gpa.free(stream);
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        stream,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 1), pt.runs.len);
    try testing.expectEqualStrings("Hello", pt.runs[0].text);
    var used: usize = pt.runs.len * @sizeOf(TextRun);
    for (pt.runs) |run| used += run.text.len + run.font.len + run.glyphs.len * @sizeOf(Glyph);
    try testing.expect(pt.arena.queryCapacity() <= 16 * 1024 + 4 * used);
    try testing.expect(content.items.len > 100 * 1024);
}

test "glyph names: uniXXXX and uXXXX[XX] take uppercase hex and real characters only (AGL specification)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(u21, &.{0xE9}, (try glyphNameChars(a, "uni00E9", 0)).?);
    try testing.expectEqualSlices(u21, &.{ 0x66, 0x69 }, (try glyphNameChars(a, "uni00660069", 0)).?);
    try testing.expectEqualSlices(u21, &.{0x1F600}, (try glyphNameChars(a, "u1F600", 0)).?);
    // Lowercase hex, a surrogate, and a value past U+10FFFF name no character.
    try testing.expectEqual(@as(?[]const u21, null), try glyphNameChars(a, "uni00e9", 0));
    try testing.expectEqual(@as(?[]const u21, null), try glyphNameChars(a, "uniD800", 0));
    try testing.expectEqual(@as(?[]const u21, null), try glyphNameChars(a, "u110000", 0));
}

test "text strings: UTF-16BE surrogate pairs decode, and a lone half is U+FFFD" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\u{1F600}A", try textString(a, "\xFE\xFF\xD8\x3D\xDE\x00\x00A"));
    try testing.expectEqualStrings("\u{FFFD}A", try textString(a, "\xFE\xFF\xD8\x00\x00A"));
    try testing.expectEqualStrings("\u{FFFD}A", try textString(a, "\xFE\xFF\xDC\x00\x00A"));
    try testing.expectEqualStrings("A\u{FFFD}", try textString(a, "\xFE\xFF\x00A\xD8\x3D"));
}

test "CID fonts: an Adobe character collection maps CIDs to text without /ToUnicode" {
    // One Identity-H font per collection, each drawing CID 0x0022 (A in all five, through the
    // range <0001> -> U+0020) and one CID from the table's single mappings. F6 has /ToUnicode for
    // 0x0022 only: it wins there, and the collection gives the rest. F7's registry is not Adobe:
    // nothing maps.
    const gpa = testing.allocator;
    const content =
        \\BT /F1 10 Tf 0 700 Td <00220619> Tj ET
        \\BT /F2 10 Tf 0 680 Td <00220391> Tj ET
        \\BT /F3 10 Tf 0 660 Td <002203F2> Tj ET
        \\BT /F4 10 Tf 0 640 Td <0022> Tj ET
        \\BT /F5 10 Tf 0 620 Td <002203F2> Tj ET
        \\BT /F6 10 Tf 0 600 Td <00220619> Tj ET
        \\BT /F7 10 Tf 0 580 Td <00220619> Tj ET
    ;
    const tounicode = "1 beginbfchar <0022> <005A> endbfchar";
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R /F4 8 0 R /F5 9 0 R /F6 10 0 R /F7 11 0 R >> >> >>",
        streamObject("", content),
        "<< /Type /Font /Subtype /Type0 /BaseFont /J /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /J /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 7 >> >>] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /G /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /G /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 5 >> >>] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /C /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /C /CIDSystemInfo << /Registry (Adobe) /Ordering (CNS1) /Supplement 7 >> >>] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /K /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /K /CIDSystemInfo << /Registry (Adobe) /Ordering (Korea1) /Supplement 2 >> >>] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /R /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /R /CIDSystemInfo << /Registry (Adobe) /Ordering (KR) /Supplement 9 >> >>] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /T /Encoding /Identity-H /ToUnicode 12 0 R /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /T /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 7 >> >>] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /N /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /N /CIDSystemInfo << /Registry (Test) /Ordering (Japan1) /Supplement 0 >> >>] >>",
        streamObject("", tounicode),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    const want = [_]struct { []const u8, u32 }{
        .{ "A\u{4E38}", 0 },
        .{ "A\u{00E9}", 0 },
        .{ "A\u{7070}", 0 },
        .{ "A", 0 },
        .{ "A\u{B7B0}", 0 },
        .{ "Z\u{4E38}", 0 },
        .{ "\u{FFFD}\u{FFFD}", 2 },
    };
    try testing.expectEqual(want.len, pt.runs.len);
    for (want, pt.runs) |w, run| {
        try testing.expectEqualStrings(w[0], run.text);
        try testing.expectEqual(w[1], run.unmapped);
    }
}

test "parseCMap frees each operator's tokens: a CMap's peak does not grow with its blocks" {
    // `gpa` holds only the tokens (the mappings go to the arena), so its peak is one block's
    // tokens when they are freed operator by operator, and all of them when they are not.
    const Counting = @import("abi.zig").Counting;
    var peaks: [2]usize = undefined;
    for ([_]usize{ 10, 100 }, &peaks) |blocks, *peak| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        var code: u32 = 0;
        for (0..blocks) |_| {
            try text.appendSlice(testing.allocator, "100 beginbfchar\n");
            for (0..100) |_| {
                try text.print(testing.allocator, "<{X:0>4}> <{X:0>4}>\n", .{ code, 0x4E00 + code });
                code += 1;
            }
            try text.appendSlice(testing.allocator, "endbfchar\n");
        }
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var counting: Counting = .{ .child = testing.allocator };
        const cm = try parseCMap(arena.allocator(), counting.allocator(), text.items, 16);
        try testing.expectEqual(blocks * 100, cm.chars.count());
        peak.* = counting.peak;
        try testing.expectEqual(@as(usize, 0), counting.live);
    }
    try testing.expect(peaks[1] < peaks[0] * 2);
}

test "an embedded Type 1 font's built-in encoding comes from its program's cleartext /Encoding" {
    // The cleartext part of a Type 1 program is all type1Encoding reads; what follows eexec is
    // encrypted and stays unread. F1 has no /Encoding: codes 65 and 66 are B and fi as the
    // program's array says. F2's /Differences gives 65 a name, and 66 still comes from the
    // program. F3's program says StandardEncoding. F4 is TrueType, which is not read: unmapped.
    // F5's program has no /Length1, so only eexec ends its cleartext.
    const gpa = testing.allocator;
    // `67 /Z put` lacks its dup: not an entry. What follows eexec is not read even when it
    // looks like one, and even with no /Length1 to stop at.
    const cleartext = "%!FontType1-1.0: T\n/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\ndup 65 /B put\ndup 66 /fi put\n67 /Z put\nreadonly def\ncurrentdict end\ncurrentfile eexec\n";
    const array_program = cleartext ++ "dup 68 /Y put\n";
    const standard_program = "%!FontType1-1.0: S\n/Encoding StandardEncoding def\ncurrentfile eexec\n";
    const content =
        \\BT /F1 10 Tf 0 700 Td (ABCD) Tj ET
        \\BT /F2 10 Tf 0 680 Td (AB) Tj ET
        \\BT /F3 10 Tf 0 660 Td (AB) Tj ET
        \\BT /F4 10 Tf 0 640 Td (AB) Tj ET
        \\BT /F5 10 Tf 0 620 Td (ABCD) Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R /F4 8 0 R /F5 11 0 R >> >> >>",
        streamObject("", content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+T /FontDescriptor << /Flags 4 /FontFile 9 0 R >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+T /Encoding << /Differences [65 /C] >> /FontDescriptor << /Flags 4 /FontFile 9 0 R >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+S /FontDescriptor << /Flags 32 /FontFile 10 0 R >> >>",
        "<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+U /FontDescriptor << /Flags 4 /FontFile2 9 0 R >> >>",
        streamObject(std.fmt.comptimePrint("/Length1 {d}", .{cleartext.len}), array_program),
        streamObject("", standard_program),
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+T /FontDescriptor << /Flags 4 /FontFile 12 0 R >> >>",
        streamObject("", array_program),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    const want = [_]struct { []const u8, u32 }{
        .{ "B\u{FB01}\u{FFFD}\u{FFFD}", 2 },
        .{ "C\u{FB01}", 0 },
        .{ "AB", 0 },
        .{ "\u{FFFD}\u{FFFD}", 2 },
        .{ "B\u{FB01}\u{FFFD}\u{FFFD}", 2 },
    };
    try testing.expectEqual(want.len, pt.runs.len);
    for (want, pt.runs) |w, run| {
        try testing.expectEqualStrings(w[0], run.text);
        try testing.expectEqual(w[1], run.unmapped);
    }
}

test "CidTable: every CID reads as the source CMap does, in all five collections" {
    // The build compiled src/cid to the embedded tables; this parses the same files with
    // parseCMap and asks both about every two-byte code.
    const gpa = testing.allocator;
    const options = @import("build_options");
    for (cid_orderings, cid_table_data) |ordering, data| {
        const path = try std.fmt.allocPrint(gpa, "{s}/Adobe-{s}-UCS2", .{ options.cid_dir, ordering });
        defer gpa.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 24));
        defer gpa.free(text);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const cm = try parseCMap(arena.allocator(), gpa, text, 64);
        const table: CidTable = .{ .bytes = data };
        var mapped: usize = 0;
        var want_buf: [max_chars]u21 = undefined;
        var got_buf: [max_chars]u21 = undefined;
        for (0..0x10000) |cid| {
            const want = cm.lookup(@intCast(cid), 2, &want_buf);
            const got = table.lookup(@intCast(cid), &got_buf);
            if (want) |w| {
                try testing.expectEqualSlices(u21, w, got.?);
                mapped += 1;
            } else try testing.expectEqual(@as(?[]const u21, null), got);
        }
        // Each collection maps thousands of CIDs: the comparison covered real tables.
        try testing.expect(mapped > 10_000);
        try testing.expectEqual(@as(?[]const u21, null), table.lookup(0x10000, &got_buf));
    }
}

/// Tests: a PDF of `pages` pages, each the 5000 dash-pattern operators of "a PageText holds its
/// result" (about 110 KB of content) and one short line. The content is /ASCIIHexDecode, so each
/// page decodes it into its work memory: an unfiltered stream is read where it lies in the file and
/// would need no work memory for its content at all.
fn heavyPagesPdf(gpa: Allocator, pages: usize) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..5000) |_| try raw.appendSlice(gpa, "[1 2 3 4 5 6 7 8] 0 d\n");
    try raw.appendSlice(gpa, "BT /F1 12 Tf 72 720 Td (Hello) Tj ET\n");
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    for (raw.items) |byte| try content.print(gpa, "{x:0>2}", .{byte});
    try content.append(gpa, '>');
    var bodies: std.ArrayList([]const u8) = .empty;
    defer {
        for (bodies.items[2..]) |b| gpa.free(b);
        bodies.deinit(gpa);
    }
    try bodies.append(gpa, "<< /Type /Catalog /Pages 2 0 R >>");
    var kids: std.Io.Writer.Allocating = .init(gpa);
    defer kids.deinit();
    for (0..pages) |i| try kids.writer.print("{d} 0 R ", .{4 + 2 * i});
    try bodies.append(gpa, "");
    try bodies.append(gpa, try std.fmt.allocPrint(gpa, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>", .{}));
    for (0..pages) |i| {
        try bodies.append(gpa, try std.fmt.allocPrint(gpa, "<< /Type /Page /Parent 2 0 R /Contents {d} 0 R /Resources << /Font << /F1 3 0 R >> >> >>", .{5 + 2 * i}));
        try bodies.append(gpa, try std.fmt.allocPrint(gpa, "<< /Length {d} /Filter /ASCIIHexDecode >>\nstream\n{s}\nendstream", .{ content.items.len, content.items }));
    }
    const tree = try std.fmt.allocPrint(gpa, "<< /Type /Pages /Kids [{s}] /Count {d} /MediaBox [0 0 612 792] >>", .{ kids.written(), pages });
    defer gpa.free(tree);
    bodies.items[1] = tree;
    return read.test_util.build(gpa, bodies.items, "");
}

test "the reader keeps at most max_retained_work of page work between pages" {
    const gpa = testing.allocator;
    const pdf = try heavyPagesPdf(gpa, 1);
    defer gpa.free(pdf);
    // The default keeps the page's work for the next page: more than a small block, so the
    // limits below are tested against real kept memory, and no more than the limit.
    {
        var r = try Reader.open(gpa, pdf, .{});
        defer r.deinit();
        var pt = try r.pageText(gpa, 0);
        pt.deinit();
        const kept = r.work_state.queryCapacity();
        try testing.expect(kept > 64 * 1024);
        try testing.expect(kept <= (read.Options{}).max_retained_work);
    }
    for ([_]usize{ 0, 16 * 1024 }) |limit| {
        var r = try Reader.open(gpa, pdf, .{ .max_retained_work = limit });
        defer r.deinit();
        var pt = try r.pageText(gpa, 0);
        pt.deinit();
        try testing.expect(r.work_state.queryCapacity() <= limit);
    }
}

test "pageRuns twice without endPageRuns holds one page's work, not two" {
    const gpa = testing.allocator;
    const pdf = try heavyPagesPdf(gpa, 2);
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    const first = try r.pageRuns(0);
    try testing.expectEqualStrings("Hello", first.runs[0].text);
    const one = r.work_state.queryCapacity();
    // No endPageRuns: the next page ends the first itself.
    const second = try r.pageRuns(1);
    try testing.expectEqualStrings("Hello", second.runs[0].text);
    try testing.expect(r.work_state.queryCapacity() < one + one / 2);
    r.endPageRuns();
}

test "pages after the first ask the allocator for no large block" {
    // Each page needs more than 64 KiB of work. Before the reader kept its work arena, every page
    // grew a new one through several such blocks, a system call each under an allocator that maps
    // them directly (std.heap.smp_allocator), and reading was measurably slower under it.
    const Large = struct {
        child: Allocator,
        count: usize = 0,
        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (len >= 64 * 1024) self.count += 1;
            return self.child.rawAlloc(len, a, ra);
        }
        // Not counted: growing in place under std.heap.smp_allocator either stays inside its
        // pages or fails, with no system call (PageAllocator.realloc, may_move = false).
        fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.child.rawResize(m, a, n, ra);
        }
        fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (n > m.len and n >= 64 * 1024) self.count += 1;
            return self.child.rawRemap(m, a, n, ra);
        }
        fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.rawFree(m, a, ra);
        }
    };
    const gpa = testing.allocator;
    const pdf = try heavyPagesPdf(gpa, 6);
    defer gpa.free(pdf);
    var large: Large = .{ .child = gpa };
    var r = try Reader.open(large.allocator(), pdf, .{});
    defer r.deinit();
    var first = try r.pageText(large.allocator(), 0);
    first.deinit();
    // The first page did need large blocks, so a zero below is the reuse, not a small page.
    try testing.expect(large.count > 0);
    large.count = 0;
    for (1..6) |i| {
        var pt = try r.pageText(large.allocator(), i);
        defer pt.deinit();
        try testing.expectEqualStrings("Hello", pt.runs[0].text);
    }
    try testing.expectEqual(@as(usize, 0), large.count);
}
