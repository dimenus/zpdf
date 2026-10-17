//! Text layout, the first layer above drawing: how wide a line of text is, where it may break,
//! and how it wraps to a width.
//!
//! A font is an embedded `Font`, whose widths come from shaping (kerning and ligatures included),
//! or one of the 12 standard text fonts, whose widths are Adobe's AFM metrics: the same tables
//! the reader uses, and what a viewer's substitute font honours. Standard-font text must be
//! WinAnsi, as drawing it requires (NotWinAnsi otherwise).
//!
//! Wrapping is greedy, by these rules:
//! - a line may break after a run of spaces or tabs, and before or after a CJK ideograph or kana,
//!   except before closing punctuation and after opening punctuation (a short kinsoku set);
//! - `\n`, `\r\n` and `\r` force a break; each paragraph they separate gives at least one line,
//!   an empty one when the paragraph is empty, and empty text gives no lines;
//! - a line's spaces at its end are not part of it, and a continuation line starts after the
//!   spaces it broke at;
//! - a word wider than the width is broken between characters when `break_words` is set (never
//!   before a combining mark, a variation selector, a zero-width joiner or a skin-tone modifier),
//!   and otherwise stands on its own line, wider than the width, which the caller can see.
//!
//! Widths are measured word by word, so kerning between a word and the space beside it is not
//! counted; a word's own kerning is.

const std = @import("std");
const zpdf = @import("root.zig");
const sfnt = @import("sfnt.zig");
const tables = @import("read_tables.zig");
const winansi = @import("winansi.zig");

pub const FontRef = union(enum) {
    standard: zpdf.StandardFont,
    embedded: *zpdf.Font,
};

pub const Line = struct {
    /// Byte offset of the line's first character in the text.
    start: u32,
    /// The line's length in bytes, without its trailing spaces or its line break.
    len: u32,
    /// The line's width in points.
    width: f64,
};

pub const WrapOptions = struct {
    shape: zpdf.ShapeOptions = .{},
    /// Break a word wider than the line between characters.
    break_words: bool,
};

/// The width of `utf8` at `size` points, as one run with no breaks.
pub fn measure(gpa: std.mem.Allocator, font: FontRef, size: f64, utf8: []const u8, options: zpdf.ShapeOptions) !f64 {
    if (!(std.math.isFinite(size) and size > 0)) return error.InvalidNumber;
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    return switch (font) {
        .standard => |s| measureStandard(s, size, utf8),
        .embedded => |f| measureEmbedded(gpa, f, size, utf8, options),
    };
}

fn measureStandard(font: zpdf.StandardFont, size: f64, utf8: []const u8) error{NotWinAnsi}!f64 {
    const widths = standardWidths(font);
    var total: u64 = 0;
    var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| {
        _ = winansi.encode(cp) orelse return error.NotWinAnsi;
        total += widthOf(widths, cp) orelse return error.NotWinAnsi;
    }
    return @as(f64, @floatFromInt(total)) * size / 1000.0;
}

fn measureEmbedded(gpa: std.mem.Allocator, font: *zpdf.Font, size: f64, utf8: []const u8, options: zpdf.ShapeOptions) !f64 {
    if (utf8.len == 0) return 0;
    var shaped = try zpdf.shape(gpa, font, utf8, options);
    defer shaped.deinit(gpa);
    var advance: i64 = 0;
    for (shaped.glyphs) |glyph| advance += glyph.advance_x;
    const upem = try sfnt.unitsPerEm(font.bytes, font.index);
    return @as(f64, @floatFromInt(advance)) * size / @as(f64, @floatFromInt(upem));
}

fn standardWidths(font: zpdf.StandardFont) []const tables.CodePointWidth {
    const name = font.baseFont();
    for (&tables.text_font_widths) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f.widths;
    }
    unreachable; // every StandardFont has a table: the test "every standard font has widths" checks it
}

fn widthOf(widths: []const tables.CodePointWidth, cp: u21) ?u16 {
    const i = std.sort.binarySearch(tables.CodePointWidth, widths, cp, struct {
        fn order(key: u21, item: tables.CodePointWidth) std.math.Order {
            return std.math.order(key, item.cp);
        }
    }.order) orelse return null;
    return widths[i].width;
}

/// The lines `utf8` wraps to at `max_width` points, owned by `gpa`.
pub fn wrap(gpa: std.mem.Allocator, font: FontRef, size: f64, utf8: []const u8, max_width: f64, options: WrapOptions) ![]Line {
    if (!(std.math.isFinite(max_width) and max_width > 0)) return error.InvalidNumber;
    if (!(std.math.isFinite(size) and size > 0)) return error.InvalidNumber;
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);
    if (utf8.len == 0) return lines.toOwnedSlice(gpa);

    var w: Wrapper = .{ .gpa = gpa, .font = font, .size = size, .max = max_width, .options = options, .lines = &lines };
    var start: usize = 0;
    var i: usize = 0;
    while (i <= utf8.len) {
        if (i == utf8.len or utf8[i] == '\n' or utf8[i] == '\r') {
            try w.paragraph(utf8, start, i);
            if (i == utf8.len) break;
            i += if (utf8[i] == '\r' and i + 1 < utf8.len and utf8[i + 1] == '\n') 2 else 1;
            start = i;
            continue;
        }
        i += 1;
    }
    return lines.toOwnedSlice(gpa);
}

const Wrapper = struct {
    gpa: std.mem.Allocator,
    font: FontRef,
    size: f64,
    max: f64,
    options: WrapOptions,
    lines: *std.ArrayList(Line),

    // The line being filled: where it starts, where its last word ends, and its width there.
    line_start: ?usize = null,
    line_end: usize = 0,
    line_width: f64 = 0,

    fn paragraph(w: *Wrapper, text: []const u8, start: usize, end: usize) !void {
        w.line_start = null;
        w.line_width = 0;
        var i = start;
        while (i < end) {
            if (text[i] == ' ' or text[i] == '\t') {
                i += 1;
                continue;
            }
            const word_end = nextBreak(text, i, end);
            try w.word(text, i, word_end);
            // A break between two non-space pieces (CJK) has no space to drop.
            i = word_end;
        }
        if (w.line_start) |s| {
            try w.emit(s, w.line_end, w.line_width);
        } else {
            try w.emit(start, start, 0);
        }
    }

    /// A line's width is measured over the whole line, spaces included, never summed from its
    /// words: shaping across a space (kerning, contextual forms) makes a sum differ from what the
    /// line draws.
    fn word(w: *Wrapper, text: []const u8, start: usize, end: usize) !void {
        if (w.line_start) |s| {
            const joined = try measure(w.gpa, w.font, w.size, text[s..end], w.options.shape);
            if (joined <= w.max + fit_slack) {
                w.line_end = end;
                w.line_width = joined;
                return;
            }
            try w.emit(s, w.line_end, w.line_width);
            w.line_start = null;
        }
        const width = try measure(w.gpa, w.font, w.size, text[start..end], w.options.shape);
        if (width > w.max + fit_slack and w.options.break_words) {
            try w.breakWord(text, start, end);
            return;
        }
        w.line_start = start;
        w.line_end = end;
        w.line_width = width;
    }

    /// Pieces of a word wider than the line: each the longest prefix that fits (at least one
    /// character, so a line too narrow for any character still advances).
    fn breakWord(w: *Wrapper, text: []const u8, start: usize, end: usize) !void {
        var piece = start;
        while (piece < end) {
            var fit = nextCharacter(text, piece, end);
            var fit_width = try measure(w.gpa, w.font, w.size, text[piece..fit], w.options.shape);
            while (fit < end) {
                const next = nextCharacter(text, fit, end);
                const next_width = try measure(w.gpa, w.font, w.size, text[piece..next], w.options.shape);
                if (next_width > w.max + fit_slack) break;
                fit = next;
                fit_width = next_width;
            }
            if (fit == end) {
                // The last piece stays open, so a following word can join its line.
                w.line_start = piece;
                w.line_end = end;
                w.line_width = fit_width;
                return;
            }
            try w.emit(piece, fit, fit_width);
            piece = fit;
        }
    }

    fn emit(w: *Wrapper, start: usize, end: usize, width: f64) !void {
        try w.lines.append(w.gpa, .{ .start = @intCast(start), .len = @intCast(end - start), .width = width });
    }
};

/// Room for floating-point error when a width is compared with the line's: a word that fits
/// exactly must not be pushed to the next line by rounding.
const fit_slack = 1e-9;

/// Where the word starting at `i` ends: at a space, a tab, `end`, or a CJK break opportunity.
fn nextBreak(text: []const u8, i: usize, end: usize) usize {
    var prev = cpAt(text, i);
    var j = i + seqLen(text[i]);
    while (j < end) {
        if (text[j] == ' ' or text[j] == '\t') return j;
        const cur = cpAt(text, j);
        if (breakBetween(prev, cur)) return j;
        prev = cur;
        j += seqLen(text[j]);
    }
    return end;
}

fn seqLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

fn cpAt(text: []const u8, i: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return 0xFFFD;
    return std.unicode.utf8Decode(text[i..][0..len]) catch 0xFFFD;
}

/// A break is allowed between `a` and `b` when either is a CJK ideograph or kana, unless `b`
/// closes or `a` opens.
fn breakBetween(a: u21, b: u21) bool {
    if (!(isCjk(a) or isCjk(b))) return false;
    if (closes(b) or opens(a)) return false;
    return true;
}

fn isCjk(cp: u21) bool {
    return (cp >= 0x3040 and cp <= 0x30FF) or // Hiragana, Katakana
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Extension A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0x20000 and cp <= 0x2FFFF); // CJK Extensions B and later
}

fn closes(cp: u21) bool {
    return switch (cp) {
        '、', '。', '，', '．', '・', '：', '；', '？', '！', 'ー', '）', '」', '』', '】', '〕', '〉', '》', '｝', '］', 'ぁ', 'ぃ', 'ぅ', 'ぇ', 'ぉ', 'っ', 'ゃ', 'ゅ', 'ょ', 'ァ', 'ィ', 'ゥ', 'ェ', 'ォ', 'ッ', 'ャ', 'ュ', 'ョ', ')', ']', '}', ',', '.', '!', '?', ':', ';' => true,
        else => false,
    };
}

fn opens(cp: u21) bool {
    return switch (cp) {
        '（', '「', '『', '【', '〔', '〈', '《', '｛', '［', '(', '[', '{' => true,
        else => false,
    };
}

/// The end of the character at `i`: the code point and every combining mark, variation
/// selector, zero-width joiner (with the character it joins) and skin-tone modifier after it.
fn nextCharacter(text: []const u8, i: usize, end: usize) usize {
    var j = i + (seqLen(text[i]));
    while (j < end) {
        const cp = cpAt(text, j);
        const len = seqLen(text[j]);
        if (cp == 0x200D) {
            j += len;
            if (j < end) j += seqLen(text[j]);
            continue;
        }
        if (!extends(cp)) break;
        j += len;
    }
    return @min(j, end);
}

fn extends(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFE20 and cp <= 0xFE2F) or
        (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

const testing = std.testing;

fn loadTestFont() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, @import("build_options").test_font_roboto, testing.allocator, .unlimited);
}

fn texts(text: []const u8, lines: []const Line, out: [][]const u8) [][]const u8 {
    for (lines, 0..) |l, i| out[i] = text[l.start..][0..l.len];
    return out[0..lines.len];
}

test "text_layout: every standard font has widths, and a standard width is Adobe's" {
    inline for (@typeInfo(zpdf.StandardFont).@"enum".field_names) |name| {
        try testing.expect(standardWidths(@field(zpdf.StandardFont, name)).len > 0);
    }
    // Helvetica's AFM: H 722, e 556, l 222, o 556.
    try testing.expectApproxEqAbs(@as(f64, 22.78), try measure(testing.allocator, .{ .standard = .helvetica }, 10, "Hello", .{}), 1e-9);
    // Courier is monospaced at 600.
    try testing.expectApproxEqAbs(@as(f64, 30), try measure(testing.allocator, .{ .standard = .courier }, 10, "Hello", .{}), 1e-9);
    try testing.expectError(error.NotWinAnsi, measure(testing.allocator, .{ .standard = .helvetica }, 10, "Ω", .{}));
    // Ł has an Adobe width but no WinAnsi code, so drawing it fails: measuring it must fail too.
    try testing.expectError(error.NotWinAnsi, measure(testing.allocator, .{ .standard = .helvetica }, 10, "Ł", .{}));
    try testing.expectError(error.InvalidNumber, measure(testing.allocator, .{ .standard = .helvetica }, 0, "a", .{}));
    try testing.expectError(error.InvalidUtf8, measure(testing.allocator, .{ .standard = .helvetica }, 10, "\xff", .{}));
}

test "text_layout: an embedded font's width is the width the reader finds for the drawn run" {
    const gpa = testing.allocator;
    const bytes = try loadTestFont();
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer font.deinit();
    const text = "office café, AVA";
    const width = try measure(gpa, .{ .embedded = &font }, 12, text, .{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var doc = try zpdf.Document.begin(gpa, &out.writer, .{ .compress = true });
    defer doc.deinit();
    const id = try doc.addFont(&font);
    const page = try doc.beginPage(400, 200);
    try doc.drawText(page, id, 12, 10, 100, .black, text, .{});
    try doc.endPage(page);
    try doc.finish();

    var reader = try zpdf.read.Reader.open(gpa, out.written(), .{});
    defer reader.deinit();
    var page_text = try reader.pageText(gpa, 0);
    defer page_text.deinit();
    try testing.expectEqual(@as(usize, 1), page_text.runs.len);
    // Each glyph is placed at its exact shaped position, but /W is whole thousandths of an em, so
    // the read run ends at the last glyph's rounded width: within half a thousandth of the size.
    try testing.expectApproxEqAbs(page_text.runs[0].width.?, width, 12 * 0.0005);
}

test "text_layout: wrap breaks at spaces, drops the spaces it breaks at, and keeps the ones between words" {
    const gpa = testing.allocator;
    const helv: FontRef = .{ .standard = .helvetica };
    const text = "aaa  bbb ccc   ";
    const two_words = try measure(gpa, helv, 10, "aaa  bbb", .{});
    const lines = try wrap(gpa, helv, 10, text, two_words, .{ .break_words = false });
    defer gpa.free(lines);
    var buf: [8][]const u8 = undefined;
    const got = texts(text, lines, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("aaa  bbb", got[0]);
    try testing.expectEqualStrings("ccc", got[1]);
    try testing.expectApproxEqAbs(two_words, lines[0].width, 1e-9);
    try testing.expectApproxEqAbs(try measure(gpa, helv, 10, "ccc", .{}), lines[1].width, 1e-9);
}

test "text_layout: line breaks force lines, an empty paragraph is an empty line, and empty text is no lines" {
    const gpa = testing.allocator;
    const helv: FontRef = .{ .standard = .helvetica };
    const text = "one\n\r\ntwo\rthree";
    const lines = try wrap(gpa, helv, 10, text, 1000, .{ .break_words = false });
    defer gpa.free(lines);
    var buf: [8][]const u8 = undefined;
    const got = texts(text, lines, &buf);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("one", got[0]);
    try testing.expectEqualStrings("", got[1]);
    try testing.expectEqualStrings("two", got[2]);
    try testing.expectEqualStrings("three", got[3]);

    const none = try wrap(gpa, helv, 10, "", 100, .{ .break_words = false });
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectError(error.InvalidNumber, wrap(gpa, helv, 10, "a", 0, .{ .break_words = false }));
}

test "text_layout: a word wider than the line overflows, or breaks between characters when asked" {
    const gpa = testing.allocator;
    const helv: FontRef = .{ .standard = .helvetica };
    // A real 49-character item description with no space (PS-25291), in a 67pt column at 8pt.
    const text = "GRAHAMCRACKER-GOLDFISH/CINN/PF/CASE(300/2CTPKG)GF";
    const whole = try wrap(gpa, helv, 8, text, 67, .{ .break_words = false });
    defer gpa.free(whole);
    try testing.expectEqual(@as(usize, 1), whole.len);
    try testing.expect(whole[0].width > 67);

    const pieces = try wrap(gpa, helv, 8, text, 67, .{ .break_words = true });
    defer gpa.free(pieces);
    try testing.expect(pieces.len > 1);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (pieces) |p| {
        try testing.expect(p.width <= 67 + 1e-9);
        try joined.appendSlice(gpa, text[p.start..][0..p.len]);
        // Each piece is as long as it can be: one more character would not fit.
        if (p.start + p.len < text.len) {
            try testing.expect(try measure(gpa, helv, 8, text[p.start..][0 .. p.len + 1], .{}) > 67);
        }
    }
    try testing.expectEqualStrings(text, joined.items);

    // A following word joins the last piece's line when it fits. The line is as wide as
    // "aaaaaa bb" (6 x 556 + 278 + 2 x 556 = 4726), which holds eight a's (4448), so the ten
    // a's break after eight and "aa bb" (2 x 556 + 278 + 2 x 556 = 2502) shares the next line.
    const tail = try wrap(gpa, helv, 10, "aaaaaaaaaa bb", try measure(gpa, helv, 10, "aaaaaa bb", .{}), .{ .break_words = true });
    defer gpa.free(tail);
    var buf: [8][]const u8 = undefined;
    const got = texts("aaaaaaaaaa bb", tail, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("aaaaaaaa", got[0]);
    try testing.expectEqualStrings("aa bb", got[1]);
}

test "text_layout: a broken word never splits a combining mark from its letter" {
    const gpa = testing.allocator;
    const bytes = try loadTestFont();
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer font.deinit();
    const f: FontRef = .{ .embedded = &font };
    // "e" + COMBINING ACUTE ACCENT, five times, in a line narrower than one character, so each
    // piece is the smallest one wrap allows. The accent has no advance, so a wider line would
    // keep it with its letter by width alone and test nothing.
    const text = "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}";
    const one = try measure(gpa, f, 10, "e\u{301}", .{});
    const lines = try wrap(gpa, f, 10, text, one / 2, .{ .break_words = true });
    defer gpa.free(lines);
    try testing.expectEqual(@as(usize, 5), lines.len);
    for (lines) |l| try testing.expectEqualStrings("e\u{301}", text[l.start..][0..l.len]);
}

test "text_layout: CJK breaks between characters, but not before closing or after opening punctuation" {
    const gpa = testing.allocator;
    const bytes = try loadTestFont();
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer font.deinit();
    const f: FontRef = .{ .embedded = &font };
    // Roboto has no CJK glyphs; the shaped .notdef advances still give widths to break by.
    const text = "日本語「テスト」です。";
    const two = try measure(gpa, f, 10, "日本", .{});
    const lines = try wrap(gpa, f, 10, text, two, .{ .break_words = false });
    defer gpa.free(lines);
    var buf: [16][]const u8 = undefined;
    const got = texts(text, lines, &buf);
    try testing.expect(got.len > 1);
    for (got) |line| {
        try testing.expect(!std.mem.startsWith(u8, line, "」"));
        try testing.expect(!std.mem.startsWith(u8, line, "。"));
        try testing.expect(!std.mem.endsWith(u8, line, "「"));
    }
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (got) |line| try joined.appendSlice(gpa, line);
    try testing.expectEqualStrings(text, joined.items);
}

test "text_layout: a line's width is the whole line shaped, kerning across its spaces included" {
    // Roboto kerns T against a space: "T y" draws narrower than "T" + " " + "y" measured apart.
    const gpa = testing.allocator;
    const bytes = try loadTestFont();
    defer gpa.free(bytes);
    var font = try zpdf.Font.init(gpa, bytes, 0, &.{});
    defer font.deinit();
    const f: FontRef = .{ .embedded = &font };
    const whole = try measure(gpa, f, 10, "T y", .{});
    const parts = try measure(gpa, f, 10, "T", .{}) + try measure(gpa, f, 10, " ", .{}) + try measure(gpa, f, 10, "y", .{});
    try testing.expect(parts - whole > 0.1);

    // A line as wide as the shaped text fits it, though the parts' sum would not.
    const lines = try wrap(gpa, f, 10, "T y", whole, .{ .break_words = false });
    defer gpa.free(lines);
    try testing.expectEqualSlices(Line, &.{.{ .start = 0, .len = 3, .width = whole }}, lines);
}
