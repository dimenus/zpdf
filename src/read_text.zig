//! zpdf.read's text: the text a page draws, as runs with positions (Reader.pageText).
//!
//! A run is one text-showing operator (Tj, TJ, ' or "), as drawn: its text in Unicode, where its
//! first glyph's origin is (after any TJ adjustment before it), its size and its advance. An
//! operator that shows no glyph makes no run. The glyphs inside a marked-content span with
//! /ActualText make one run whose text is the ActualText; a span that draws no glyph but an image
//! makes a run placed on the image, with no glyphs. The ActualText is the span's own, else that
//! of the structure element its /MCID names (14.7.4.4). Runs come in content-stream order, which
//! is not always reading order: readers that agree on the text disagree on its order (MuPDF
//! keeps content order, Poppler sorts by position), so ordering is left to the caller. No space
//! is invented between runs or for a large TJ gap; the caller decides what a gap means.
//!
//! Coordinates are default user space: points, y up, the page's own origin (a MediaBox need not
//! start at 0, 0), before /Rotate. Form XObjects are drawn into the page with their /Matrix.
//!
//! Characters come from the font's /ToUnicode CMap when it has one, else from its encoding
//! (/Encoding, /Differences, the Adobe Glyph List for glyph names, WinAnsi, MacRoman, Standard).
//! A Type0 font's /Encoding CMap (src/cmap.zig: one of the standard's predefined CMaps, or a CMap
//! stream) splits its strings into codes and maps each code to a CID. A Type0 font whose CIDFont
//! has an Adobe character collection (Japan1, GB1, CNS1, Korea1, KR) maps a code /ToUnicode does
//! not have through Adobe's CID-to-Unicode CMap for that collection (9.10.2; src/cid, compiled to
//! a CidTable at build time). A code with none of these, or with no CID mapping, is U+FFFD in the
//! text and counted in `unmapped`; a code with no CID mapping still draws a glyph, CID 0's or
//! its notdef mapping's (9.7.6.3), and moves the text position by that glyph's width. Widths
//! come from /Widths or /W (by CID), and for the 14 standard fonts with no /Widths from Adobe's
//! AFM metrics (read_tables.zig).
//!
//! Refused: a Type0 font whose /Encoding names a CMap that is not one of the standard's predefined
//! ones, or a CMap stream that uses one (error.UnsupportedFont: without its CMap the codes cannot
//! even be split into characters), and anything zpdf.read refuses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const read = @import("read.zig");
const cmap = @import("cmap.zig");
const cff = @import("cff.zig");
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
    /// For an ActualText run placed on an image, the image's height.
    size: f64,
    /// From the first glyph's origin to where the next glyph would start, in user space. null
    /// when a glyph's width is unknown (a font with no width for one of its codes).
    width: ?f64,
    /// The font's /BaseFont, or "" when it has none.
    font: []const u8,
    /// Codes with no Unicode mapping, or whose /ToUnicode gives half of a UTF-16 surrogate pair
    /// that the next code does not complete; each is U+FFFD in `text`.
    unmapped: u32,
    /// Each glyph's origin, in default user space, in drawing order. None for an ActualText run
    /// placed on an image: its x and y are the image's bottom-left corner, its width the image's.
    glyphs: []const Glyph,
    /// The text is a marked-content span's /ActualText (14.9.4), which replaces what its glyphs
    /// map to; the run covers every glyph drawn inside the span. zpdf writes one around each
    /// cluster whose glyphs are not in text order (Indic reordering, marks).
    actual_text: bool,
    /// Vertical writing (/Identity-V, 9.7.4.3): each glyph moves the text position along text
    /// space's y axis, down for the usual negative displacement. A glyph's origin is that text
    /// position, which is the glyph's vertical origin, not the horizontal origin its outline is
    /// drawn from. An ActualText run is vertical when its first run was.
    vertical: bool,
    /// Drawn by an annotation's appearance stream (12.5.5), such as a form field's value or a
    /// stamp, not by the page's content stream. Its runs follow the page's.
    annotation: bool,
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
    /// Type0: its /Encoding CMap (src/cmap.zig), which splits strings into codes and gives each
    /// code's CID. null for a simple font, whose codes are single bytes.
    code_map: ?cmap.Map,
    /// The CMap's /WMode is 1: vertical writing.
    vertical: bool,
    to_unicode: ?CMap,
    /// Type0 with an Adobe character collection: Adobe's CID-to-Unicode table for it, static
    /// data built from src/cid, by CID.
    cid_unicode: ?CidTable,
    /// Simple fonts: the characters of each code from the encoding (null: none).
    encoding: [256]?[]const u21,
    /// Simple fonts: width in 1/1000 text space units per code, from /Widths or the standard
    /// font metrics (null: unknown).
    simple_widths: [256]?f64,
    /// Type0: /W, as sorted ranges, and /DW.
    cid_widths: []const CidRange,
    default_width: f64,
    /// Type0 with a vertical CMap: each CID's vertical displacement w1, from /W2 as sorted ranges, and
    /// /DW2's (9.7.4.3). The position vectors in /W2 and /DW2 place the glyph's outline relative
    /// to the text position and do not move it, so they are not kept.
    cid_v_displacements: []const CidRange,
    default_v_displacement: f64,

    const CidRange = struct { first: u32, last: u32, widths: []const f64 };

    /// One code taken from a string, and for a Type0 font its CIDs.
    const Shown = struct {
        code: u32,
        len: u3,
        /// The CID its mappings select; null when it has none, which leaves it with no character
        /// but the ToUnicode CMap's.
        cid: ?u16,
        /// The CID whose glyph is drawn: `cid`, else its notdef mapping's, else 0.
        glyph: u16,
    };

    /// The code at the start of `s`, which must not be empty.
    fn take(self: *const Font, s: []const u8) Shown {
        const m = self.code_map orelse return .{ .code = s[0], .len = 1, .cid = null, .glyph = 0 };
        const c = m.split(s);
        const mapped = m.cid(c);
        return .{ .code = c.value, .len = c.len, .cid = mapped, .glyph = mapped orelse m.notdef(c) orelse 0 };
    }

    fn width(self: *const Font, g: Shown) ?f64 {
        if (self.code_map == null) return self.simple_widths[g.code];
        return cidMetric(self.cid_widths, g.glyph) orelse self.default_width;
    }

    /// The vertical displacement w1 of a vertical font's glyph.
    fn vDisplacement(self: *const Font, g: Shown) f64 {
        return cidMetric(self.cid_v_displacements, g.glyph) orelse self.default_v_displacement;
    }

    fn cidMetric(ranges: []const CidRange, code: u32) ?f64 {
        var lo: usize = 0;
        var hi: usize = ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = ranges[mid];
            if (code < r.first) {
                hi = mid;
            } else if (code > r.last) {
                lo = mid + 1;
            } else return if (r.widths.len == 1) r.widths[0] else r.widths[code - r.first];
        }
        return null;
    }

    fn unicode(self: *const Font, g: Shown, buf: *[max_chars]u21) ?[]const u21 {
        if (self.to_unicode) |cm| {
            if (cm.lookup(g.code, g.len, buf)) |u| return u;
        }
        if (self.code_map == null) return self.encoding[g.code];
        const cid = g.cid orelse return null;
        // Comptime-false in zpdf.wasm, so the lookup is not compiled there.
        if (cid_tables) if (self.cid_unicode) |t| return t.lookup(cid, buf);
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
    /// A definition of U+0000 alone is null, as if the code had none: producers write <0000> for
    /// a glyph with no character, and a NUL in the text would hide that the glyph is unmapped.
    pub fn lookup(self: *const CMap, code: u32, len: u8, buf: *[max_chars]u21) ?[]const u21 {
        const u = self.latest(code, len, buf) orelse return null;
        if (u.len == 1 and u[0] == 0) return null;
        return u;
    }

    fn latest(self: *const CMap, code: u32, len: u8, buf: *[max_chars]u21) ?[]const u21 {
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

/// UTF-16BE to code points; an unpaired surrogate half is kept: Interp.show joins a ToUnicode
/// high half with the next glyph's low half and counts any other half as unmapped, and a text
/// string's half becomes U+FFFD through appendUtf8. Into `arena`: the result is a list's items,
/// not a single allocation a caller could free.
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

/// The characters a glyph name stands for: for a ZapfDingbats font, the ITC Zapf Dingbats Glyph
/// List first (the AGL Specification's order, so its a1 to a191 are dingbats); then the Adobe
/// Glyph List, then uniXXXX (one or more groups of four), uXXXX to uXXXXXX, then ligatures (a_b)
/// and variants (a.sc) by their parts. Into `arena`: the result is a list's items, and parts of a
/// failed name are left there.
fn glyphNameChars(arena: Allocator, name: []const u8, zapf_dingbats: bool, depth: u32) Error!?[]const u21 {
    const a = arena;
    if (depth > 4) return null;
    if (zapf_dingbats) if (nameLookup(&tables.zapf_dingbats_names, name)) |cp| return try a.dupe(u21, &.{cp});
    if (nameLookup(&tables.glyph_names, name)) |cp| return try a.dupe(u21, &.{cp});
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        if (dot == 0) return null;
        return glyphNameChars(a, name[0..dot], zapf_dingbats, depth + 1);
    }
    if (std.mem.indexOfScalar(u8, name, '_') != null) {
        var out: std.ArrayList(u21) = .empty;
        var parts = std.mem.splitScalar(u8, name, '_');
        while (parts.next()) |part| {
            const u = (try glyphNameChars(a, part, zapf_dingbats, depth + 1)) orelse return null;
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

fn nameLookup(table: []const tables.GlyphName, name: []const u8) ?u21 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, table[mid].name, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return table[mid].cp,
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
        .code_map = null,
        .vertical = false,
        .to_unicode = null,
        .cid_unicode = null,
        .encoding = @splat(null),
        .simple_widths = @splat(null),
        .cid_widths = &.{},
        .default_width = 1000,
        .cid_v_displacements = &.{},
        .default_v_displacement = -1000,
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
    const m = try encodingCMap(r, (try r.getResolved(dict, "Encoding")) orelse return error.Malformed, 0);
    f.code_map = m;
    f.vertical = m.vertical();
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
    if (try r.getResolved(cid, "W")) |w| f.cid_widths = try cidMetrics(r, w, 1);
    if (!f.vertical) return;
    // /DW2 [v_y w1] and /W2 groups of [w1 v_x v_y] (9.7.4.3).
    if (try r.getResolved(cid, "DW2")) |dw2| {
        const pair = switch (dw2) {
            .array => |arr| arr,
            else => return error.Malformed,
        };
        if (pair.len != 2) return error.Malformed;
        f.default_v_displacement = (try r.resolve(pair[1])).number() orelse return error.Malformed;
    }
    if (try r.getResolved(cid, "W2")) |w2| f.cid_v_displacements = try cidMetrics(r, w2, 3);
}

/// /W or /W2 (9.7.4.3) as sorted ranges of each CID's first number: `c [n ...]` gives CIDs from
/// c on, `stride` numbers each; `c_first c_last n ...` gives every CID in the range `stride`
/// numbers. A CID the array gives more than once takes its last value, as a ToUnicode code
/// defined twice does (CMap.lookup): pdfminer and pdf.js read /W the same way; which one MuPDF
/// keeps depends on how its unstable sort orders the two.
fn cidMetrics(r: *Reader, obj: Object, stride: usize) Error![]const Font.CidRange {
    const a = r.arenaAllocator();
    const w = switch (obj) {
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
                if (list.len % stride != 0) return error.Malformed;
                const n = list.len / stride;
                if (n == 0) {
                    i += 2;
                    continue;
                }
                if (@as(u64, first) + n - 1 > 0xFFFF) return error.Malformed;
                const ws = try a.alloc(f64, n);
                for (ws, 0..) |*v, k| v.* = try firstOfGroup(r, list[k * stride ..][0..stride]);
                try ranges.append(a, .{ .first = first, .last = first + @as(u32, @intCast(n)) - 1, .widths = ws });
                i += 2;
            },
            else => {
                const last = try cidOf(r, w[i + 1]);
                if (i + 1 + stride >= w.len or last < first) return error.Malformed;
                const v = try firstOfGroup(r, w[i + 2 ..][0..stride]);
                try ranges.append(a, .{ .first = first, .last = last, .widths = try a.dupe(f64, &.{v}) });
                i += 2 + stride;
            },
        }
    }
    // Writers almost always give the entries in order with no overlap; those are kept as they
    // are, with no work beyond this check, and only the others are swept.
    const in_order = for (ranges.items[@min(1, ranges.items.len)..], 0..) |e, k| {
        if (e.first <= ranges.items[k].last) break false;
    } else true;
    if (in_order) return ranges.items;
    var scratch: std.heap.ArenaAllocator = .init(r.arena_state.child_allocator);
    defer scratch.deinit();
    return disjointLatest(a, scratch.allocator(), ranges.items);
}

/// `entries`, in the order the file gives them, as ranges that do not overlap, sorted by first
/// CID, where each CID keeps the value of the last entry that covers it (Font.cidMetric's binary
/// search needs both). The result and the width lists it points into are in `arena`; `scratch`
/// holds the work. A sweep over the entries' ends with the covering entries in a heap by
/// position, so a hostile array costs n log n, not one shift of the list per entry.
fn disjointLatest(arena: Allocator, scratch: Allocator, entries: []const Font.CidRange) Error![]const Font.CidRange {
    // Every place where the entry in force can change: each first CID and each CID after a last.
    const bounds = try scratch.alloc(u32, entries.len * 2);
    for (entries, 0..) |e, k| {
        bounds[2 * k] = e.first;
        bounds[2 * k + 1] = e.last + 1;
    }
    std.mem.sort(u32, bounds, {}, std.sort.asc(u32));
    const by_first = try scratch.alloc(u32, entries.len);
    for (by_first, 0..) |*o, k| o.* = @intCast(k);
    std.mem.sort(u32, by_first, entries, struct {
        fn lt(es: []const Font.CidRange, x: u32, y: u32) bool {
            return es[x].first < es[y].first;
        }
    }.lt);
    // The entries that cover the current CID, the latest on top.
    var covering: std.PriorityQueue(u32, void, struct {
        fn later(_: void, x: u32, y: u32) std.math.Order {
            return std.math.order(y, x);
        }
    }.later) = .empty;
    var out: std.ArrayList(Font.CidRange) = .empty;
    var next: usize = 0;
    var b: usize = 0;
    while (b < bounds.len) {
        const at = bounds[b];
        var end = b + 1;
        while (end < bounds.len and bounds[end] == at) end += 1;
        if (end == bounds.len) break;
        // Every first CID is a bound, so an entry joins at its own first CID.
        while (next < by_first.len and entries[by_first[next]].first == at) : (next += 1) try covering.push(scratch, by_first[next]);
        while (covering.peek()) |top| {
            if (entries[top].last >= at) break;
            _ = covering.pop();
        }
        // The top covers all of at up to the next bound: its own last + 1 is a bound too.
        if (covering.peek()) |top| {
            const e = entries[top];
            const last = bounds[end] - 1;
            const widths = if (e.widths.len == 1) e.widths else e.widths[at - e.first .. last - e.first + 1];
            try out.append(arena, .{ .first = at, .last = last, .widths = widths });
        }
        b = end;
    }
    return out.items;
}

/// The first of a group of numbers; the others must be numbers too.
fn firstOfGroup(r: *Reader, group: []const Object) Error!f64 {
    for (group[1..]) |x| _ = (try r.resolve(x)).number() orelse return error.Malformed;
    return (try r.resolve(group[0])).number() orelse error.Malformed;
}

/// A Type0 font's /Encoding: a predefined CMap's name (Table 118; UnsupportedFont for any other
/// name), or a CMap stream, encoded into the reader's arena.
fn encodingCMap(r: *Reader, enc: Object, depth: u32) Error!cmap.Map {
    return switch (enc) {
        .name => |n| cmap.predefined(n) orelse error.UnsupportedFont,
        .stream => |s| {
            const gpa = r.arena_state.child_allocator;
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const resolved = try cmapStream(r, scratch.allocator(), s, depth);
            const bytes = if (resolved.parent) |p| try cmap.encodeOver(r.arenaAllocator(), &resolved.b, p) else try cmap.encode(r.arenaAllocator(), &resolved.b, cmap.no_parent);
            return cmap.fromStream(bytes);
        },
        else => error.Malformed,
    };
}

/// A CMap stream's definitions over those of the CMap it uses (its usecmap operator, else its
/// /UseCMap entry): a stream's are merged in; a predefined CMap is named by its index, and
/// answers what the stream does not map. Identity-H and Identity-V are merged in.
fn cmapStream(r: *Reader, a: Allocator, s: read.Stream, depth: u32) Error!struct { b: cmap.Builder, parent: ?u16 } {
    if (depth >= 4) return error.TooDeep;
    var b = try cmap.parse(a, r.arena_state.child_allocator, try r.streamData(s));
    const use: ?Object = if (b.usecmap) |n| Object{ .name = n } else try r.getResolved(s.dict, "UseCMap");
    const u = use orelse return .{ .b = b, .parent = null };
    switch (u) {
        .name => |n| {
            const vertical = std.mem.eql(u8, n, "Identity-V");
            if (vertical or std.mem.eql(u8, n, "Identity-H")) {
                var id: cmap.Builder = .{ .wmode = @intFromBool(vertical) };
                try id.codespace.append(a, .{ .len = 2, .lo = .{ 0, 0, 0, 0 }, .hi = .{ 0xFF, 0xFF, 0, 0 } });
                try id.map(a, 2, 0, 0xFFFF, 0);
                return .{ .b = try b.over(a, &id), .parent = null };
            }
            return .{ .b = b, .parent = cmap.predefinedIndex(n) orelse return error.UnsupportedFont };
        },
        .stream => |ps| {
            const base = try cmapStream(r, a, ps, depth + 1);
            return .{ .b = try b.over(a, &base.b), .parent = base.parent };
        },
        else => return error.Malformed,
    }
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

/// The built-in encoding of an embedded CFF program (/FontFile3 with /Subtype /Type1C): the glyph
/// name of each code (src/cff.zig), copied into the reader's arena. null when the font has no such
/// program, or cff.zig reads none from it. The program itself is decoded into scratch memory and
/// not kept.
fn cffEncoding(r: *Reader, dict: Dict) Error!?[256]?[]const u8 {
    const fd = (try r.getResolved(dict, "FontDescriptor")) orelse return null;
    if (fd != .dict) return error.Malformed;
    const program = switch ((try r.getResolved(fd.dict, "FontFile3")) orelse return null) {
        .stream => |s| s,
        else => return error.Malformed,
    };
    const subtype = (try r.getResolved(program.dict, "Subtype")) orelse return null;
    if (!(subtype == .name and std.mem.eql(u8, subtype.name, "Type1C"))) return null;
    var scratch: std.heap.ArenaAllocator = .init(r.arena_state.child_allocator);
    defer scratch.deinit();
    const data = try r.decodeStream(scratch.allocator(), program);
    const names = (try cff.builtinEncoding(scratch.allocator(), data)) orelse return null;
    var out: [256]?[]const u8 = @splat(null);
    for (names, &out) |n, *o| if (n) |name| {
        o.* = try r.arenaAllocator().dupe(u8, name);
    };
    return out;
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
    // embedded Type 1 program, the /Encoding in its cleartext; for an embedded CFF program
    // (/FontFile3 /Type1C), its own encoding and glyph names (src/cff.zig). An embedded TrueType
    // program is not read, and Standard is not guessed for it or for a program these do not read:
    // Ghostscript re-encodes its subsets, so the guess gives wrong letters with no sign of it.
    // Such codes get no base: unmapped unless /ToUnicode or /Differences says.
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
        if (try type1Encoding(r, dict)) |builtin| {
            names = builtin;
        } else if (try cffEncoding(r, dict)) |builtin| names = builtin;
    } else if (std_metrics == null and try isSymbolic(r, dict)) {
        // A symbolic font's built-in encoding is its own (9.6.6.2), not Standard: unknown too.
    } else if (std_metrics) |m| switch (m) {
        .symbolic => |s| names = s.names,
        .text => names = tables.standard_encoding,
    } else if (!type3) names = tables.standard_encoding;

    if (is_winansi) {
        for (0..256) |c| {
            // WinAnsiEncoding's unused codes above octal 40 (0x7F, 0x81, 0x8D, 0x8F, 0x90, 0x9D)
            // draw the glyph "bullet" (Annex D, its note 3); cp1252 leaves them undefined.
            const cp = winansi.decode(@intCast(c)) orelse if (c > 0o40) 0x2022 else continue;
            // WinAnsiEncoding draws 0xA0 with the glyph "space" and 0xAD with "hyphen" (Annex D,
            // its notes 6 and 5), and a glyph's name is what says its character (9.10.2): so
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
    const zapf_dingbats = if (std_metrics) |m| m == .symbolic and std.mem.eql(u8, m.symbolic.name, "ZapfDingbats") else false;
    for (0..256) |c| {
        if (names[c]) |n| f.encoding[c] = try glyphNameChars(a, n, zapf_dingbats, 0);
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
    /// The structure elements of the stream being run, by MCID: its /StructParents entry in the
    /// structure tree's /ParentTree (14.7.4.4). null when it has none.
    mcids: ?[]const Object = null,
    /// The runs being drawn are an annotation's (TextRun.annotation).
    annotation: bool = false,

    const Marked = struct {
        /// The span's /ActualText, as UTF-8, when it has one.
        actual: ?[]const u8,
        /// The first run drawn inside it.
        first_run: usize,
        /// The box, in user space, of the images drawn inside it: [x0, y0, x1, y1].
        image_box: ?[4]f64 = null,
    };

    /// An image is drawn, through the CTM's unit square (8.9.4): every open span's box grows to
    /// hold it.
    fn noteImage(self: *Interp) void {
        const m = self.gs.ctm;
        var box: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        for ([_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |c| {
            const x = c[0] * m[0] + c[1] * m[2] + m[4];
            const y = c[0] * m[1] + c[1] * m[3] + m[5];
            box = .{ @min(box[0], x), @min(box[1], y), @max(box[2], x), @max(box[3], y) };
        }
        if (!std.math.isFinite(box[0] + box[1] + box[2] + box[3])) return;
        for (self.marked.items) |*mk| {
            const b = mk.image_box orelse box;
            mk.image_box = .{ @min(b[0], box[0]), @min(b[1], box[1]), @max(b[2], box[2]), @max(b[3], box[3]) };
        }
    }

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
        // A word that starts like a number but is not one (`1.5-30`), among the operands of the
        // next operator. Writers make these in path coordinates; the operator is skipped, unless
        // it is one this reader acts on, which then refuses the page rather than guess a value.
        // A zero with a rounding residue's digits after it is 0 (isZeroWithResidue).
        var bad_operand = false;
        while (true) {
            lx.skipWhite();
            const start = lx.pos;
            const t = lx.next(a) catch |err| switch (err) {
                // The lexer reads a word from a number's first character and fails only when
                // the word is not a number; any other refusal (a string, a dictionary) stands.
                error.Malformed => if (start < content.len and read.isNumberStart(content[start])) {
                    if (isZeroWithResidue(content[start..lx.pos])) {
                        if (operands.items.len >= 1 << 16) return error.TooLarge;
                        try operands.append(self.scratch, .{ .real = 0 });
                    } else bad_operand = true;
                    continue;
                } else return err,
                else => return err,
            };
            switch (t) {
                .eof => break,
                .keyword => |word| {
                    const op = op_words.get(word);
                    if (op) |o| if (o == .true or o == .false or o == .null) {
                        try operands.append(self.scratch, try p.fromToken(t, 0));
                        continue;
                    };
                    self.operations += 1;
                    if (self.operations > self.r.options.max_operations) return error.TooLarge;
                    // Every other operator (paths, painting, colour, line style) draws no text.
                    if (op) |o| {
                        if (o == .BI) {
                            try skipInlineImage(&lx, a, self.r.options.max_depth);
                            self.noteImage();
                        } else if (bad_operand) {
                            return error.Malformed;
                        } else try self.operator(o, operands.items, resources, depth);
                    }
                    bad_operand = false;
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

    /// Whether `word` is a zero written with a dot, then '-' and digits only: `0.00-13322676`,
    /// `-0.000000000000-5684342`. A writer (Google Docs, by MuPDF's bug 703248) prints a value
    /// within rounding of zero as its fixed-point zero followed by the residue's significant
    /// digits without their exponent: 13322676 is 6 * 2^-52 = 1.3322676e-15, 5684342 is 2^-44.
    /// So the value is zero to within the residue. A nonzero part before the '-' (`1.5-30`)
    /// gives no such reading and stays a bad word.
    fn isZeroWithResidue(word: []const u8) bool {
        const body = if (word.len > 0 and (word[0] == '-' or word[0] == '+')) word[1..] else word;
        const dash = std.mem.indexOfScalar(u8, body, '-') orelse return false;
        const zero = body[0..dash];
        const residue = body[dash + 1 ..];
        if (std.mem.count(u8, zero, ".") != 1 or zero.len < 2 or residue.len == 0) return false;
        for (zero) |c| if (c != '0' and c != '.') return false;
        for (residue) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }

    fn num(ops: []const Object, i: usize) Error!f64 {
        if (i >= ops.len) return error.Malformed;
        const v = ops[i].number() orelse return error.Malformed;
        if (!std.math.isFinite(v)) return error.Malformed;
        return v;
    }

    /// The content-stream words the interpreter acts on, each spelled as its field name: the
    /// operators operator() runs, BI, and the keywords that are operands, found with one lookup
    /// per word (op_words, built at compile time from the names) instead of a string compare per
    /// name.
    const Op = enum { q, Q, cm, BT, Tf, Tc, Tw, Tz, TL, Ts, Td, TD, Tm, @"T*", Tj, TJ, @"'", @"\"", Do, gs, BMC, BDC, EMC, BI, true, false, null };
    const op_words = std.StaticStringMap(Op).initEnum();

    fn operator(self: *Interp, op: Op, ops: []const Object, resources: Dict, depth: u32) Error!void {
        switch (op) {
            // run() handles these itself.
            .BI, .true, .false, .null => unreachable,
            .q => {
                if (self.stack.items.len >= 1024) return error.TooDeep;
                try self.stack.append(self.scratch, self.gs);
            },
            .Q => {
                // An unbalanced Q is common and harmless: the state stays. A form's Q cannot pop
                // what the page saved.
                if (self.stack.items.len > self.stack_floor) self.gs = self.stack.pop().?;
            },
            .cm => {
                if (ops.len != 6) return error.Malformed;
                var m: Matrix = undefined;
                for (0..6) |i| m[i] = try num(ops, i);
                self.gs.ctm = mul(m, self.gs.ctm);
            },
            .BT => {
                self.tm = identity;
                self.tlm = identity;
            },
            .Tf => {
                if (ops.len != 2 or ops[0] != .name) return error.Malformed;
                const fonts = switch ((try self.r.getResolved(resources, "Font")) orelse return error.Malformed) {
                    .dict => |d| d,
                    else => return error.Malformed,
                };
                self.gs.font = try loadFont(self.r, fonts.get(ops[0].name) orelse return error.Malformed);
                self.gs.size = try num(ops, 1);
            },
            .Tc => {
                self.gs.char_spacing = try num(ops, 0);
            },
            .Tw => {
                self.gs.word_spacing = try num(ops, 0);
            },
            .Tz => {
                self.gs.h_scale = try num(ops, 0) / 100;
            },
            .TL => {
                self.gs.leading = try num(ops, 0);
            },
            .Ts => {
                self.gs.rise = try num(ops, 0);
            },
            .Td => {
                self.moveLine(try num(ops, 0), try num(ops, 1));
            },
            .TD => {
                self.gs.leading = -(try num(ops, 1));
                self.moveLine(try num(ops, 0), try num(ops, 1));
            },
            .Tm => {
                if (ops.len != 6) return error.Malformed;
                for (0..6) |i| self.tm[i] = try num(ops, i);
                self.tlm = self.tm;
            },
            .@"T*" => {
                self.moveLine(0, -self.gs.leading);
            },
            .Tj => {
                if (ops.len != 1 or ops[0] != .string) return error.Malformed;
                try self.show(&.{ops[0]});
            },
            .TJ => {
                if (ops.len != 1 or ops[0] != .array) return error.Malformed;
                try self.show(ops[0].array);
            },
            .@"'" => {
                if (ops.len != 1 or ops[0] != .string) return error.Malformed;
                self.moveLine(0, -self.gs.leading);
                try self.show(&.{ops[0]});
            },
            .@"\"" => {
                if (ops.len != 3 or ops[2] != .string) return error.Malformed;
                self.gs.word_spacing = try num(ops, 0);
                self.gs.char_spacing = try num(ops, 1);
                self.moveLine(0, -self.gs.leading);
                try self.show(&.{ops[2]});
            },
            .Do => {
                if (ops.len != 1 or ops[0] != .name) return error.Malformed;
                try self.drawXObject(ops[0].name, resources, depth);
            },
            .gs => {
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
            },
            .BMC => {
                try self.beginMarked(null);
            },
            .BDC => {
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
                    } else if (try self.elementActualText(d)) |at| actual = try textString(self.scratch, at);
                }
                try self.beginMarked(actual);
            },
            .EMC => {
                // An unbalanced EMC is ignored, as an unbalanced Q is, and a form's cannot close
                // what the page opened.
                if (self.marked.items.len <= self.marked_floor) return;
                const m = self.marked.pop().?;
                const actual = m.actual orelse return;
                // A span that drew no glyph but an image: its text is placed on the image.
                if (m.first_run >= self.runs.items.len) if (m.image_box) |b| {
                    try self.runs.append(self.scratch, .{
                        .text = actual,
                        .x = b[0],
                        .y = b[1],
                        .size = b[3] - b[1],
                        .width = b[2] - b[0],
                        .font = "",
                        .unmapped = 0,
                        .glyphs = &.{},
                        .actual_text = true,
                        .vertical = false,
                        .annotation = self.annotation,
                    });
                    try self.ends.append(self.scratch, .{ b[2], b[1] });
                };
                // A nested span merges first; an enclosing one then merges that run with the rest,
                // so the outermost ActualText is the text.
                try self.mergeActual(m.first_run, actual);
            },
        }
    }

    /// The /ActualText of the structure element a marked-content sequence belongs to by its
    /// /MCID (14.7.4.4, 14.9.4), when the sequence's own property list has none. The element is
    /// the stream's /ParentTree array at the MCID, and counts only when its /K lists that MCID:
    /// an array whose entries are out of place gives no text, rather than a guess at which entry
    /// was meant.
    fn elementActualText(self: *Interp, props: Dict) Error!?[]const u8 {
        const mcids = self.mcids orelse return null;
        const id = switch ((try self.r.getResolved(props, "MCID")) orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        if (id < 0 or id >= mcids.len) return null;
        const elem = switch (try self.r.resolve(mcids[@intCast(id)])) {
            .dict => |d| d,
            else => return null,
        };
        if (!try kHolds(self.r, (try self.r.getResolved(elem, "K")) orelse return null, id)) return null;
        const at = (try self.r.getResolved(elem, "ActualText")) orelse return null;
        return if (at == .string) at.string else null;
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
        if (subtype == .name and std.mem.eql(u8, subtype.name, "Image")) return self.noteImage();
        if (!(subtype == .name and std.mem.eql(u8, subtype.name, "Form"))) return;
        try self.drawForm(ref, s, resources, depth);
    }

    /// Runs form XObject `s` (`ref` is how it was reached: a reference, or the stream itself),
    /// with `resources` when it has none of its own.
    fn drawForm(self: *Interp, ref: Object, s: read.Stream, resources: Dict, depth: u32) Error!void {
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
        // A form's MCIDs are its own, by its /StructParents (14.7.4.4).
        const saved_mcids = self.mcids;
        defer self.mcids = saved_mcids;
        self.mcids = try structParents(self.r, s.dict);
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

    /// The text of the page's annotations, after its content, as a viewer draws them: each one's
    /// normal appearance stream (/AP /N, or its /AS entry when /N holds one stream per state),
    /// placed on its /Rect by the algorithm of 12.5.5. An annotation with no appearance draws
    /// nothing; none is made up from /Contents or field values (MuPDF synthesises some, and
    /// mutool then gives text the file does not draw). Left out, as a viewer leaves them out:
    /// Hidden and NoView, Invisible on a type that is not standard (12.5.3), and Popup, which a
    /// viewer shows only when asked.
    fn drawAnnotations(self: *Interp, page: read.Page) Error!void {
        const r = self.r;
        const annots = switch ((try r.getResolved(page.dict, "Annots")) orelse return) {
            .array => |a| a,
            else => return error.Malformed,
        };
        for (annots) |ref| {
            const annot = switch (try r.resolve(ref)) {
                .dict => |d| d,
                else => return error.Malformed,
            };
            const subtype = switch ((try r.getResolved(annot, "Subtype")) orelse return error.Malformed) {
                .name => |n| n,
                else => return error.Malformed,
            };
            if (std.mem.eql(u8, subtype, "Popup")) continue;
            var flags: i64 = switch ((try r.getResolved(annot, "F")) orelse Object{ .integer = 0 }) {
                .integer => |n| n,
                else => return error.Malformed,
            };
            const invisible = 1 << 0;
            const hidden = 1 << 1;
            const no_zoom = 1 << 3;
            const no_rotate = 1 << 4;
            const no_view = 1 << 5;
            if (flags & (hidden | no_view) != 0) continue;
            if (flags & invisible != 0 and !standardAnnotation(subtype)) continue;
            // A Text annotation (a note's icon) behaves as if NoZoom and NoRotate were set
            // (12.5.6.4).
            if (std.mem.eql(u8, subtype, "Text")) flags |= no_zoom | no_rotate;
            const ap = switch ((try r.getResolved(annot, "AP")) orelse continue) {
                .dict => |d| d,
                else => return error.Malformed,
            };
            const n_ref = ap.get("N") orelse continue;
            const form_ref, const form = switch (try r.resolve(n_ref)) {
                .stream => |st| .{ n_ref, st },
                .dict => |states| blk: {
                    const as = switch ((try r.getResolved(annot, "AS")) orelse continue) {
                        .name => |n| n,
                        else => return error.Malformed,
                    };
                    const st_ref = states.get(as) orelse continue;
                    break :blk switch (try r.resolve(st_ref)) {
                        .stream => |st| .{ st_ref, st },
                        else => return error.Malformed,
                    };
                },
                else => return error.Malformed,
            };
            if (try r.getResolved(form.dict, "Subtype")) |st| {
                if (!(st == .name and std.mem.eql(u8, st.name, "Form"))) return error.Malformed;
            }
            const bbox = try r.rect((try r.getResolved(form.dict, "BBox")) orelse return error.Malformed);
            const matrix = if (try r.getResolved(form.dict, "Matrix")) |m| try matrixOf(r, m) else identity;
            var rect = try r.rect((try r.getResolved(annot, "Rect")) orelse return error.Malformed);
            // NoZoom: the appearance keeps its own size, from the rectangle's top-left corner.
            // NoRotate: on a rotated page it stays upright, turned about that corner. As MuPDF
            // places them (pdf_annot_display_rect, pdf_annot_transform).
            if (flags & no_zoom != 0) rect = .{ rect[0], rect[3] - (bbox[3] - bbox[1]), rect[0] + (bbox[2] - bbox[0]), rect[3] };
            const rotate: u16 = if (flags & no_rotate != 0) page.rotate else 0;
            if (rotate != 0) {
                const turn = mul(mul(.{ 1, 0, 0, 1, -rect[0], -rect[3] }, rotation(rotate)), .{ 1, 0, 0, 1, rect[0], rect[3] });
                rect = boxOf(rect, turn);
            }
            // 12.5.5: the form's bounding box, transformed by its /Matrix, is mapped onto the
            // rectangle by a scale and a translation (A); the form then runs with /Matrix × A.
            const box = boxOf(bbox, matrix);
            const w = box[2] - box[0];
            const h = box[3] - box[1];
            const upright: Matrix = switch (rotate) {
                0 => identity,
                90 => .{ 0, h / w, -w / h, 0, w, 0 },
                180 => .{ -1, 0, 0, -1, w, h },
                270 => .{ 0, -h / w, w / h, 0, 0, h },
                else => unreachable,
            };
            const sx = if (w == 0) 0 else (rect[2] - rect[0]) / w;
            const sy = if (h == 0) 0 else (rect[3] - rect[1]) / h;
            const a_matrix = mul(upright, .{ sx, 0, 0, sy, rect[0] - box[0] * sx, rect[1] - box[1] * sy });
            // Each appearance starts from the default graphics state, outside any span the page
            // left open, with no structure of its own.
            const saved_gs = self.gs;
            const saved_mcids = self.mcids;
            defer {
                self.gs = saved_gs;
                self.mcids = saved_mcids;
                self.annotation = false;
            }
            self.gs = .{ .ctm = a_matrix };
            self.mcids = null;
            self.annotation = true;
            try self.drawForm(form_ref, form, page.resources, 0);
        }
    }

    /// One text-showing operator: strings and TJ adjustments, as one run.
    fn show(self: *Interp, parts: []const Object) Error!void {
        const font = self.gs.font orelse return error.Malformed;
        const a = self.scratch;
        var text: std.ArrayList(u8) = .empty;
        var unmapped: u32 = 0;
        var width_known = true;
        var glyphs: std.ArrayList(Glyph) = .empty;
        // A high surrogate half that ends a glyph's characters, waiting for the next glyph's: some
        // writers map the two UTF-16 halves of one character to two glyphs. Joined, the character
        // is the first glyph's and the second glyph has none; a half left alone is no character.
        var pending_high: ?u16 = null;
        for (parts) |part| switch (part) {
            .string => |bytes| {
                var i: usize = 0;
                while (i < bytes.len) {
                    const g = font.take(bytes[i..]);
                    i += g.len;
                    const at = self.origin();
                    self.glyph_count += 1;
                    if (self.glyph_count > self.r.options.max_page_glyphs) return error.TooLarge;
                    var buf: [max_chars]u21 = undefined;
                    const found = font.unicode(g, &buf);
                    var chars = found orelse &.{};
                    if (pending_high) |high| {
                        pending_high = null;
                        if (chars.len > 0 and chars[0] <= 0xFFFF and std.unicode.utf16IsLowSurrogate(@intCast(chars[0]))) {
                            try appendUtf8(a, &text, std.unicode.utf16DecodeSurrogatePair(&.{ high, @intCast(chars[0]) }) catch unreachable);
                            chars = chars[1..];
                        } else {
                            try appendUtf8(a, &text, std.unicode.replacement_character);
                            unmapped += 1;
                        }
                    }
                    const text_at = std.math.cast(u32, text.items.len) orelse return error.TooLarge;
                    try glyphs.append(a, .{ .x = at[0], .y = at[1], .text_at = text_at });
                    if (found == null) {
                        try appendUtf8(a, &text, std.unicode.replacement_character);
                        unmapped += 1;
                    } else {
                        var lone = false;
                        for (chars, 0..) |cp, k| {
                            if (cp >= 0xD800 and cp <= 0xDFFF) {
                                if (k == chars.len - 1 and std.unicode.utf16IsHighSurrogate(@intCast(cp))) {
                                    pending_high = @intCast(cp);
                                } else {
                                    try appendUtf8(a, &text, std.unicode.replacement_character);
                                    lone = true;
                                }
                            } else try appendUtf8(a, &text, cp);
                        }
                        if (lone) unmapped += 1;
                    }
                    const word: f64 = if (g.len == 1 and g.code == 32) self.gs.word_spacing else 0;
                    // 9.4.4: tx = (w0 Tfs + Tc + Tw) Th, or in vertical writing ty = w1 Tfs + Tc
                    // + Tw, with no horizontal scaling.
                    if (font.vertical) {
                        self.advance(0, font.vDisplacement(g) / 1000 * self.gs.size + self.gs.char_spacing + word);
                    } else {
                        const w0 = font.width(g) orelse blk: {
                            width_known = false;
                            break :blk 0;
                        };
                        self.advance((w0 / 1000 * self.gs.size + self.gs.char_spacing + word) * self.gs.h_scale, 0);
                    }
                }
            },
            .integer, .real => {
                const adjust = -(part.number().?) / 1000 * self.gs.size;
                if (font.vertical) self.advance(0, adjust) else self.advance(adjust * self.gs.h_scale, 0);
            },
            else => return error.Malformed,
        };
        if (pending_high != null) {
            try appendUtf8(a, &text, std.unicode.replacement_character);
            unmapped += 1;
        }
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
            .vertical = font.vertical,
            .annotation = self.annotation,
        });
    }

    fn advance(self: *Interp, tx: f64, ty: f64) void {
        self.tm = mul(.{ 1, 0, 0, 1, tx, ty }, self.tm);
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
pub fn pdfDocEncoding(b: u8) ?u21 {
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

/// The standard annotation types (ISO 32000-1 Table 169): the Invisible flag hides only others.
fn standardAnnotation(subtype: []const u8) bool {
    const types = [_][]const u8{ "Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "Popup", "FileAttachment", "Sound", "Movie", "Widget", "Screen", "PrinterMark", "TrapNet", "Watermark", "3D", "Redact" };
    for (types) |t| if (std.mem.eql(u8, subtype, t)) return true;
    return false;
}

/// A /Matrix entry: six finite numbers.
fn matrixOf(r: *Reader, obj: Object) Error!Matrix {
    const m = switch (obj) {
        .array => |arr| arr,
        else => return error.Malformed,
    };
    if (m.len != 6) return error.Malformed;
    var mat: Matrix = undefined;
    for (0..6) |i| {
        mat[i] = (try r.resolve(m[i])).number() orelse return error.Malformed;
        if (!std.math.isFinite(mat[i])) return error.Malformed;
    }
    return mat;
}

/// The bounding box of rectangle `b` transformed by `m`.
fn boxOf(b: [4]f64, m: Matrix) [4]f64 {
    var out: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for ([_][2]f64{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[0], b[3] }, .{ b[2], b[3] } }) |c| {
        const x = c[0] * m[0] + c[1] * m[2] + m[4];
        const y = c[0] * m[1] + c[1] * m[3] + m[5];
        out = .{ @min(out[0], x), @min(out[1], y), @max(out[2], x), @max(out[3], y) };
    }
    return out;
}

/// A turn of `degrees` (a multiple of 90) counterclockwise in user space.
fn rotation(degrees: u16) Matrix {
    return switch (degrees) {
        0 => identity,
        90 => .{ 0, 1, -1, 0, 0, 0 },
        180 => .{ -1, 0, 0, -1, 0, 0 },
        270 => .{ 0, -1, 1, 0, 0, 0 },
        else => unreachable,
    };
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
    interp.mcids = try structParents(r, page.dict);
    if (try r.pageContentsIn(work, page)) |content| try interp.run(content, page.resources, 0);
    try interp.drawAnnotations(page);
    return .{ .runs = interp.runs.items, .unplaced_actual_text = interp.unplaced_actual_text };
}

/// The structure elements, by MCID, of a page or form `dict`: the array its /StructParents names in
/// the structure tree's /ParentTree (14.7.4.4). null when either is missing or not that shape: the
/// page then has no structure-tree ActualText, and its text is its glyphs'.
fn structParents(r: *Reader, dict: Dict) Error!?[]const Object {
    const key = switch ((try r.getResolved(dict, "StructParents")) orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    const root = switch ((try r.getResolved(r.trailerDict(), "Root")) orelse return null) {
        .dict => |d| d,
        else => return null,
    };
    const tree = switch ((try r.getResolved(root, "StructTreeRoot")) orelse return null) {
        .dict => |d| d,
        else => return null,
    };
    const parents = switch ((try r.getResolved(tree, "ParentTree")) orelse return null) {
        .dict => |d| d,
        else => return null,
    };
    return switch ((try numberTreeGet(r, parents, key, 0)) orelse return null) {
        .array => |a| a,
        else => null,
    };
}

/// The value for `key` in a number tree (7.9.7), or null: /Nums pairs in a leaf, /Kids with
/// /Limits above. A kid without /Limits is searched too.
fn numberTreeGet(r: *Reader, node: Dict, key: i64, depth: u32) Error!?Object {
    if (depth >= 32) return error.TooDeep;
    if (try r.getResolved(node, "Nums")) |nums| {
        if (nums != .array) return null;
        var i: usize = 0;
        while (i + 1 < nums.array.len) : (i += 2) {
            const k = try r.resolve(nums.array[i]);
            if (k == .integer and k.integer == key) return try r.resolve(nums.array[i + 1]);
        }
    }
    const kids = (try r.getResolved(node, "Kids")) orelse return null;
    if (kids != .array) return null;
    for (kids.array) |kid_ref| {
        const kid = switch (try r.resolve(kid_ref)) {
            .dict => |d| d,
            else => continue,
        };
        if (try r.getResolved(kid, "Limits")) |limits| {
            if (limits == .array and limits.array.len == 2) {
                const lo = try r.resolve(limits.array[0]);
                const hi = try r.resolve(limits.array[1]);
                if (lo == .integer and hi == .integer and (key < lo.integer or key > hi.integer)) continue;
            }
        }
        if (try numberTreeGet(r, kid, key, depth + 1)) |v| return v;
    }
    return null;
}

/// Whether a structure element's /K lists marked-content id `id`: as an integer, a marked-content
/// reference's /MCID, or either inside an array (14.7.2, Table 323).
fn kHolds(r: *Reader, k: Object, id: i64) Error!bool {
    switch (k) {
        .integer => |n| return n == id,
        .dict => |d| {
            const m = (try r.getResolved(d, "MCID")) orelse return false;
            return m == .integer and m.integer == id;
        },
        .array => |items| {
            for (items) |item| {
                const v = try r.resolve(item);
                if (v != .array and try kHolds(r, v, id)) return true;
            }
            return false;
        },
        else => return false,
    }
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

test "encoding CMaps, predefined and in the file: codes split by codespace, CIDs give widths and text" {
    const gpa = testing.allocator;
    // R (90ms-RKSJ-H): ① 8740 is CID 7555, the one-byte space 20 is CID 231 (U+2002 in Adobe's
    // Japan1 table, /W 500), 外 8A4F is CID 1422, あ 82A0 is CID 843. Tw 0.5 applies to the
    // one-byte code 32 (9.3.3): the space moves 500 / 1000 * 10 + 0.5.
    // V (UniJIS-UCS2-V): vertical; あ い are CIDs 843 and 845.
    // E (a CMap stream): one-byte codes 00 to 7F and two-byte 8000 to FFFF; 41 is CID 34 (A),
    // 8001 CID 843; 05 has only a notdef mapping, CID 1 (/W 250), so no character; FF at the end
    // is half a code: invalid, CID 0, no character.
    // U (a stream that uses UniJIS-UCS2-H): its own 3042 is CID 999; 3044 falls to the parent.
    const page =
        \\BT /R 10 Tf 0.5 Tw 100 700 Td <8740208a4f82a0> Tj 0 Tw ET
        \\BT /V 10 Tf 300 700 Td <30423044> Tj ET
        \\BT /E 10 Tf 400 700 Td <41800105ff> Tj ET
        \\BT /U 10 Tf 500 700 Td <30423044> Tj ET
    ;
    const stream_cmap =
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\2 begincodespacerange <00> <7F> <8000> <FFFF> endcodespacerange
        \\1 begincidrange <41> <5a> 34 endcidrange
        \\1 begincidchar <8001> 843 endcidchar
        \\1 beginnotdefrange <00> <1f> 1 endnotdefrange
        \\endcmap CMapName currentdict /CMap defineresource pop end end
    ;
    const japan1 = "/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 6 >>";
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 20 0 R] /Count 4 /MediaBox [0 0 612 792] /Resources << /Font << /R 9 0 R /V 10 0 R /E 11 0 R /U 12 0 R /X 13 0 R /S 14 0 R /I 21 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>",
        streamObject("", page),
        streamObject("", "BT /X 10 Tf <0041> Tj ET"),
        streamObject("", "BT /S 10 Tf <41> Tj ET"),
        "<< /Type /Font /Subtype /Type0 /BaseFont /R /Encoding /90ms-RKSJ-H /DescendantFonts [15 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /V /Encoding /UniJIS-UCS2-V /DescendantFonts [15 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /E /Encoding 16 0 R /DescendantFonts [15 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /U /Encoding 17 0 R /DescendantFonts [15 0 R] >>",
        // Refused: a stream that uses a CMap that is not predefined.
        "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding 18 0 R /DescendantFonts [15 0 R] >>",
        // A stream that uses itself, through /UseCMap: refused, not followed forever.
        "<< /Type /Font /Subtype /Type0 /BaseFont /S /Encoding 19 0 R /DescendantFonts [15 0 R] >>",
        "<< /Type /Font /Subtype /CIDFontType0 /BaseFont /C " ++ japan1 ++ " /W [1 [250] 34 [600] 231 [500] 843 [900] 999 [700]] >>",
        streamObject("/Type /CMap", stream_cmap),
        streamObject("/Type /CMap", "/UniJIS-UCS2-H usecmap 1 begincidchar <3042> 999 endcidchar"),
        streamObject("/Type /CMap", "/Not-A-CMap usecmap"),
        streamObject("/Type /CMap /UseCMap 19 0 R", "1 begincodespacerange <00> <FF> endcodespacerange"),
        "<< /Type /Page /Parent 2 0 R /Contents 22 0 R >>",
        // I uses Identity-V with one code of its own: 0022 is CID 843; 0001 is CID 1 by Identity.
        "<< /Type /Font /Subtype /Type0 /BaseFont /I /Encoding 23 0 R /DescendantFonts [15 0 R] >>",
        streamObject("", "BT /I 10 Tf 600 700 Td <00220001> Tj ET"),
        streamObject("/Type /CMap", "/Identity-V usecmap 1 begincidchar <0022> 843 endcidchar"),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 4), pt.runs.len);

    const rk = pt.runs[0];
    try testing.expectEqualStrings("\u{2460}\u{2002}\u{5916}\u{3042}", rk.text);
    try testing.expectEqual(@as(u32, 0), rk.unmapped);
    for ([_]f64{ 100, 110, 115.5, 125.5 }, rk.glyphs) |x, g| try testing.expectApproxEqAbs(x, g.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 34.5), rk.width.?, 1e-9);
    try testing.expect(!rk.vertical);

    const v = pt.runs[1];
    try testing.expectEqualStrings("\u{3042}\u{3044}", v.text);
    try testing.expect(v.vertical);
    try testing.expectApproxEqAbs(@as(f64, 690), v.glyphs[1].y, 1e-9);

    // 41: /W 600; 8001: CID 843, 900; 05: CID 1, 250; FF: CID 0, /DW 1000.
    const e = pt.runs[2];
    try testing.expectEqualStrings("A\u{3042}\u{fffd}\u{fffd}", e.text);
    try testing.expectEqual(@as(u32, 2), e.unmapped);
    for ([_]f64{ 400, 406, 415, 417.5 }, e.glyphs) |x, g| try testing.expectApproxEqAbs(x, g.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 27.5), e.width.?, 1e-9);

    // 3042 is CID 999 (/W 700) by the stream; 3044 is CID 845 by UniJIS-UCS2-H (/DW 1000).
    const u = pt.runs[3];
    try testing.expectApproxEqAbs(@as(f64, 507), u.glyphs[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 17), u.width.?, 1e-9);
    try testing.expectEqualStrings("\u{3044}", u.text[u.glyphs[1].text_at..]);

    try testing.expectError(error.UnsupportedFont, r.pageText(gpa, 1));
    try testing.expectError(error.TooDeep, r.pageText(gpa, 2));
    var id = try r.pageText(gpa, 3);
    defer id.deinit();
    try testing.expectEqualStrings("\u{3042} ", id.runs[0].text);
    try testing.expect(id.runs[0].vertical);
}

test "ActualText from the structure tree by MCID, and on an image span with no glyph" {
    const gpa = testing.allocator;
    // MCIDs 0 to 3 on the page; MCID 0 in the form, which has its own /StructParents.
    // 0: /K 0, ActualText "zero" over a glyph. 1: /K [1], ActualText "one" over an image.
    // 2: /K << /MCID 2 >> (a reference), ActualText "two" over an inline image.
    // 3: the element at index 3 lists /K 9, not 3: no ActualText, so the glyph's own text.
    // A span with its own /ActualText and nothing drawn: unplaced, counted.
    const page =
        \\/Span <</MCID 0>> BDC BT /F1 10 Tf 10 700 Td (A) Tj ET EMC
        \\/Span <</MCID 1>> BDC q 50 0 0 20 100 600 cm /Im1 Do Q EMC
        \\/Span <</MCID 2>> BDC q 30 0 0 10 200 500 cm BI /W 1 /H 1 /BPC 8 /CS /G ID
    ++ "\n\x00\nEI Q EMC\n" ++
        \\/Span <</MCID 3>> BDC BT /F1 10 Tf 10 400 Td (B) Tj ET EMC
        \\/Span <</ActualText (none)>> BDC EMC
        \\/Fm1 Do
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 8 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /StructParents 7 /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R /Fm1 15 0 R >> >> >>",
        streamObject("", page),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        streamObject("/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray", "\x00"),
        "<< /Type /StructElem /S /Document >>",
        // The parent tree: a root with two kids, the second holding keys 7 and 8.
        "<< /Type /StructTreeRoot /ParentTree 9 0 R >>",
        "<< /Kids [10 0 R 11 0 R] >>",
        "<< /Limits [0 5] /Nums [0 [7 0 R]] >>",
        "<< /Limits [7 8] /Nums [7 [12 0 R 13 0 R 14 0 R 16 0 R] 8 [17 0 R]] >>",
        "<< /Type /StructElem /S /Span /P 7 0 R /K 0 /ActualText (zero) >>",
        "<< /Type /StructElem /S /Span /P 7 0 R /K [1] /ActualText (one) >>",
        "<< /Type /StructElem /S /Span /P 7 0 R /K << /Type /MCR /MCID 2 >> /ActualText (two) >>",
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 612 792] /StructParents 8 /Resources << /Font << /F1 5 0 R >> >>", "/Span <</MCID 0>> BDC BT /F1 10 Tf 10 300 Td (C) Tj ET EMC"),
        "<< /Type /StructElem /S /Span /P 7 0 R /K 9 /ActualText (wrong) >>",
        "<< /Type /StructElem /S /Span /P 7 0 R /K 0 /ActualText (form) >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 5), pt.runs.len);
    try testing.expectEqualStrings("zero", pt.runs[0].text);
    try testing.expect(pt.runs[0].actual_text);
    try testing.expectEqual(@as(usize, 1), pt.runs[0].glyphs.len);
    // On the image: its bottom-left corner, its width, its height as the size, and no glyphs.
    try testing.expectEqualStrings("one", pt.runs[1].text);
    try testing.expectEqual(@as(usize, 0), pt.runs[1].glyphs.len);
    try testing.expectEqual([4]f64{ 100, 600, 50, 20 }, [4]f64{ pt.runs[1].x, pt.runs[1].y, pt.runs[1].width.?, pt.runs[1].size });
    try testing.expectEqualStrings("two", pt.runs[2].text);
    try testing.expectEqual([4]f64{ 200, 500, 30, 10 }, [4]f64{ pt.runs[2].x, pt.runs[2].y, pt.runs[2].width.?, pt.runs[2].size });
    try testing.expectEqualStrings("B", pt.runs[3].text);
    try testing.expect(!pt.runs[3].actual_text);
    try testing.expectEqualStrings("form", pt.runs[4].text);
    try testing.expectEqual(@as(u32, 1), pt.unplaced_actual_text);
}

test "an embedded CFF program's own encoding is the base under /Differences, and a non-CFF one is not read" {
    const gpa = testing.allocator;
    const options = @import("build_options");
    var buf: [512]u8 = undefined;
    // custom-scattered.cff: code 3 is A, 65 is B, 200 is alpha.sc, 255 is x.alt.
    const program = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.bufPrint(&buf, "{s}/cff/custom-scattered.cff", .{options.read_fixtures}), gpa, .limited(1 << 20));
    defer gpa.free(program);
    const stream = try std.fmt.allocPrint(gpa, "<< /Subtype /Type1C /Length {d} >>\nstream\n{s}\nendstream", .{ program.len, program });
    defer gpa.free(stream);
    const other = try std.fmt.allocPrint(gpa, "<< /Subtype /OpenType /Length {d} >>\nstream\n{s}\nendstream", .{ program.len, program });
    defer gpa.free(other);
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R /F2 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        streamObject("", "BT /F1 10 Tf (\\003A\\310\\377) Tj /F2 10 Tf (\\003A) Tj ET"),
        // /Differences changes 255 only; the rest is the program's: 3 A, 65 B, 200 alpha.sc.
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+ZpdfTest /FirstChar 0 /LastChar 255 /Encoding << /Differences [255 /Z] >> /FontDescriptor 6 0 R >>",
        "<< /Type /FontDescriptor /FontName /ABCDEF+ZpdfTest /Flags 4 /FontFile3 8 0 R >>",
        // The same program as /OpenType, which it is not: not read, so no base.
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+ZpdfTest /Encoding << /Differences [255 /Z] >> /FontDescriptor 9 0 R >>",
        stream,
        "<< /Type /FontDescriptor /FontName /ABCDEF+ZpdfTest /Flags 4 /FontFile3 10 0 R >>",
        other,
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    // alpha.sc is the AGL's alpha with a suffix (U+03B1); x.alt is overridden by /Z.
    try testing.expectEqualStrings("AB\u{03B1}Z", pt.runs[0].text);
    try testing.expectEqual(@as(u32, 0), pt.runs[0].unmapped);
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", pt.runs[1].text);
}

test "/W and /W2 that give a CID twice: the last value holds, and every other CID keeps its own" {
    const gpa = testing.allocator;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] /Resources << /Font << /H 5 0 R /V 6 0 R /T 9 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        streamObject("", "BT /H 10 Tf 100 700 Td <000000010002000300040005000600070008> Tj ET BT /V 10 Tf 300 700 Td <000100020003> Tj ET BT /T 10 Tf 100 600 Td <000000010002> Tj ET"),
        "<< /Type /Font /Subtype /Type0 /BaseFont /H /Encoding /Identity-H /DescendantFonts [7 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /V /Encoding /Identity-V /DescendantFonts [8 0 R] >>",
        // Each CID's last value: 0 100; 1 900; 2 800; 3 700; 4 none (/DW 1000); 5 30; 6 40; 7 20;
        // 8 none. Sorted by first CID, the entries overlap, and a CID past an overlap (3, 7) is
        // still found.
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /A /DW 1000 /W [0 [100 200 300 400] 1 [900] 2 3 700 6 [10 20] 5 [30 40] 2 [800]] >>",
        // CID 1 w1 -500, 2 -300 (given again, alone), 3 -800 (only in the first array).
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /B /W2 [1 [-500 0 880 -600 0 880 -800 0 880] 2 [-300 0 880]] >>",
        // In order, but the last two entries share CID 2, which takes 700.
        "<< /Type /Font /Subtype /Type0 /BaseFont /T /Encoding /Identity-H /DescendantFonts [10 0 R] >>",
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /C /W [0 [50] 1 [100 200] 2 [700]] >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 3), pt.runs.len);
    const h = pt.runs[0];
    for ([_]f64{ 100, 101, 110, 118, 125, 135, 135.3, 135.7, 135.9 }, h.glyphs) |x, g| try testing.expectApproxEqAbs(x, g.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 45.9), h.width.?, 1e-9);
    const v = pt.runs[1];
    for ([_]f64{ 700, 695, 692 }, v.glyphs) |y, g| try testing.expectApproxEqAbs(y, g.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 16), v.width.?, 1e-9);
    const t = pt.runs[2];
    for ([_]f64{ 100, 100.5, 101.5 }, t.glyphs) |x, g| try testing.expectApproxEqAbs(x, g.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.5), t.width.?, 1e-9);
}

test "Identity-V: glyphs move by /W2 and /DW2's w1 and Tc along y, TJ along y, with no Tz or Tw" {
    const gpa = testing.allocator;
    // Tc 2, Tz 50 and Tw 3 hold for every run. By ISO 32000-1 9.4.4, a vertical glyph moves the
    // text position by ty = w1 / 1000 * 10 + Tc, and a TJ number n by -n / 1000 * 10: Tz scales
    // neither, and Tw applies to the one-byte code 32 only, never to the two-byte 0020.
    const page =
        \\BT /V1 10 Tf 50 Tz 2 Tc 3 Tw 100 700 Td [<0001> 500 <00200003> <0004> <0005>] TJ ET
        \\BT /V2 10 Tf 200 500 Td <00010007> Tj ET
        \\BT /H 10 Tf 300 300 Td <0001> Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 18 0 R] /Count 4 /MediaBox [0 0 612 792] /Resources << /Font << /V1 9 0 R /V2 10 0 R /H 11 0 R /V3 12 0 R /V4 13 0 R /H3 19 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents 7 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>",
        streamObject("", page),
        streamObject("", "BT /V3 10 Tf <0001> Tj ET"),
        streamObject("", "BT /V4 10 Tf <0001> Tj ET"),
        "<< /Type /Font /Subtype /Type0 /BaseFont /V1 /Encoding /Identity-V /DescendantFonts [14 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /V2 /Encoding /Identity-V /DescendantFonts [15 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /H /Encoding /Identity-H /DescendantFonts [14 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /V3 /Encoding /Identity-V /DescendantFonts [16 0 R] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /V4 /Encoding /Identity-V /DescendantFonts [17 0 R] >>",
        // CIDs 3 and 4: w1 -500 and -1500 (an array); 5 and 6: -2000 (a range); others: /DW2's
        // default -1000.
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /A /W2 [3 [-500 250 880 -1500 250 880] 5 6 -2000 500 880] >>",
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /B /DW2 [880 -900] >>",
        // Malformed: /W2 groups are three numbers; /DW2 is two.
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /C /W2 [1 [-500 250]] >>",
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /D /DW2 [-900] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 20 0 R >>",
        // Horizontal writing never reads /W2, so C's malformed one does not stop it.
        "<< /Type /Font /Subtype /Type0 /BaseFont /H3 /Encoding /Identity-H /DescendantFonts [16 0 R] >>",
        streamObject("", "BT /H3 10 Tf <0001> Tj ET"),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 3), pt.runs.len);
    // V1: 0001 at 700 moves -10 + 2; the TJ 500 moves -5; 0020 moves -10 + 2; 0003 -5 + 2; 0004
    // -15 + 2; 0005 -20 + 2, ending at 645.
    const v1 = pt.runs[0];
    try testing.expect(v1.vertical);
    try testing.expectEqual(@as(usize, 5), v1.glyphs.len);
    for ([_]f64{ 700, 687, 679, 676, 663 }, v1.glyphs) |y, g| {
        try testing.expectApproxEqAbs(@as(f64, 100), g.x, 1e-9);
        try testing.expectApproxEqAbs(y, g.y, 1e-9);
    }
    try testing.expectApproxEqAbs(@as(f64, 55), v1.width.?, 1e-9);
    // V2: /DW2's w1 -900: each glyph moves -9 + 2.
    const v2 = pt.runs[1];
    try testing.expect(v2.vertical);
    try testing.expectApproxEqAbs(@as(f64, 493), v2.glyphs[1].y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 14), v2.width.?, 1e-9);
    // H, the same CIDFont with Identity-H: /W2 does not apply; (1000 / 1000 * 10 + 2) * 0.5.
    const h = pt.runs[2];
    try testing.expect(!h.vertical);
    try testing.expectApproxEqAbs(@as(f64, 6), h.width.?, 1e-9);
    try testing.expectError(error.Malformed, r.pageText(gpa, 1));
    try testing.expectError(error.Malformed, r.pageText(gpa, 2));
    var h3 = try r.pageText(gpa, 3);
    defer h3.deinit();
    try testing.expectEqual(@as(usize, 1), h3.runs.len);
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
    const to_unicode =
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\3 beginbfchar <0001> <0041> <0002> <0000> <0003> <D83DDE00> endbfchar
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
        // UniJIS-UTF32-H is one of Adobe's CMaps but not one of Table 118's predefined ones.
        "<< /Type /Font /Subtype /Type0 /BaseFont /V /Encoding /UniJIS-UTF32-H /DescendantFonts [15 0 R] >>",
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 300 0]", "BT /F1 8 Tf 0 0 Td (A\x80) Tj ET"),
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /X2 11 0 R >> >>", "/X2 Do"),
        streamObject("", page1),
        streamObject("", "BT /F3 12 Tf <0001> Tj ET"),
        streamObject("", "/X2 Do"),
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Test /W [1 [500 600] 10 20 250] /DW 1000 >>",
        streamObject("", to_unicode),
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
        // Identity-H: 0001 bfchar A; 0002 bfchar U+0000, which is no character; 000A small
        // range a; 0101 large range U+4E01; 0020 and 0021 an array range; 0005 none; 0003 a
        // surrogate pair. /W: 500 600 for 1 and 2, 250 for 10 to 20, /DW 1000 else: 6350 /
        // 1000 * 12.
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

test "a character's two UTF-16 halves mapped to two glyphs: joined on the first; a half alone is unmapped" {
    const gpa = testing.allocator;
    // 0001 and 0005 map to the high half of U+1F534, 0002 and 0004 to its low half, 0003 to A,
    // 0006 to the high half then A.
    const to_unicode =
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\6 beginbfchar <0001> <D83D> <0002> <DD34> <0003> <0041> <0004> <DD34> <0005> <D83D> <0006> <D83D0041> endbfchar
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] /Resources << /Font << /F 5 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        // Joined; a high half then A; a low half alone; a high half last; joined across a TJ
        // adjustment; a high half, then an unmapped code; a high half inside one code's
        // characters, then a low half, which it does not wait for.
        streamObject("", "BT /F 10 Tf <00010002> Tj <00010003> Tj <0004> Tj <0005> Tj [<0001> -100 <0002>] TJ <00010009> Tj <00060002> Tj ET"),
        "<< /Type /Font /Subtype /Type0 /BaseFont /T /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 7 0 R >>",
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /T /DW 1000 >>",
        streamObject("", to_unicode),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    const Want = struct { text: []const u8, unmapped: u32, text_at: []const u32 };
    const want = [_]Want{
        .{ .text = "\u{1f534}", .unmapped = 0, .text_at = &.{ 0, 4 } },
        .{ .text = "\u{fffd}A", .unmapped = 1, .text_at = &.{ 0, 3 } },
        .{ .text = "\u{fffd}", .unmapped = 1, .text_at = &.{0} },
        .{ .text = "\u{fffd}", .unmapped = 1, .text_at = &.{0} },
        .{ .text = "\u{1f534}", .unmapped = 0, .text_at = &.{ 0, 4 } },
        .{ .text = "\u{fffd}\u{fffd}", .unmapped = 2, .text_at = &.{ 0, 3 } },
        .{ .text = "\u{fffd}A\u{fffd}", .unmapped = 2, .text_at = &.{ 0, 4 } },
    };
    try testing.expectEqual(want.len, pt.runs.len);
    for (want, pt.runs) |w, run| {
        try testing.expectEqualStrings(w.text, run.text);
        try testing.expectEqual(w.unmapped, run.unmapped);
        try testing.expectEqual(w.text_at.len, run.glyphs.len);
        for (w.text_at, run.glyphs) |at, g| try testing.expectEqual(at, g.text_at);
    }
}

test "WinAnsi's unused codes above octal 40 are bullets; below it, and under /Differences, they are not" {
    const gpa = testing.allocator;
    const content =
        \\BT /F1 10 Tf 100 100 Td (\177\201\215\217\220\235\037A) Tj ET
        \\BT /F2 10 Tf 100 80 Td (\177\201) Tj ET
    ;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>",
        streamObject("", content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [127 /A] >> >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 2), pt.runs.len);
    // \037 is below octal 40: no glyph name, so unmapped.
    try testing.expectEqualStrings("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{fffd}A", pt.runs[0].text);
    try testing.expectEqual(@as(u32, 1), pt.runs[0].unmapped);
    // Helvetica's bullet is 350 wide: the sixth bullet starts at 100 + 5 * 3.5.
    try testing.expectApproxEqAbs(@as(f64, 117.5), pt.runs[0].glyphs[5].x, 1e-9);
    try testing.expectEqualStrings("A\u{2022}", pt.runs[1].text);
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
    // U+0000 alone is no character: a later <0000> takes the code from a range, a range starting
    // at <0000> loses only its first code, and U+0000 inside a longer destination stays.
    const nul = try parseCMap(a, testing.allocator, "1 beginbfrange <0000> <00FF> <0061> <0105> <0107> <0000> endbfrange 3 beginbfchar <0001> <0000> <0002> <00410000> <0004> <00000041> endbfchar", 16);
    try testing.expectEqual(@as(?[]const u21, null), nul.lookup(1, 2, &buf));
    try testing.expectEqualSlices(u21, &.{ 'A', 0 }, nul.lookup(2, 2, &buf).?);
    try testing.expectEqualSlices(u21, &.{ 0, 'A' }, nul.lookup(4, 2, &buf).?);
    try testing.expectEqualSlices(u21, &.{'d'}, nul.lookup(3, 2, &buf).?);
    try testing.expectEqual(@as(?[]const u21, null), nul.lookup(0x105, 2, &buf));
    try testing.expectEqualSlices(u21, &.{1}, nul.lookup(0x106, 2, &buf).?);
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

test "ZapfDingbats glyph names by the ITC Zapf Dingbats Glyph List, in that font only" {
    const gpa = testing.allocator;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] /Resources << /Font << /Z 5 0 R /S 6 0 R /H 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        // Z: the built-in encoding's 4 (a20), space (not in the list: the AGL's) and l (a71).
        // S: a subset, by /Differences: a12, a variant of a71, and a20 and a71 joined. H:
        // Helvetica with the same names in /Differences; the AGL has none of them.
        streamObject("", "BT /Z 10 Tf 0 700 Td (4 l) Tj ET BT /S 10 Tf 0 600 Td (ABC) Tj ET BT /H 10 Tf 0 500 Td (A) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+ZapfDingbats /Encoding << /Differences [65 /a12 /a71.alt /a20_a71] >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Differences [65 /a12] >> >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 3), pt.runs.len);
    try testing.expectEqualStrings("\u{2714} \u{25cf}", pt.runs[0].text);
    try testing.expectEqual(@as(u32, 0), pt.runs[0].unmapped);
    try testing.expectEqualStrings("\u{261e}\u{25cf}\u{2714}\u{25cf}", pt.runs[1].text);
    try testing.expectEqualStrings("\u{fffd}", pt.runs[2].text);
    try testing.expectEqual(@as(u32, 1), pt.runs[2].unmapped);
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
    // An odd byte at the end of a two-byte font's string matches no codespace range: it is one
    // invalid code (9.7.6.2), drawn as CID 0 with /DW's width, and has no character.
    var half = try r.pageText(gpa, 2);
    defer half.deinit();
    try testing.expectEqual(@as(usize, 2), half.runs[0].glyphs.len);
    try testing.expectEqual(@as(u32, 2), half.runs[0].unmapped);
    try testing.expectApproxEqAbs(@as(f64, 20), half.runs[0].width.?, 1e-9);
    var few_ops = try Reader.open(gpa, pdf, .{ .max_operations = 5 });
    defer few_ops.deinit();
    try testing.expectError(error.TooLarge, few_ops.pageText(gpa, 0));
    var few_glyphs = try Reader.open(gpa, pdf, .{ .max_page_glyphs = 2 });
    defer few_glyphs.deinit();
    try testing.expectError(error.TooLarge, few_glyphs.pageText(gpa, 0));
}

test "a word that starts like a number and is not one skips its operator, unless the reader acts on it; a zero with a residue after it is 0" {
    const gpa = testing.allocator;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R 9 0 R 12 0 R] /Count 5 /MediaBox [0 0 612 792] /Resources << /Font << /F1 10 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
        // A path's and a colour's operators skipped; an inline image after a bad word is still
        // skipped to its EI, so its "(" is not read as a string. true, false and null are
        // operands (of sh, which is skipped), not operators.
        streamObject("",
            \\2.50-30 5 m 10 2.50-30 l 10 20 2.50-30 5 re S 1.-2 g 3-4 BI /W 1 /H 1 /CS /G /BPC 8 ID ( EI
            \\true false null /Sh0 sh
            \\BT /F1 10 Tf 7 8 Td (A) Tj ET
        ),
        "<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>",
        // Td still has two numbers without the bad word; it is refused all the same.
        streamObject("", "BT /F1 10 Tf 1 2.50-30 5 Td (A) Tj ET"),
        "<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>",
        // Inside an array the word is part of an object, which is refused.
        streamObject("", "BT /F1 10 Tf [(A) 1-2 (B)] TJ ET"),
        "<< /Type /Page /Parent 2 0 R /Contents 11 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        // A refusal that is not a word: a stray ")".
        streamObject("", ") 0 0 m BT /F1 10 Tf (A) Tj ET"),
        "<< /Type /Page /Parent 2 0 R /Contents 13 0 R >>",
        // Zeros with a residue's digits, read as 0, in cm, Tm and Td: B at (10 + 40, 20 + 0 + 5).
        // Words close to these that are not one: the next test.
        streamObject("", "1 0.00-13322676 -0.000000000000-5684342 1 10 20 cm BT /F1 10 Tf 1 .0-7 0. 1 40 0 Tm 0.0-1 5 Td (B) Tj ET"),
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 1), pt.runs.len);
    try testing.expectEqualStrings("A", pt.runs[0].text);
    try testing.expectApproxEqAbs(@as(f64, 7), pt.runs[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8), pt.runs[0].y, 1e-9);
    // Td's operand has no value to guess.
    try testing.expectError(error.Malformed, r.pageText(gpa, 1));
    try testing.expectError(error.Malformed, r.pageText(gpa, 2));
    try testing.expectError(error.Malformed, r.pageText(gpa, 3));
    var zeros = try r.pageText(gpa, 4);
    defer zeros.deinit();
    try testing.expectEqual(@as(usize, 1), zeros.runs.len);
    try testing.expectEqualStrings("B", zeros.runs[0].text);
    try testing.expectApproxEqAbs(@as(f64, 50), zeros.runs[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 25), zeros.runs[0].y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), zeros.runs[0].size, 1e-9);
}

test "words near a zero with a residue that are not one: refused where the reader acts on them" {
    const gpa = testing.allocator;
    // No dot, nothing after the '-', a dot in the residue, a nonzero digit, two dots, a second
    // '-', a bare dot: each a bad word among Td's operands.
    const words = [_][]const u8{ "00-12", "0.00-", "0.00-1.5", "0.01-12", "0.0.0-12", "0.00-12-3", ".-12" };
    inline for (words) |w| {
        const pdf = try read.test_util.build(gpa, &.{
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>",
            streamObject("", "BT /F1 10 Tf 1 " ++ w ++ " Td (A) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        }, "");
        defer gpa.free(pdf);
        var r = try Reader.open(gpa, pdf, .{});
        defer r.deinit();
        testing.expectError(error.Malformed, r.pageText(gpa, 0)) catch |err| {
            std.debug.print("word {s} was not refused\n", .{w});
            return err;
        };
    }
}

test "annotations: each appearance on its /Rect (12.5.5), by /AS, with Hidden, NoView, Popup and Invisible left out" {
    const gpa = testing.allocator;
    const pdf = try read.test_util.build(gpa, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 20 0 R 23 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [6 0 R 8 0 R 11 0 R 13 0 R 14 0 R 15 0 R 17 0 R 18 0 R 19 0 R] >>",
        // The character spacing the page leaves set does not reach an appearance.
        streamObject("", "5 Tc BT /F1 10 Tf 50 50 Td (P) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        // Scaled 2x across and 3x up onto its rectangle; no resources of its own, so the page's.
        "<< /Type /Annot /Subtype /FreeText /Rect [100 500 300 560] /AP << /N 7 0 R >> >>",
        streamObject("/Type /XObject /Subtype /Form /BBox [0 0 100 20]", "BT /F1 10 Tf 0 5 Td (A) Tj ET"),
        // The /On state; a rectangle given by its other corners; a /Matrix and a box off 0, 0.
        "<< /Type /Annot /Subtype /Widget /Rect [300 120 200 100] /AS /On /AP << /N << /On 9 0 R /Off 10 0 R >> >> >>",
        streamObject("/Subtype /Form /BBox [10 0 110 20] /Matrix [1 0 0 1 10 0] /Resources << /Font << /G 5 0 R >> >>", "BT /G 10 Tf 15 2 Td (B) Tj ET"),
        streamObject("/Subtype /Form /BBox [0 0 1 1]", "BT /F1 10 Tf (X) Tj ET"),
        "<< /Type /Annot /Subtype /Square /F 2 /Rect [0 0 10 10] /AP << /N 12 0 R >> >>",
        streamObject("/BBox [0 0 10 10]", "BT /F1 10 Tf (H) Tj ET"),
        "<< /Type /Annot /Subtype /Square /F 32 /Rect [0 0 10 10] /AP << /N 12 0 R >> >>",
        "<< /Type /Annot /Subtype /Popup /Rect [0 0 10 10] /AP << /N 12 0 R >> >>",
        // Invisible hides only a type that is not standard.
        "<< /Type /Annot /Subtype /Stamp /F 1 /Rect [0 0 10 10] /AP << /N 16 0 R >> >>",
        streamObject("/BBox [0 0 10 10]", "BT /F1 10 Tf (S) Tj ET"),
        "<< /Type /Annot /Subtype /Foo /F 1 /Rect [0 0 10 10] /AP << /N 12 0 R >> >>",
        // No appearance; states but no /AS.
        "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] >>",
        "<< /Type /Annot /Subtype /Widget /Rect [0 0 10 10] /AP << /N << /On 12 0 R >> >> >>",
        // A note on a page turned 90 degrees: its own size from the top-left corner (NoZoom),
        // turned upright about it (NoRotate).
        "<< /Type /Page /Parent 2 0 R /Rotate 90 /Annots [21 0 R] >>",
        "<< /Type /Annot /Subtype /Text /Rect [100 100 300 140] /AP << /N 22 0 R >> >>",
        streamObject("/BBox [0 0 20 20]", "BT /F1 10 Tf 2 3 Td (N) Tj ET"),
        "<< /Type /Page /Parent 2 0 R /Annots [5] >>",
    }, "");
    defer gpa.free(pdf);
    var r = try Reader.open(gpa, pdf, .{});
    defer r.deinit();
    var pt = try r.pageText(gpa, 0);
    defer pt.deinit();
    try testing.expectEqual(@as(usize, 4), pt.runs.len);
    const want = [_]struct { text: []const u8, x: f64, y: f64, size: f64, annotation: bool }{
        .{ .text = "P", .x = 50, .y = 50, .size = 10, .annotation = false },
        .{ .text = "A", .x = 100, .y = 515, .size = 30, .annotation = true },
        .{ .text = "B", .x = 205, .y = 102, .size = 10, .annotation = true },
        .{ .text = "S", .x = 0, .y = 0, .size = 10, .annotation = true },
    };
    for (want, pt.runs) |w, run| {
        try testing.expectEqualStrings(w.text, run.text);
        try testing.expectApproxEqAbs(w.x, run.x, 1e-9);
        try testing.expectApproxEqAbs(w.y, run.y, 1e-9);
        try testing.expectApproxEqAbs(w.size, run.size, 1e-9);
        try testing.expectEqual(w.annotation, run.annotation);
    }
    // Helvetica's A is 667 wide: 6.67 at 10 points, 2x across, and no Tc.
    try testing.expectApproxEqAbs(@as(f64, 13.34), pt.runs[1].width.?, 1e-9);
    // Rect [100 120 120 140] by NoZoom, turned about (100, 140) to [100 140 120 160]; the
    // appearance turned with it: (2, 3) is at (100 + 20 - 3, 140 + 2).
    var turned = try r.pageText(gpa, 1);
    defer turned.deinit();
    try testing.expectEqual(@as(usize, 1), turned.runs.len);
    try testing.expectApproxEqAbs(@as(f64, 117), turned.runs[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 142), turned.runs[0].y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), turned.runs[0].size, 1e-9);
    // An /Annots entry that is not a dictionary.
    try testing.expectError(error.Malformed, r.pageText(gpa, 2));
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
    try testing.expectEqualSlices(u21, &.{0xE9}, (try glyphNameChars(a, "uni00E9", false, 0)).?);
    try testing.expectEqualSlices(u21, &.{ 0x66, 0x69 }, (try glyphNameChars(a, "uni00660069", false, 0)).?);
    try testing.expectEqualSlices(u21, &.{0x1F600}, (try glyphNameChars(a, "u1F600", false, 0)).?);
    // Lowercase hex, a surrogate, and a value past U+10FFFF name no character.
    try testing.expectEqual(@as(?[]const u21, null), try glyphNameChars(a, "uni00e9", false, 0));
    try testing.expectEqual(@as(?[]const u21, null), try glyphNameChars(a, "uniD800", false, 0));
    try testing.expectEqual(@as(?[]const u21, null), try glyphNameChars(a, "u110000", false, 0));
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
    const Counting = @import("counting.zig").Counting;
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
