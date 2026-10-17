//! zpdf: a PDF renderer and generator, with a wasm build for the browser.

const std = @import("std");
const assert = std.debug.assert;
const ManagedList = std.array_list.Managed;
const builtin = @import("builtin");

pub const sfnt = @import("sfnt.zig");
pub const instancer = @import("instancer.zig");
pub const text_map = @import("text_map.zig");
pub const pdf = @import("pdf.zig");
pub const abi = @import("abi.zig");
pub const winansi = @import("winansi.zig");
pub const read = @import("read.zig");
pub const Document = pdf.Document;
pub const StandardFont = pdf.StandardFont;
pub const Color = pdf.Color;

// The C ABI (abi.zig): exported by zpdf.wasm and by libzpdf, not by the Zig module.
comptime {
    if (builtin.target.cpu.arch == .wasm32 or @import("abi_options").export_c) abi.exportAll();
}

/// On wasm32 a panic keeps its message for JS (abi.capturePanic) before it
/// traps; elsewhere, std's handler.
pub const panic = if (builtin.target.cpu.arch == .wasm32) std.debug.FullPanic(abi.capturePanic) else std.debug.FullPanic(std.debug.defaultPanic);
pub const Outlines = instancer.Outlines;
pub const PathCommand = instancer.PathCommand;
pub const FontId = pdf.FontId;
pub const PageId = pdf.PageId;

test {
    _ = abi;
    _ = winansi;
    _ = sfnt;
    _ = instancer;
    _ = text_map;
    _ = pdf;
    _ = read;
    _ = @import("read_text.zig");
}

pub const Direction = enum(u32) {
    dont_know = 0,
    ltr = 1,
    rtl = 2,
    _,
};

pub const Glyph = extern struct {
    id: u16,
    _reserved0: u16,
    cluster: u32,
    advance_x: i32,
    advance_y: i32,
    offset_x: i32,
    offset_y: i32,
};

pub const Run = extern struct {
    direction: u32,
    script: u32,
    glyph_start: u32,
    glyph_count: u32,
    /// The paragraph's direction as kb resolved it (Direction values).
    paragraph_direction: u32,
};

comptime {
    assert(@sizeOf(Glyph) == 24);
    assert(@sizeOf(Run) == 20);
}

const LoadFontErrorCode = enum(u32) {
    none = 0,
    need_to_create_blob = 1,
    invalid_font = 2,
    out_of_memory = 3,
    could_not_open_file = 4,
    read_error = 5,
    count = 6,
};

const ShapeErrorCode = enum(u32) {
    none = 0,
    invalid_font = 1,
    gave_text_before_calling_begin = 2,
    out_of_memory = 3,
    too_many_operations = 4,
    count = 5,
};

/// kb's allocator bridge (see kb_shim.c). Allocate-only: every bridge is backed
/// by an ArenaAllocator and kb's frees are no-ops, because each kb allocation
/// lives exactly as long as the font or the shape context that made it.
const AllocatorBridge = extern struct {
    alloc: *const fn (?*anyopaque, u32) callconv(.c) ?*anyopaque,
    user_data: ?*anyopaque,
};

const OpaqueFont = opaque {};

extern fn kbshim_font_create(
    font_bridge: *AllocatorBridge,
    scratch_bridge: *AllocatorBridge,
    context_bridge: *AllocatorBridge,
    font_bytes: ?*anyopaque,
    font_bytes_len: c_int,
    font_index: c_int,
    out_font: *?*OpaqueFont,
) callconv(.c) u32;
extern fn kbshim_font_destroy(font: *OpaqueFont) callconv(.c) void;
extern fn kbshim_font_axis_count(font: *OpaqueFont) callconv(.c) c_int;
extern fn kbshim_font_axis_info(
    font: *OpaqueFont,
    axis_index: c_int,
    tag: *u32,
    minimum: *f32,
    default_value: *f32,
    maximum: *f32,
    hidden: *c_int,
) callconv(.c) c_int;
extern fn kbshim_font_set_instance(font: *OpaqueFont, vector: [*]f32, normalized: [*]i16) callconv(.c) void;
extern fn kbshim_glyph_advance_x(font: *OpaqueFont, glyph_id: u32) callconv(.c) i32;
extern fn kbshim_font_metric(font: *OpaqueFont, tag: u32, vector: [*]f32) callconv(.c) f32;
extern fn kbshim_font_has_context(font: *const OpaqueFont) callconv(.c) c_int;
extern fn kbshim_shape_utf8(
    font: *OpaqueFont,
    utf8: [*]const u8,
    utf8_len: c_int,
    paragraph_direction: u32,
    language: u32,
    emit_glyph: *const fn (?*anyopaque, *const Glyph) callconv(.c) c_int,
    emit_run: *const fn (?*anyopaque, *const Run) callconv(.c) c_int,
    emit_user_data: ?*anyopaque,
) callconv(.c) u32;

// kb's allocator contract says "The allocation does not need to be aligned".
// 16 is what malloc gives, which is what an ASan build of kb runs with.
const kb_alignment = std.mem.Alignment.fromByteUnits(16);

fn isSingleSfntMagic(tag: *const [4]u8) bool {
    if (std.mem.eql(u8, tag, &.{ 0x00, 0x01, 0x00, 0x00 })) return true;
    if (std.mem.eql(u8, tag, "OTTO")) return true;
    if (std.mem.eql(u8, tag, "true")) return true;
    return false;
}

/// kb reads a 12-byte table directory after a 4-byte magic check and does not
/// bound the chosen ttcf offset. Refuse those inputs here, on the copy kb sees.
fn fontBytesAreSafeForKb(bytes: []const u8, index: i32) bool {
    if (bytes.len < 4) return false;
    const tag = bytes[0..4];
    if (isSingleSfntMagic(tag)) return sfntDirectoryFits(bytes);
    if (std.mem.eql(u8, tag, "ttcf")) return ttcDirectoryFits(bytes, index);
    return false;
}

fn sfntDirectoryFits(bytes: []const u8) bool {
    if (bytes.len < 12) return false;
    if (!isSingleSfntMagic(bytes[0..4])) return false;
    const num_tables = std.mem.readInt(u16, bytes[4..6], .big);
    const tables_bytes = std.math.mul(usize, 16, num_tables) catch return false;
    const need = std.math.add(usize, 12, tables_bytes) catch return false;
    return need <= bytes.len;
}

fn ttcDirectoryFits(bytes: []const u8, index: i32) bool {
    if (bytes.len < 12) return false;
    const num_fonts = std.mem.readInt(u32, bytes[8..12], .big);
    const list_bytes = std.math.mul(usize, 4, num_fonts) catch return false;
    const list_end = std.math.add(usize, 12, list_bytes) catch return false;
    if (list_end > bytes.len) return false;
    if (index < 0) return false;
    const idx = std.math.cast(u32, index) orelse return false;
    if (idx >= num_fonts) return false;
    const off_at = 12 + 4 * @as(usize, idx);
    const dir_off = std.mem.readInt(u32, bytes[off_at..][0..4], .big);
    if (@as(usize, dir_off) > bytes.len) return false;
    return sfntDirectoryFits(bytes[dir_off..]);
}

/// `user_data` is a `*std.mem.Allocator`. In production it is an arena's
/// allocator; a test can wrap it (FailingAllocator) to fail one kb allocation
/// at a time, which failing the arena's child cannot do: the arena takes memory
/// from its child in large blocks, so most kb allocations never reach it.
fn bridgeAlloc(user_data: ?*anyopaque, size: u32) callconv(.c) ?*anyopaque {
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(user_data orelse return null));
    const buffer = allocator.alignedAlloc(u8, kb_alignment, size) catch return null;
    return buffer.ptr;
}

/// kb's memory for one font. Heap-allocated so the bridges' user_data pointers
/// stay valid when a Font value moves (Document keeps fonts in a growable list).
const KbMemory = struct {
    /// The kb font blob and the shim's handle. Freed by Font.deinit.
    font_arena: std.heap.ArenaAllocator,
    /// The font's kb shape context. Invariant: when the handle has no context,
    /// this arena is empty. It is freed with .free_all after a failed shape, so
    /// a pointer left over from the dropped context reads freed memory (which a
    /// hardened allocator reports) instead of a recycled arena block.
    context_arena: std.heap.ArenaAllocator,
    /// What kb allocates through. Each is its arena's allocator.
    font_allocator: std.mem.Allocator,
    context_allocator: std.mem.Allocator,
    font_bridge: AllocatorBridge,
    context_bridge: AllocatorBridge,
};

/// One axis setting of a variable font: an fvar axis tag such as "wght", and a
/// value in that axis's user units (wght=700, wdth=80).
pub const Variation = struct {
    tag: [4]u8,
    value: f32,
};

/// One variation axis of a font, in the axis's user units. `hidden` is fvar's
/// HIDDEN_AXIS flag: the font asks a UI not to offer the axis.
pub const Axis = struct {
    tag: [4]u8,
    minimum: f32,
    default: f32,
    maximum: f32,
    hidden: bool,
};

/// Font ids: each Font.init takes the next, so no two Fonts share one. A plain
/// counter where there is one thread (wasm32 has no 64-bit atomics), an atomic
/// one elsewhere.
const FontIds = if (builtin.single_threaded) struct {
    next_id: u64 = 1,
    fn take(self: *@This()) u64 {
        defer self.next_id += 1;
        return self.next_id;
    }
} else struct {
    next_id: std.atomic.Value(u64) = .init(1),
    fn take(self: *@This()) u64 {
        return self.next_id.fetchAdd(1, .monotonic);
    }
};
var font_ids: FontIds = .{};

/// A font loaded into kb, with the kb shape context that shapes it.
///
/// Shaping changes the font: the first `shape` creates a kb shape context and
/// later calls reuse it, because kb caches its per-script shape configs there.
/// So a Font is not safe to shape from two threads at once; `shape` takes
/// `*Font` to say so.
///
/// A Font is one instance of the file: the variation coordinates are fixed by
/// `init` and every shape and advance uses them.
pub const Font = struct {
    gpa: std.mem.Allocator,
    /// Unique among the Fonts this process has made, so a ShapeResult can name
    /// its font (see ShapeResult.font_id).
    id: u64,
    bytes: []u8,
    /// The face of `bytes` this font is (0 unless `bytes` is a collection).
    index: i32,
    kb: *KbMemory,
    handle: *OpaqueFont,
    /// kb's normalized coordinates (F2Dot14, one per fvar axis, fvar order) of
    /// this instance. Empty for a font with no axes; all zero at the default
    /// instance. Lives in the font arena.
    normalized: []const i16,
    /// The user coordinates `variations` gave each fvar axis (fvar order, the
    /// axis default where no variation named it), before kb clamps them; and
    /// the axis defaults. Empty for a font with no axes. In the font arena.
    coordinates: []const f32,
    default_coordinates: []const f32,

    /// Loads face `index` of `bytes` at the instance `variations` names. A
    /// font with no axes, or the default instance, passes `&.{}`.
    ///
    /// How `variations` becomes the instance:
    /// - Each fvar axis starts at its default value; a variation whose tag
    ///   names the axis sets it.
    /// - A tag the font has no axis for is ignored, as HarfBuzz does. So a
    ///   static font accepts any variations and draws as with none.
    /// - A value outside the axis's range is clamped to the range by kb
    ///   (kbts_NormalizeVariationVector), as HarfBuzz does.
    /// - kb normalizes the user values once, here (avar segment maps
    ///   included); `normalized` holds the result, and shaping, advances and
    ///   PDF widths all use that one vector.
    /// - error.InvalidNumber: a value is NaN or infinite.
    /// - error.DuplicateVariationTag: two variations name the same tag. kb
    ///   keeps the first and HarfBuzz the last, so neither reading is safe.
    /// - error.UnsupportedAvarVersion: `variations` is not empty and the font
    ///   has an avar version 2 table. kb reads avar 2 as version 1 (its axis
    ///   mapping and variation store are ignored), so its coordinates would
    ///   differ from HarfBuzz's. With no variations such a font loads as
    ///   before, at its default instance.
    pub fn init(gpa: std.mem.Allocator, bytes: []const u8, index: i32, variations: []const Variation) !Font {
        for (variations, 0..) |v, i| {
            if (!std.math.isFinite(v.value)) return error.InvalidNumber;
            for (variations[0..i]) |earlier| {
                if (std.mem.eql(u8, &earlier.tag, &v.tag)) return error.DuplicateVariationTag;
            }
        }
        const owned_bytes = try gpa.dupe(u8, bytes);
        errdefer gpa.free(owned_bytes);
        if (!fontBytesAreSafeForKb(owned_bytes, index)) return error.InvalidFont;
        if (variations.len != 0) {
            if (try sfnt.avarMajorVersion(owned_bytes, index)) |major| {
                if (major != 1) return error.UnsupportedAvarVersion;
            }
        }
        const font_bytes_len = std.math.cast(c_int, owned_bytes.len) orelse return error.InputTooLarge;
        const font_index = std.math.cast(c_int, index) orelse return error.InputTooLarge;

        const kb = try gpa.create(KbMemory);
        errdefer gpa.destroy(kb);
        kb.* = .{
            .font_arena = .init(gpa),
            .context_arena = .init(gpa),
            .font_allocator = undefined,
            .context_allocator = undefined,
            .font_bridge = .{ .alloc = bridgeAlloc, .user_data = &kb.font_allocator },
            .context_bridge = .{ .alloc = bridgeAlloc, .user_data = &kb.context_allocator },
        };
        kb.font_allocator = kb.font_arena.allocator();
        kb.context_allocator = kb.context_arena.allocator();
        errdefer kb.font_arena.deinit();

        // kb is done with the load scratch when PlaceBlob returns.
        var scratch_arena: std.heap.ArenaAllocator = .init(gpa);
        defer scratch_arena.deinit();
        var scratch_allocator = scratch_arena.allocator();
        var scratch_bridge: AllocatorBridge = .{ .alloc = bridgeAlloc, .user_data = &scratch_allocator };

        var font: ?*OpaqueFont = null;
        const err_code_raw = kbshim_font_create(&kb.font_bridge, &scratch_bridge, &kb.context_bridge, owned_bytes.ptr, font_bytes_len, font_index, &font);
        if (err_code_raw > @backingInt(LoadFontErrorCode.count)) return error.UnknownLoadFontError;
        const err_code: LoadFontErrorCode = @fromBackingInt(@intCast(err_code_raw));
        switch (err_code) {
            .none => {},
            .need_to_create_blob => return error.NeedToCreateBlob,
            .invalid_font => return error.InvalidFont,
            .out_of_memory => return error.OutOfMemory,
            .could_not_open_file => return error.CouldNotOpenFile,
            .read_error => return error.ReadError,
            .count => return error.LoadFontErrorCount,
        }

        const handle = font.?;
        errdefer kbshim_font_destroy(handle);
        const instance = try setInstance(kb.font_allocator, handle, variations);

        return .{
            .gpa = gpa,
            .id = font_ids.take(),
            .bytes = owned_bytes,
            .index = index,
            .kb = kb,
            .handle = handle,
            .normalized = instance.normalized,
            .coordinates = instance.coordinates,
            .default_coordinates = instance.defaults,
        };
    }

    /// True when the instance is not the default one: some normalized
    /// coordinate is not 0. Only then does the PDF embed instanced outlines.
    pub fn isInstanced(self: *const Font) bool {
        return std.mem.indexOfNone(i16, self.normalized, &.{0}) != null;
    }

    /// How far the instance moves the font metric MVAR names `tag` ("hasc",
    /// "hdsc", "cpht"), in font units, rounded half up as fontTools rounds
    /// MVAR deltas. 0 for the default instance, for a font without axes, and
    /// for a tag the font's MVAR does not vary.
    ///
    /// kbts_FontMetric is the MVAR delta for every font and tag (0 without
    /// MVAR). The value at the instance minus the value at the default stays
    /// the delta even for an MVAR whose delta at the default is not 0.
    pub fn metricDelta(self: *const Font, tag: *const [4]u8) !i32 {
        if (self.coordinates.len == 0) return 0;
        const kb_tag = std.mem.readInt(u32, tag, .little);
        const at_instance = kbshim_font_metric(self.handle, kb_tag, @constCast(self.coordinates.ptr));
        const at_default = kbshim_font_metric(self.handle, kb_tag, @constCast(self.default_coordinates.ptr));
        const delta = @floor(@as(f64, at_instance) - @as(f64, at_default) + 0.5);
        if (!(delta >= -32768 and delta <= 32767)) return error.InvalidFont;
        return @intFromFloat(delta);
    }

    /// The advance kb's shaping gives `glyph_id` before GPOS, in font units, at
    /// this instance: hmtx plus the HVAR delta, or gvar's phantom points for a
    /// variable font without HVAR (kbts_GetGlyphAdvanceX).
    pub fn glyphAdvanceX(self: *const Font, glyph_id: u16) i32 {
        return kbshim_glyph_advance_x(self.handle, glyph_id);
    }

    /// The glyph outlines of this instance, as the PDF embeds them (see
    /// Outlines). They read the font's bytes, so the Font must outlive them.
    pub fn outlines(self: *const Font, gpa: std.mem.Allocator) !Outlines {
        return Outlines.init(gpa, self.bytes, self.index, self.normalized);
    }

    /// The font's variation axes in fvar order, as kb reads them
    /// (kbts_GetVariationAxisInfo): the same ranges and defaults that `init`
    /// normalizes against, so a value inside [minimum, maximum] is never
    /// clamped. Empty for a font with no axes. Allocated with `allocator`.
    pub fn axes(self: *const Font, allocator: std.mem.Allocator) ![]Axis {
        const out = try allocator.alloc(Axis, @intCast(kbshim_font_axis_count(self.handle)));
        errdefer allocator.free(out);
        for (out, 0..) |*axis, axis_index| {
            var tag: u32 = 0;
            var hidden: c_int = 0;
            if (kbshim_font_axis_info(self.handle, @intCast(axis_index), &tag, &axis.minimum, &axis.default, &axis.maximum, &hidden) == 0) {
                return error.InvalidFont;
            }
            std.mem.writeInt(u32, &axis.tag, tag, .little);
            axis.hidden = hidden != 0;
        }
        return out;
    }

    pub fn deinit(self: *Font) void {
        kbshim_font_destroy(self.handle);
        self.kb.context_arena.deinit();
        self.kb.font_arena.deinit();
        self.gpa.destroy(self.kb);
        self.gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Builds the user-unit vector (fvar order) from `variations` and has kb
/// normalize it into the font arena. See Font.init for the rules.
const InstanceVectors = struct {
    normalized: []const i16,
    coordinates: []const f32,
    defaults: []const f32,
};

fn setInstance(arena: std.mem.Allocator, handle: *OpaqueFont, variations: []const Variation) !InstanceVectors {
    const axis_count: usize = @intCast(kbshim_font_axis_count(handle));
    if (axis_count == 0) return .{ .normalized = &.{}, .coordinates = &.{}, .defaults = &.{} };
    const vector = try arena.alloc(f32, axis_count);
    const defaults = try arena.alloc(f32, axis_count);
    const normalized = try arena.alloc(i16, axis_count);
    for (vector, 0..) |*coord, axis_index| {
        var tag: u32 = 0;
        var minimum: f32 = 0;
        var default_value: f32 = 0;
        var maximum: f32 = 0;
        var hidden: c_int = 0;
        if (kbshim_font_axis_info(handle, @intCast(axis_index), &tag, &minimum, &default_value, &maximum, &hidden) == 0) {
            return error.InvalidFont;
        }
        coord.* = default_value;
        defaults[axis_index] = default_value;
        // kb keeps a tag as its four bytes in file order, read little-endian
        // (KBTS_FOURCC).
        for (variations) |v| {
            if (std.mem.readInt(u32, &v.tag, .little) == tag) coord.* = v.value;
        }
    }
    kbshim_font_set_instance(handle, vector.ptr, normalized.ptr);
    try checkNormalized(normalized);
    return .{ .normalized = normalized, .coordinates = vector, .defaults = defaults };
}

/// A normalized coordinate is F2Dot14 in [-1, 1]; gvar scalars and the
/// instancer rely on it. kb has returned -21846 for a corrupted fvar (an axis
/// minimum above its default) in a Debug build and 0 in ReleaseFast (t-3242),
/// so a value outside the range fails the font.
fn checkNormalized(normalized: []const i16) !void {
    for (normalized) |coord| {
        if (coord < -16384 or coord > 16384) return error.InvalidFont;
    }
}

test "checkNormalized refuses coordinates outside F2Dot14 [-1, 1]" {
    try checkNormalized(&.{ -16384, 0, 16384 });
    try std.testing.expectError(error.InvalidFont, checkNormalized(&.{ 0, -16385 }));
    try std.testing.expectError(error.InvalidFont, checkNormalized(&.{-21846}));
    try std.testing.expectError(error.InvalidFont, checkNormalized(&.{16385}));
}

/// Parses HarfBuzz-style variation settings: `tag=value` items separated by
/// commas, such as "wght=700,wdth=80". A tag of 1 to 4 printable ASCII
/// characters is padded with spaces to 4, as HarfBuzz does. The result is
/// allocated with `allocator`. Duplicates and unknown tags are left for
/// Font.init to judge.
pub fn parseVariations(allocator: std.mem.Allocator, text: []const u8) ![]Variation {
    var list = ManagedList(Variation).init(allocator);
    errdefer list.deinit();
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse return error.InvalidVariation;
        const tag_text = item[0..eq];
        if (tag_text.len == 0 or tag_text.len > 4) return error.InvalidVariation;
        var tag: [4]u8 = @splat(' ');
        for (tag_text, 0..) |c, i| {
            if (c < 0x21 or c > 0x7E) return error.InvalidVariation;
            tag[i] = c;
        }
        const value = std.fmt.parseFloat(f32, item[eq + 1 ..]) catch return error.InvalidVariation;
        try list.append(.{ .tag = tag, .value = value });
    }
    return list.toOwnedSlice();
}

pub const ShapeOptions = struct {
    paragraph_direction: Direction = .dont_know,
    language: u32 = 0,
};

/// One shaped paragraph, with what it was shaped from, so a consumer such as
/// Document.drawShaped cannot pair glyphs with the wrong text or font.
pub const ShapeResult = struct {
    /// The id of the Font that shaped it (Font.id). An id, not an address:
    /// the result may outlive the font, and a later Font can sit at the
    /// same address.
    font_id: u64,
    /// A copy of the UTF-8 that was shaped. A glyph's `cluster` is an index
    /// into its codepoints.
    text: []u8,
    /// Glyph order follows kb output order. For RTL runs this is visual order.
    glyphs: []Glyph,
    runs: []Run,

    pub fn deinit(self: *ShapeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.glyphs);
        allocator.free(self.runs);
        self.* = undefined;
    }
};

/// Where shaping places each glyph: its origin relative to the line's
/// origin, in font units, y up. Each glyph sits at the pen plus its offset,
/// then the pen moves by its advance. Every consumer of a ShapeResult places
/// glyphs with this, so a PDF and a canvas cannot disagree on where a mark or
/// an RTL glyph goes.
pub const Pen = struct {
    x: i64 = 0,
    y: i64 = 0,

    pub const Origin = struct { x: i64, y: i64 };

    pub fn place(self: *Pen, glyph: Glyph) Origin {
        const origin: Origin = .{ .x = self.x + glyph.offset_x, .y = self.y + glyph.offset_y };
        self.x += glyph.advance_x;
        self.y += glyph.advance_y;
        return origin;
    }
};

const EmitContext = struct {
    glyphs: ManagedList(Glyph),
    runs: ManagedList(Run),
    failed: bool = false,

    fn emitGlyph(user_data: ?*anyopaque, glyph: *const Glyph) callconv(.c) c_int {
        const self: *EmitContext = @ptrCast(@alignCast(user_data orelse return 0));
        self.glyphs.append(glyph.*) catch {
            self.failed = true;
            return 0;
        };
        return 1;
    }

    fn emitRun(user_data: ?*anyopaque, run: *const Run) callconv(.c) c_int {
        const self: *EmitContext = @ptrCast(@alignCast(user_data orelse return 0));
        self.runs.append(run.*) catch {
            self.failed = true;
            return 0;
        };
        return 1;
    }
};

/// Shapes one paragraph of `utf8` with `font`. The result is allocated with
/// `allocator` and owned by the caller. kb's own memory comes from the font.
pub fn shape(allocator: std.mem.Allocator, font: *Font, utf8: []const u8, options: ShapeOptions) !ShapeResult {
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    switch (options.paragraph_direction) {
        .dont_know, .ltr, .rtl => {},
        _ => return error.InvalidDirection,
    }
    const utf8_len = std.math.cast(c_int, utf8.len) orelse return error.InputTooLarge;

    var emit_context: EmitContext = .{
        .glyphs = ManagedList(Glyph).init(allocator),
        .runs = ManagedList(Run).init(allocator),
    };
    defer emit_context.glyphs.deinit();
    defer emit_context.runs.deinit();

    const shape_err_raw = kbshim_shape_utf8(
        font.handle,
        utf8.ptr,
        utf8_len,
        @backingInt(options.paragraph_direction),
        options.language,
        EmitContext.emitGlyph,
        EmitContext.emitRun,
        &emit_context,
    );
    // The shim drops the context on any failure; keep "no context means an
    // empty context arena" true before anything can shape again.
    if (kbshim_font_has_context(font.handle) == 0) {
        _ = font.kb.context_arena.reset(.free_all);
    }
    if (shape_err_raw > @backingInt(ShapeErrorCode.count)) return error.UnknownShapeError;
    const shape_err: ShapeErrorCode = @fromBackingInt(@intCast(shape_err_raw));

    if (emit_context.failed) return error.OutOfMemory;
    switch (shape_err) {
        .none => {},
        .invalid_font => return error.InvalidFont,
        .gave_text_before_calling_begin => return error.GaveTextBeforeCallingBegin,
        .out_of_memory => return error.OutOfMemory,
        .too_many_operations => return error.TooManyOperations,
        .count => return error.ShapeErrorCount,
    }

    const visual = try visualOrder(allocator, emit_context.glyphs.items, emit_context.runs.items);
    errdefer allocator.free(visual.glyphs);
    errdefer allocator.free(visual.runs);
    return .{
        .font_id = font.id,
        .text = try allocator.dupe(u8, utf8),
        .glyphs = visual.glyphs,
        .runs = visual.runs,
    };
}

/// The line's runs in visual order, left to right. kb returns runs in logical
/// order and only flips the glyphs inside a right-to-left run, so without this
/// an RTL paragraph's runs would be drawn first-to-last from the left.
///
/// This is kb's own model of a line, as its author's reference editor refpad
/// lays one out (refpad_editor.c: blocks of one direction; an RTL paragraph
/// shows them in reverse). The levels come from kb's run directions: in an
/// LTR paragraph LTR runs are level 0 and RTL runs 1; in an RTL paragraph RTL
/// runs are 1 and LTR runs 2. Then, from the highest level down to the lowest
/// odd one, every maximal sequence of runs at that level or above is reversed
/// (UAX #9 rule L2). Glyphs keep their order within a run.
///
/// It is not strict UAX #9: kb resolves directions for shaping and leans to
/// LTR on purpose (neutrals and digits next to a direction change, a leading
/// bracket), and it does not support explicit embeddings or isolates
/// (U+202A..U+202E, U+2066..U+2069). How far the two differ is measured by
/// the "line order" test against tests/bidi/cases.tsv.
/// Both slices are new, allocated with `allocator`.
fn visualOrder(allocator: std.mem.Allocator, glyphs: []const Glyph, runs: []const Run) !struct { glyphs: []Glyph, runs: []Run } {
    const order = try allocator.alloc(usize, runs.len);
    defer allocator.free(order);
    const levels = try allocator.alloc(u8, runs.len);
    defer allocator.free(levels);
    var highest: u8 = 0;
    var lowest_odd: u8 = 255;
    for (runs, levels, order, 0..) |r, *level, *o, i| {
        o.* = i;
        const rtl_paragraph = r.paragraph_direction == @backingInt(Direction.rtl);
        level.* = if (r.direction == @backingInt(Direction.rtl)) 1 else if (rtl_paragraph) 2 else 0;
        highest = @max(highest, level.*);
        if (level.* % 2 == 1) lowest_odd = @min(lowest_odd, level.*);
    }
    var level = highest;
    while (level >= lowest_odd and level > 0) : (level -= 1) {
        var i: usize = 0;
        while (i < order.len) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < order.len and levels[order[j]] >= level) j += 1;
            std.mem.reverse(usize, order[i..j]);
            i = j;
        }
    }

    const out_glyphs = try allocator.alloc(Glyph, glyphs.len);
    errdefer allocator.free(out_glyphs);
    const out_runs = try allocator.alloc(Run, runs.len);
    var at: u32 = 0;
    for (order, out_runs) |from, *to| {
        const r = runs[from];
        if (@as(usize, r.glyph_start) + r.glyph_count > glyphs.len) {
            allocator.free(out_runs);
            return error.InvalidFont;
        }
        @memcpy(out_glyphs[at..][0..r.glyph_count], glyphs[r.glyph_start..][0..r.glyph_count]);
        to.* = r;
        to.glyph_start = at;
        at += r.glyph_count;
    }
    if (at != glyphs.len) {
        allocator.free(out_runs);
        return error.InvalidFont;
    }
    return .{ .glyphs = out_glyphs, .runs = out_runs };
}

test "visualOrder: UAX #9 L2 over runs, derived levels" {
    const gpa = std.testing.allocator;
    const L = @backingInt(Direction.ltr);
    const R = @backingInt(Direction.rtl);
    const g = struct {
        fn glyph(id: u16) Glyph {
            return .{ .id = id, ._reserved0 = 0, .cluster = id, .advance_x = 1, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
        }
        fn run(dir: u32, para: u32, start: u32, count: u32) Run {
            return .{ .direction = dir, .script = 0, .glyph_start = start, .glyph_count = count, .paragraph_direction = para };
        }
    };
    const glyphs = [_]Glyph{ g.glyph(0), g.glyph(1), g.glyph(2), g.glyph(3), g.glyph(4), g.glyph(5) };
    const Case = struct { runs: []const Run, want: []const u16 };
    const cases = [_]Case{
        // LTR paragraph: an RTL run stays where it is; two RTL runs in a row swap.
        .{ .runs = &.{ g.run(L, L, 0, 2), g.run(R, L, 2, 2), g.run(L, L, 4, 2) }, .want = &.{ 0, 1, 2, 3, 4, 5 } },
        .{ .runs = &.{ g.run(L, L, 0, 2), g.run(R, L, 2, 2), g.run(R, L, 4, 2) }, .want = &.{ 0, 1, 4, 5, 2, 3 } },
        // RTL paragraph: runs right to left; LTR runs in a row keep their order.
        .{ .runs = &.{ g.run(R, R, 0, 2), g.run(L, R, 2, 2), g.run(R, R, 4, 2) }, .want = &.{ 4, 5, 2, 3, 0, 1 } },
        .{ .runs = &.{ g.run(R, R, 0, 2), g.run(L, R, 2, 2), g.run(L, R, 4, 2) }, .want = &.{ 2, 3, 4, 5, 0, 1 } },
        // One run: unchanged either way.
        .{ .runs = &.{g.run(R, R, 0, 6)}, .want = &.{ 0, 1, 2, 3, 4, 5 } },
    };
    for (cases) |case| {
        const v = try visualOrder(gpa, &glyphs, case.runs);
        defer gpa.free(v.glyphs);
        defer gpa.free(v.runs);
        var ids: [6]u16 = undefined;
        for (v.glyphs, &ids) |gl, *id| id.* = gl.id;
        try std.testing.expectEqualSlices(u16, case.want, &ids);
        var at: u32 = 0;
        for (v.runs) |r| {
            try std.testing.expectEqual(at, r.glyph_start);
            at += r.glyph_count;
        }
    }
}

test "font loads from memory and deinit frees" {
    const options = @import("build_options");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_latin, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var font = try Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();
}

test "font rejects junk bytes" {
    const junk = "not_a_font";
    try std.testing.expectError(error.InvalidFont, Font.init(std.testing.allocator, junk, 0, &.{}));
}

test "font rejects empty bytes" {
    try std.testing.expectError(error.InvalidFont, Font.init(std.testing.allocator, "", 0, &.{}));
}

test "font rejects kbts baked blob" {
    // kbts_blob_header is 10 u32 fields plus Tables[KBTS_BLOB_TABLE_ID_COUNT]
    // (18 entries of two u32s): 40 + 144 = 184 bytes. kb's baked loader does
    // no bounds checks; refuse the magic before calling kb.
    var kbts_buf: [184]u8 = @splat(0);
    @memcpy(kbts_buf[0..4], "kbts");
    try std.testing.expectError(error.InvalidFont, Font.init(std.testing.allocator, &kbts_buf, 0, &.{}));
}

test "font rejects short sfnt header" {
    const short = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF };
    try std.testing.expectError(error.InvalidFont, Font.init(std.testing.allocator, &short, 0, &.{}));
}

test "font rejects ttcf directory offset past the end" {
    const ttc = [_]u8{
        't',  't',  'c',  'f',
        0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x64,
    };
    try std.testing.expectError(error.InvalidFont, Font.init(std.testing.allocator, &ttc, 0, &.{}));
}

test "font init/deinit uses allocator bridge" {
    const options = @import("build_options");

    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const alloc = counting.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_latin, alloc, .unlimited);

    var font = try Font.init(alloc, bytes, 0, &.{});
    font.deinit();
    alloc.free(bytes);
    try std.testing.expect(counting.allocations > 0);
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
}

test "shape rejects invalid utf8" {
    const options = @import("build_options");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_latin, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var font = try Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();

    try std.testing.expectError(error.InvalidUtf8, shape(std.testing.allocator, &font, "\xff", .{}));
}

test "shape rejects unknown paragraph direction" {
    const options = @import("build_options");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.test_font_latin, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var font = try Font.init(std.testing.allocator, bytes, 0, &.{});
    defer font.deinit();

    const bad: Direction = @fromBackingInt(@intCast(99));
    try std.testing.expectError(error.InvalidDirection, shape(std.testing.allocator, &font, "a", .{ .paragraph_direction = bad }));
}

fn loadFontForTest(allocator: std.mem.Allocator, path: []const u8) !Font {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return Font.init(allocator, bytes, 0, &.{});
}

fn shapeFixture(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !ShapeResult {
    var font = try loadFontForTest(allocator, path);
    defer font.deinit();
    return shape(allocator, &font, text, .{});
}

test "checkAllAllocationFailures: font load plus shape" {
    const options = @import("build_options");
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, path: []const u8) !void {
            var result = try shapeFixture(allocator, path, "a");
            result.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{options.test_font_latin});
}

test "shape ffi ligature from HarfBuzz test font" {
    const options = @import("build_options");
    var result = try shapeFixture(std.testing.allocator, options.test_font_latin, "ffi");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.glyphs.len < 3);
    try std.testing.expect(result.glyphs.len >= 1);
}

test "shape mark to base from HarfBuzz test font" {
    const options = @import("build_options");
    var result = try shapeFixture(std.testing.allocator, options.test_font_marks, "x\u{0301}");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.glyphs.len >= 2);
    var has_zero_advance = false;
    for (result.glyphs) |g| {
        if (g.advance_x == 0) {
            has_zero_advance = true;
            break;
        }
    }
    try std.testing.expect(has_zero_advance);
}

test "shape devanagari reordering from HarfBuzz test font" {
    const options = @import("build_options");
    var result = try shapeFixture(std.testing.allocator, options.test_font_devanagari, "\u{091F}\u{094D}\u{0930}\u{0942}");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.glyphs.len >= 2);
    try std.testing.expect(result.runs.len >= 1);
    try std.testing.expect(result.runs[0].script != 0);
}

test "shape arabic joining from HarfBuzz test font" {
    const options = @import("build_options");
    var result = try shapeFixture(std.testing.allocator, options.test_font_arabic, "\u{0628}\u{0628}\u{0628}");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.runs.len >= 1);
    try std.testing.expectEqual(@backingInt(Direction.rtl), result.runs[0].direction);
    try std.testing.expect(result.glyphs.len >= 3);
}

test "shape hebrew rtl from HarfBuzz test font" {
    const options = @import("build_options");
    var result = try shapeFixture(std.testing.allocator, options.test_font_hebrew, "\u{05E7}\u{05D5}\u{05DC}");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.runs.len >= 1);
    try std.testing.expectEqual(@backingInt(Direction.rtl), result.runs[0].direction);
    try std.testing.expect(result.glyphs.len >= 3);
    try std.testing.expect(result.glyphs[0].cluster > result.glyphs[result.glyphs.len - 1].cluster);
}

test "shape reports TooManyOperations for known TestGSUBThree trigger" {
    const options = @import("build_options");
    var font = try loadFontForTest(std.testing.allocator, options.test_font_toomanyops);
    defer font.deinit();

    try std.testing.expectError(error.TooManyOperations, shape(std.testing.allocator, &font, "lol", .{}));
}

fn emitGlyphAlwaysFail(_: ?*anyopaque, _: *const Glyph) callconv(.c) c_int {
    return 0;
}

fn emitRunAlwaysFail(_: ?*anyopaque, _: *const Run) callconv(.c) c_int {
    return 0;
}

test "shim returns TooManyOperations when emit_glyph rejects the run" {
    const options = @import("build_options");
    var font = try loadFontForTest(std.testing.allocator, options.test_font_toomanyops);
    defer font.deinit();

    const text = "lol";
    const text_len = std.math.cast(c_int, text.len) orelse return error.InputTooLarge;
    const code = kbshim_shape_utf8(
        font.handle,
        text.ptr,
        text_len,
        @backingInt(Direction.dont_know),
        0,
        emitGlyphAlwaysFail,
        emitRunAlwaysFail,
        null,
    );
    try std.testing.expectEqual(0, kbshim_font_has_context(font.handle));
    try std.testing.expectEqual(@backingInt(ShapeErrorCode.too_many_operations), code);
}

// Lines that reach several kb shape configs on one font: scripts, forced
// directions, and repeats, so later lines hit configs cached by earlier ones.
const ReuseCase = struct { text: []const u8, direction: Direction };
const reuse_fonts = [_]struct { path_field: []const u8, cases: []const ReuseCase }{
    .{ .path_field = "test_font_roboto", .cases = &.{
        .{ .text = "office affine AVATAR", .direction = .dont_know },
        .{ .text = "Tie\u{0302}\u{0301}ng Vie\u{0323}\u{0302}t", .direction = .ltr },
        .{ .text = "office affine AVATAR", .direction = .rtl },
    } },
    .{ .path_field = "test_font_noto_devanagari", .cases = &.{
        .{ .text = "\u{0915}\u{093F} \u{0915}\u{094D}\u{0937}", .direction = .dont_know },
        .{ .text = "abc \u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}", .direction = .dont_know },
    } },
    .{ .path_field = "test_font_amiri", .cases = &.{
        .{ .text = "\u{0628}\u{0633}\u{0645} \u{0627}\u{0644}\u{0644}\u{0647}", .direction = .dont_know },
        .{ .text = "123 \u{0644}\u{0627} abc", .direction = .ltr },
        .{ .text = "\u{0628}\u{0650}\u{0633}\u{0652}\u{0645}\u{0650}", .direction = .rtl },
    } },
    .{ .path_field = "test_font_noto_hebrew", .cases = &.{
        .{ .text = "\u{05E9}\u{05B8}\u{05C1}\u{05DC}\u{05D5}\u{05B9}\u{05DD}", .direction = .dont_know },
        .{ .text = "hello \u{05E9}\u{05DC}\u{05D5}\u{05DD}", .direction = .ltr },
    } },
};

fn reuseFontPath(comptime field: []const u8) []const u8 {
    return @field(@import("build_options"), field);
}

fn expectSameShape(got: ShapeResult, want: ShapeResult) !void {
    try std.testing.expectEqualSlices(Glyph, want.glyphs, got.glyphs);
    try std.testing.expectEqualSlices(Run, want.runs, got.runs);
}

fn shapeFresh(allocator: std.mem.Allocator, path: []const u8, case: ReuseCase) !ShapeResult {
    var font = try loadFontForTest(allocator, path);
    defer font.deinit();
    return shape(allocator, &font, case.text, .{ .paragraph_direction = case.direction });
}

test "one font shapes every line as a fresh font would, three passes over mixed scripts" {
    const gpa = std.testing.allocator;
    inline for (reuse_fonts) |rf| {
        const path = reuseFontPath(rf.path_field);
        var font = try loadFontForTest(gpa, path);
        defer font.deinit();
        var pass: u32 = 0;
        while (pass < 3) : (pass += 1) {
            for (rf.cases) |case| {
                var got = try shape(gpa, &font, case.text, .{ .paragraph_direction = case.direction });
                defer got.deinit(gpa);
                var want = try shapeFresh(gpa, path, case);
                defer want.deinit(gpa);
                try expectSameShape(got, want);
            }
        }
        try std.testing.expect(kbshim_font_has_context(font.handle) != 0);
    }
}

test "a second shape of the same text allocates nothing from the font" {
    const options = @import("build_options");
    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var font = try loadFontForTest(counting.allocator(), options.test_font_amiri);
    defer font.deinit();
    const text = "\u{0628}\u{0633}\u{0645} \u{0627}\u{0644}\u{0644}\u{0647}";

    const before_first = counting.allocations;
    var first = try shape(std.testing.allocator, &font, text, .{});
    defer first.deinit(std.testing.allocator);
    // The first shape builds the context and the Arabic config, so it must
    // allocate; otherwise the zero below proves nothing.
    try std.testing.expect(counting.allocations > before_first);

    const before_second = counting.allocations;
    var second = try shape(std.testing.allocator, &font, text, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(before_second, counting.allocations);
    try expectSameShape(second, first);
}

test "after TooManyOperations the same font shapes like a fresh font" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    var font = try loadFontForTest(gpa, options.test_font_toomanyops);
    defer font.deinit();

    var warm = try shape(gpa, &font, "a", .{});
    warm.deinit(gpa);
    try std.testing.expect(kbshim_font_has_context(font.handle) != 0);

    try std.testing.expectError(error.TooManyOperations, shape(gpa, &font, "lol", .{}));
    try std.testing.expectEqual(0, kbshim_font_has_context(font.handle));
    try std.testing.expectEqual(0, font.kb.context_arena.queryCapacity());

    var got = try shape(gpa, &font, "a", .{});
    defer got.deinit(gpa);
    var want = try shapeFresh(gpa, options.test_font_toomanyops, .{ .text = "a", .direction = .dont_know });
    defer want.deinit(gpa);
    try expectSameShape(got, want);
}

const FailPoint = enum {
    /// Each kb allocation of the font's context, on a context that is already
    /// warm with another script, so kb must build a new config.
    kb_warm,
    /// Each kb allocation of the font's first shape: context creation and push.
    kb_cold,
    /// Each allocation of the shape result (zpdf's emit callbacks).
    result,
};

/// Fails every allocation from index `i` on, inside one shape, then lets
/// allocation succeed and requires the same font to shape both lines as a fresh
/// font does. Runs for every i until the shape completes without reaching i.
fn checkShapeRecoversFromEveryAllocationFailure(point: FailPoint, path: []const u8, warm_case: ReuseCase, case: ReuseCase) !void {
    const gpa = std.testing.allocator;

    var want = try shapeFresh(gpa, path, case);
    defer want.deinit(gpa);
    var want_warm = try shapeFresh(gpa, path, warm_case);
    defer want_warm.deinit(gpa);

    var n_failed: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        var font = try loadFontForTest(gpa, path);
        defer font.deinit();
        if (point != .kb_cold) {
            var warm = try shape(gpa, &font, warm_case.text, .{});
            warm.deinit(gpa);
        }

        var failing = std.testing.FailingAllocator.init(
            if (point == .result) gpa else font.kb.context_arena.allocator(),
            .{ .fail_index = i },
        );
        var result_gpa = gpa;
        if (point == .result) {
            result_gpa = failing.allocator();
        } else {
            font.kb.context_allocator = failing.allocator();
        }

        if (shape(result_gpa, &font, case.text, .{})) |result| {
            var r = result;
            defer r.deinit(result_gpa);
            try std.testing.expect(!failing.has_induced_failure);
            try expectSameShape(r, want);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            // A failure inside the kb pass drops the context. A result
            // allocation can also fail after kb succeeded (toOwnedSlice), and
            // then the context is valid and stays.
            if (point != .result) try std.testing.expectEqual(0, kbshim_font_has_context(font.handle));
            n_failed += 1;
        }

        failing.fail_index = std.math.maxInt(usize);
        var again = try shape(result_gpa, &font, case.text, .{});
        defer again.deinit(result_gpa);
        try expectSameShape(again, want);
        var again_warm = try shape(result_gpa, &font, warm_case.text, .{});
        defer again_warm.deinit(result_gpa);
        try expectSameShape(again_warm, want_warm);
    }
    try std.testing.expect(n_failed > 0);
}

test "shape recovers from every kb allocation failure on a warm context" {
    try checkShapeRecoversFromEveryAllocationFailure(.kb_warm, @import("build_options").test_font_noto_hebrew, .{ .text = "hello world", .direction = .dont_know }, .{ .text = "\u{05E9}\u{05B8}\u{05C1}\u{05DC}\u{05D5}\u{05B9}\u{05DD} abc", .direction = .dont_know });
}

test "shape recovers from every kb allocation failure on the first shape of a variable font" {
    // A variable font changes what kb allocates for a new context. It does not
    // pin kb's variation-vector check (kbts__InitializeContextFont): through
    // kbts_ShapePushFont that vector fits in a kb arena block already held, so
    // no bridge allocation fails there. A variable Fraunces test that pushes
    // the font from memory does reach it.
    try checkShapeRecoversFromEveryAllocationFailure(.kb_cold, @import("build_options").test_font_variable, .{ .text = "ABC", .direction = .dont_know }, .{ .text = "ABC fin", .direction = .dont_know });
}

test "shape recovers from every kb allocation failure on the first shape" {
    try checkShapeRecoversFromEveryAllocationFailure(.kb_cold, @import("build_options").test_font_noto_hebrew, .{ .text = "hello world", .direction = .dont_know }, .{ .text = "\u{05E9}\u{05B8}\u{05C1}\u{05DC}\u{05D5}\u{05B9}\u{05DD} abc", .direction = .dont_know });
}

test "shape recovers from every result allocation failure" {
    try checkShapeRecoversFromEveryAllocationFailure(.result, @import("build_options").test_font_noto_hebrew, .{ .text = "hello world", .direction = .dont_know }, .{ .text = "\u{05E9}\u{05B8}\u{05C1}\u{05DC}\u{05D5}\u{05B9}\u{05DD} abc", .direction = .dont_know });
}

test "checkAllAllocationFailures: one font, three shapes over two scripts" {
    const options = @import("build_options");
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, path: []const u8) !void {
            var font = try loadFontForTest(allocator, path);
            defer font.deinit();
            for ([_][]const u8{ "hello", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "hello \u{05E9}\u{05DC}\u{05D5}\u{05DD}" }) |text| {
                var r = try shape(allocator, &font, text, .{});
                r.deinit(allocator);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{options.test_font_noto_hebrew});
}

// Variable fonts. kb shapes at the instance's coordinates and gives the
// advances; these tests hold kb's output to HarfBuzz's.

const HbCase = struct {
    path_field: []const u8,
    text: []const u8,
    variations: []const Variation,
    /// HarfBuzz's glyphs: id, x_advance, x_offset, y_offset, in font units.
    hb: []const [4]i32,
};

/// The exact hb-shape (HarfBuzz 14.6.0) command and output sit above each
/// case; the paths are relative to the harfbuzz package's test/ folder. Clusters
/// are not compared: HarfBuzz merges a mark's cluster into its base
/// (cluster level 0), kb gives each codepoint its own index.
const hb_cases = [_]HbCase{
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=900,wdth=25,opsz=144 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+006F,U+0066,U+0066,U+0069,U+0063,U+0065,U+0020,U+006D,U+0069,U+006E,U+0069,U+006D,U+0075,U+006D
    // [82=0+896|555=1+1512|70=4+895|72=5+900|3=6+456|80=7+1357|76=8+456|81=9+902|76=10+456|80=11+1357|88=12+901|80=13+1357]
    .{ .path_field = "test_font_roboto_flex", .text = "office minimum", .variations = &.{ .{ .tag = "wght".*, .value = 900 }, .{ .tag = "wdth".*, .value = 25 }, .{ .tag = "opsz".*, .value = 144 } }, .hb = &.{ .{ 82, 896, 0, 0 }, .{ 555, 1512, 0, 0 }, .{ 70, 895, 0, 0 }, .{ 72, 900, 0, 0 }, .{ 3, 456, 0, 0 }, .{ 80, 1357, 0, 0 }, .{ 76, 456, 0, 0 }, .{ 81, 902, 0, 0 }, .{ 76, 456, 0, 0 }, .{ 80, 1357, 0, 0 }, .{ 88, 901, 0, 0 }, .{ 80, 1357, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=100,wdth=151,GRAD=-200,slnt=-10 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+006F,U+0066,U+0066,U+0069,U+0063,U+0065,U+0020,U+006D,U+0069,U+006E,U+0069,U+006D,U+0075,U+006D
    // [82=0+1352|555=1+1873|70=4+1239|72=5+1238|3=6+500|80=7+2071|76=8+417|81=9+1282|76=10+417|80=11+2071|88=12+1282|80=13+2071]
    .{ .path_field = "test_font_roboto_flex", .text = "office minimum", .variations = &.{ .{ .tag = "wght".*, .value = 100 }, .{ .tag = "wdth".*, .value = 151 }, .{ .tag = "GRAD".*, .value = -200 }, .{ .tag = "slnt".*, .value = -10 } }, .hb = &.{ .{ 82, 1352, 0, 0 }, .{ 555, 1873, 0, 0 }, .{ 70, 1239, 0, 0 }, .{ 72, 1238, 0, 0 }, .{ 3, 500, 0, 0 }, .{ 80, 2071, 0, 0 }, .{ 76, 417, 0, 0 }, .{ 81, 1282, 0, 0 }, .{ 76, 417, 0, 0 }, .{ 80, 2071, 0, 0 }, .{ 88, 1282, 0, 0 }, .{ 80, 2071, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=650,opsz=36 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+006F,U+0066,U+0066,U+0069,U+0063,U+0065,U+0020,U+006D,U+0069,U+006E,U+0069,U+006D,U+0075,U+006D
    // [82=0+1157|555=1+1790|70=4+1078|72=5+1084|3=6+480|80=7+1753|76=8+523|81=9+1142|76=10+523|80=11+1753|88=12+1141|80=13+1753]
    .{ .path_field = "test_font_roboto_flex", .text = "office minimum", .variations = &.{ .{ .tag = "wght".*, .value = 650 }, .{ .tag = "opsz".*, .value = 36 } }, .hb = &.{ .{ 82, 1157, 0, 0 }, .{ 555, 1790, 0, 0 }, .{ 70, 1078, 0, 0 }, .{ 72, 1084, 0, 0 }, .{ 3, 480, 0, 0 }, .{ 80, 1753, 0, 0 }, .{ 76, 523, 0, 0 }, .{ 81, 1142, 0, 0 }, .{ 76, 523, 0, 0 }, .{ 80, 1753, 0, 0 }, .{ 88, 1141, 0, 0 }, .{ 80, 1753, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=opsz=144,wght=100 subset/data/fonts/Fraunces.ttf --unicodes=U+0066,U+006C,U+0075,U+0066,U+0066,U+0079,U+0020,U+006F,U+0066,U+0066,U+0069,U+0063,U+0065
    // [477=0+803|54=2+903|475=3+868|58=5+811|1=6+350|47=7+914|478=8+1237|31=11+737|33=12+751]
    .{ .path_field = "test_font_variable", .text = "fluffy office", .variations = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } }, .hb = &.{ .{ 477, 803, 0, 0 }, .{ 54, 903, 0, 0 }, .{ 475, 868, 0, 0 }, .{ 58, 811, 0, 0 }, .{ 1, 350, 0, 0 }, .{ 47, 914, 0, 0 }, .{ 478, 1237, 0, 0 }, .{ 31, 737, 0, 0 }, .{ 33, 751, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=opsz=48,wght=500,SOFT=100,WONK=0 subset/data/fonts/Fraunces.ttf --unicodes=U+0066,U+006C,U+0075,U+0066,U+0066,U+0079,U+0020,U+006F,U+0066,U+0066,U+0069,U+0063,U+0065
    // [477=0+1339|54=2+1194|475=3+1483|58=5+1100|1=6+424|47=7+1141|478=8+2081|31=11+999|33=12+1022]
    .{ .path_field = "test_font_variable", .text = "fluffy office", .variations = &.{ .{ .tag = "opsz".*, .value = 48 }, .{ .tag = "wght".*, .value = 500 }, .{ .tag = "SOFT".*, .value = 100 }, .{ .tag = "WONK".*, .value = 0 } }, .hb = &.{ .{ 477, 1339, 0, 0 }, .{ 54, 1194, 0, 0 }, .{ 475, 1483, 0, 0 }, .{ 58, 1100, 0, 0 }, .{ 1, 424, 0, 0 }, .{ 47, 1141, 0, 0 }, .{ 478, 2081, 0, 0 }, .{ 31, 999, 0, 0 }, .{ 33, 1022, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=300,SOFT=50 subset/data/fonts/Fraunces.ttf --unicodes=U+0066,U+006C,U+0075,U+0066,U+0066,U+0079,U+0020,U+006F,U+0066,U+0066,U+0069,U+0063,U+0065
    // [477=0+1262|54=2+1176|475=3+1362|58=5+1084|1=6+466|47=7+1146|478=8+1938|31=11+989|33=12+1022]
    .{ .path_field = "test_font_variable", .text = "fluffy office", .variations = &.{ .{ .tag = "wght".*, .value = 300 }, .{ .tag = "SOFT".*, .value = 50 } }, .hb = &.{ .{ 477, 1262, 0, 0 }, .{ 54, 1176, 0, 0 }, .{ 475, 1362, 0, 0 }, .{ 58, 1084, 0, 0 }, .{ 1, 466, 0, 0 }, .{ 47, 1146, 0, 0 }, .{ 478, 1938, 0, 0 }, .{ 31, 989, 0, 0 }, .{ 33, 1022, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=100,wdth=62.5,CTGR=100 subset/data/fonts/NotoSans-VF.abc.ttf --unicodes=U+0061,U+0062,U+0063,U+0061,U+0062,U+0063
    // [1=0+357|2=1+413|3=2+304|1=3+357|2=4+413|3=5+304]
    .{ .path_field = "test_font_noto_sans_vf", .text = "abcabc", .variations = &.{ .{ .tag = "wght".*, .value = 100 }, .{ .tag = "wdth".*, .value = 62.5 }, .{ .tag = "CTGR".*, .value = 100 } }, .hb = &.{ .{ 1, 357, 0, 0 }, .{ 2, 413, 0, 0 }, .{ 3, 304, 0, 0 }, .{ 1, 357, 0, 0 }, .{ 2, 413, 0, 0 }, .{ 3, 304, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=900,wdth=80 subset/data/fonts/NotoSans-VF.abc.ttf --unicodes=U+0061,U+0062,U+0063,U+0061,U+0062,U+0063
    // [1=0+550|2=1+576|3=2+479|1=3+550|2=4+576|3=5+479]
    .{ .path_field = "test_font_noto_sans_vf", .text = "abcabc", .variations = &.{ .{ .tag = "wght".*, .value = 900 }, .{ .tag = "wdth".*, .value = 80 } }, .hb = &.{ .{ 1, 550, 0, 0 }, .{ 2, 576, 0, 0 }, .{ 3, 479, 0, 0 }, .{ 1, 550, 0, 0 }, .{ 2, 576, 0, 0 }, .{ 3, 479, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=250,CTGR=40 subset/data/fonts/NotoSans-VF.abc.ttf --unicodes=U+0061,U+0062,U+0063,U+0061,U+0062,U+0063
    // [1=0+517|2=1+580|3=2+464|1=3+517|2=4+580|3=5+464]
    .{ .path_field = "test_font_noto_sans_vf", .text = "abcabc", .variations = &.{ .{ .tag = "wght".*, .value = 250 }, .{ .tag = "CTGR".*, .value = 40 } }, .hb = &.{ .{ 1, 517, 0, 0 }, .{ 2, 580, 0, 0 }, .{ 3, 464, 0, 0 }, .{ 1, 517, 0, 0 }, .{ 2, 580, 0, 0 }, .{ 3, 464, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=100 shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf --unicodes=U+0634,U+0652
    // [12=0@663,144+0|5=0+1164]
    .{ .path_field = "test_font_gpos_four", .text = "\u{0634}\u{0652}", .variations = &.{.{ .tag = "wght".*, .value = 100 }}, .hb = &.{ .{ 12, 0, 663, 144 }, .{ 5, 1164, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=900,wdth=70 shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf --unicodes=U+0634,U+0652
    // [12=0@614,389+0|5=0+1242]
    .{ .path_field = "test_font_gpos_four", .text = "\u{0634}\u{0652}", .variations = &.{ .{ .tag = "wght".*, .value = 900 }, .{ .tag = "wdth".*, .value = 70 } }, .hb = &.{ .{ 12, 0, 614, 389 }, .{ 5, 1242, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=350,wdth=85 shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf --unicodes=U+0634,U+0652
    // [12=0@604,174+0|5=0+1078]
    .{ .path_field = "test_font_gpos_four", .text = "\u{0634}\u{0652}", .variations = &.{ .{ .tag = "wght".*, .value = 350 }, .{ .tag = "wdth".*, .value = 85 } }, .hb = &.{ .{ 12, 0, 604, 174 }, .{ 5, 1078, 0, 0 } } },
    // GPOS pair kerning with variation deltas (kb t-3234, fixed in dimenus/kb 0ad1552).
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wght=900 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+0041,U+0056,U+0041
    // [36=0+1437|57=1+1405|36=2+1452]
    .{ .path_field = "test_font_roboto_flex", .text = "AVA", .variations = &.{.{ .tag = "wght".*, .value = 900 }}, .hb = &.{ .{ 36, 1437, 0, 0 }, .{ 57, 1405, 0, 0 }, .{ 36, 1452, 0, 0 } } },
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=wdth=25 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+0041,U+0056,U+0041
    // [36=0+1087|57=1+1046|36=2+1087]
    .{ .path_field = "test_font_roboto_flex", .text = "AVA", .variations = &.{.{ .tag = "wdth".*, .value = 25 }}, .hb = &.{ .{ 36, 1087, 0, 0 }, .{ 57, 1046, 0, 0 }, .{ 36, 1087, 0, 0 } } },
    // A GSUB FeatureVariations substitution, 'n' 46 -> 45 at a large opsz (kb t-3235, fixed in dimenus/kb bf74214).
    // cd harfbuzz/test && hb-shape --no-glyph-names --variations=opsz=144,wght=100 subset/data/fonts/Fraunces.ttf --unicodes=U+006E
    // [45=0+910]
    .{ .path_field = "test_font_variable", .text = "n", .variations = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } }, .hb = &.{.{ 45, 910, 0, 0 }} },
};

fn expectSameAsHarfBuzz(glyphs: []const Glyph, hb: []const [4]i32) !void {
    try std.testing.expectEqual(hb.len, glyphs.len);
    for (glyphs, hb) |g, want| {
        try std.testing.expectEqual(want, [4]i32{ g.id, g.advance_x, g.offset_x, g.offset_y });
        try std.testing.expectEqual(0, g.advance_y);
    }
}

/// expectSameAsHarfBuzz without the failure report, for tests that require a
/// difference.
fn sameAsHarfBuzz(glyphs: []const Glyph, hb: []const [4]i32) bool {
    if (glyphs.len != hb.len) return false;
    for (glyphs, hb) |g, want| {
        if (!std.meta.eql(want, [4]i32{ g.id, g.advance_x, g.offset_x, g.offset_y }) or g.advance_y != 0) return false;
    }
    return true;
}

fn loadVariableFontForTest(allocator: std.mem.Allocator, path: []const u8, variations: []const Variation) !Font {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return Font.init(allocator, bytes, 0, variations);
}

test "shaping at variation coordinates equals HarfBuzz" {
    const gpa = std.testing.allocator;
    inline for (hb_cases) |case| {
        var font = try loadVariableFontForTest(gpa, reuseFontPath(case.path_field), case.variations);
        defer font.deinit();
        // Every case is a non-default instance, so a font that ignored its
        // variations would fail here rather than match by accident.
        try std.testing.expect(std.mem.indexOfNone(i16, font.normalized, &.{0}) != null);
        var got = try shape(gpa, &font, case.text, .{});
        defer got.deinit(gpa);
        try expectSameAsHarfBuzz(got.glyphs, case.hb);
    }
}

test "the same text at the default instance differs from every HarfBuzz case" {
    // Proves each case above depends on its coordinates: shaped with no
    // variations, at least one glyph's id, advance or offset is different.
    const gpa = std.testing.allocator;
    inline for (hb_cases) |case| {
        var font = try loadVariableFontForTest(gpa, reuseFontPath(case.path_field), &.{});
        defer font.deinit();
        var got = try shape(gpa, &font, case.text, .{});
        defer got.deinit(gpa);
        try std.testing.expect(!sameAsHarfBuzz(got.glyphs, case.hb));
    }
}

test "glyphAdvanceX equals HarfBuzz's unkerned advances at the instance" {
    const gpa = std.testing.allocator;
    const Case = struct { path_field: []const u8, variations: []const Variation, gid: u16, hb: i32 };
    const cases = [_]Case{
        // HVAR. hb-shape --no-glyph-names --features=-kern --variations=wght=900 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+0041,U+0056
        // [36=0+1452|57=1+1418]
        .{ .path_field = "test_font_roboto_flex", .variations = &.{.{ .tag = "wght".*, .value = 900 }}, .gid = 36, .hb = 1452 },
        .{ .path_field = "test_font_roboto_flex", .variations = &.{.{ .tag = "wght".*, .value = 900 }}, .gid = 57, .hb = 1418 },
        // hb-shape --no-glyph-names --features=-kern --variations=wdth=25 subset/data/fonts/RobotoFlex-Variable.ttf --unicodes=U+0041,U+0056
        // [36=0+1087|57=1+1046]
        .{ .path_field = "test_font_roboto_flex", .variations = &.{.{ .tag = "wdth".*, .value = 25 }}, .gid = 36, .hb = 1087 },
        .{ .path_field = "test_font_roboto_flex", .variations = &.{.{ .tag = "wdth".*, .value = 25 }}, .gid = 57, .hb = 1046 },
        // HVAR, and an avar. hb-shape --no-glyph-names --features=-kern --variations=opsz=144,wght=100 subset/data/fonts/Fraunces.ttf --unicodes=U+0041,U+0056,U+0054,U+006F
        // [3=0+1105|24=1+1117|22=2+1088|47=3+914]
        .{ .path_field = "test_font_variable", .variations = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } }, .gid = 3, .hb = 1105 },
        .{ .path_field = "test_font_variable", .variations = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } }, .gid = 24, .hb = 1117 },
        .{ .path_field = "test_font_variable", .variations = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } }, .gid = 22, .hb = 1088 },
        // No HVAR: gvar phantom points. hb-shape --no-glyph-names --variations=wght=900,wdth=70 shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf --unicodes=U+0634
        // [5=0+1242]
        .{ .path_field = "test_font_gpos_four", .variations = &.{ .{ .tag = "wght".*, .value = 900 }, .{ .tag = "wdth".*, .value = 70 } }, .gid = 5, .hb = 1242 },
        // hb-shape --no-glyph-names --variations=wght=100 shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf --unicodes=U+0634
        // [5=0+1164]
        .{ .path_field = "test_font_gpos_four", .variations = &.{.{ .tag = "wght".*, .value = 100 }}, .gid = 5, .hb = 1164 },
    };
    inline for (cases) |case| {
        var font = try loadVariableFontForTest(gpa, reuseFontPath(case.path_field), case.variations);
        defer font.deinit();
        try std.testing.expectEqual(case.hb, font.glyphAdvanceX(case.gid));
        var default_font = try loadVariableFontForTest(gpa, reuseFontPath(case.path_field), &.{});
        defer default_font.deinit();
        try std.testing.expect(default_font.glyphAdvanceX(case.gid) != case.hb);
    }
}

test "glyphAdvanceX of a static font is its hmtx advance, for every glyph" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    inline for (.{ options.test_font_roboto, options.test_font_amiri, options.test_font_noto_devanagari }) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        const face = try sfnt.open(bytes, 0);
        // Any variations: a font with no axes ignores them all.
        var font = try Font.init(gpa, bytes, 0, &.{.{ .tag = "wght".*, .value = 900 }});
        defer font.deinit();
        try std.testing.expectEqual(0, font.normalized.len);
        var gid: u16 = 0;
        while (gid < face.num_glyphs) : (gid += 1) {
            try std.testing.expectEqual(@as(i32, try sfnt.glyphAdvance(face, gid)), font.glyphAdvanceX(gid));
        }
    }
}

test "a variable font with no variations is at its default instance" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    inline for (.{ options.test_font_variable, options.test_font_roboto_flex, options.test_font_gpos_four, options.test_font_avar2 }) |path| {
        var font = try loadVariableFontForTest(gpa, path, &.{});
        defer font.deinit();
        try std.testing.expect(font.normalized.len > 0);
        for (font.normalized) |coord| try std.testing.expectEqual(0, coord);
    }
}

test "axes equal fontTools' fvar reading, hidden flag included" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    // uv run --with fonttools: [(a.axisTag, a.minValue, a.defaultValue, a.maxValue, a.flags & 1)
    //   for a in TTFont("RobotoFlex-Variable.ttf")["fvar"].axes]
    const want = [_]Axis{
        .{ .tag = "wght".*, .minimum = 100, .default = 400, .maximum = 1000, .hidden = false },
        .{ .tag = "wdth".*, .minimum = 25, .default = 100, .maximum = 151, .hidden = false },
        .{ .tag = "opsz".*, .minimum = 8, .default = 14, .maximum = 144, .hidden = false },
        .{ .tag = "GRAD".*, .minimum = -200, .default = 0, .maximum = 150, .hidden = false },
        .{ .tag = "slnt".*, .minimum = -10, .default = 0, .maximum = 0, .hidden = false },
        .{ .tag = "XTRA".*, .minimum = 323, .default = 468, .maximum = 603, .hidden = true },
        .{ .tag = "XOPQ".*, .minimum = 27, .default = 96, .maximum = 175, .hidden = true },
        .{ .tag = "YOPQ".*, .minimum = 25, .default = 79, .maximum = 135, .hidden = true },
        .{ .tag = "YTLC".*, .minimum = 416, .default = 514, .maximum = 570, .hidden = true },
        .{ .tag = "YTUC".*, .minimum = 528, .default = 712, .maximum = 760, .hidden = true },
        .{ .tag = "YTAS".*, .minimum = 649, .default = 750, .maximum = 854, .hidden = true },
        .{ .tag = "YTDE".*, .minimum = -305, .default = -203, .maximum = -98, .hidden = true },
        .{ .tag = "YTFI".*, .minimum = 560, .default = 738, .maximum = 788, .hidden = true },
    };
    var flex = try loadVariableFontForTest(gpa, options.test_font_roboto_flex, &.{});
    defer flex.deinit();
    const got = try flex.axes(gpa);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(Axis, &want, got);

    var static = try loadVariableFontForTest(gpa, options.test_font_roboto, &.{});
    defer static.deinit();
    const none = try static.axes(gpa);
    defer gpa.free(none);
    try std.testing.expectEqual(0, none.len);
}

test "an unknown axis tag is ignored and an out-of-range value is clamped" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    // NotoSans-VF: wght 100..900, wdth 62.5..100, CTGR 0..100.
    const Pair = struct { []const Variation, []const Variation };
    const same = [_]Pair{
        .{ &.{.{ .tag = "XXXX".*, .value = 5 }}, &.{} },
        .{ &.{ .{ .tag = "wght".*, .value = 700 }, .{ .tag = "ital".*, .value = 1 } }, &.{.{ .tag = "wght".*, .value = 700 }} },
        .{ &.{.{ .tag = "wght".*, .value = 5000 }}, &.{.{ .tag = "wght".*, .value = 900 }} },
        .{ &.{.{ .tag = "wght".*, .value = -1 }}, &.{.{ .tag = "wght".*, .value = 100 }} },
        .{ &.{.{ .tag = "wdth".*, .value = 1e30 }}, &.{} },
        // Tags are case-sensitive: "WGHT" is not "wght".
        .{ &.{.{ .tag = "WGHT".*, .value = 900 }}, &.{} },
    };
    inline for (same) |pair| {
        var a = try loadVariableFontForTest(gpa, options.test_font_noto_sans_vf, pair[0]);
        defer a.deinit();
        var b = try loadVariableFontForTest(gpa, options.test_font_noto_sans_vf, pair[1]);
        defer b.deinit();
        try std.testing.expectEqualSlices(i16, b.normalized, a.normalized);
        var ra = try shape(gpa, &a, "abc", .{});
        defer ra.deinit(gpa);
        var rb = try shape(gpa, &b, "abc", .{});
        defer rb.deinit(gpa);
        try expectSameShape(ra, rb);
    }
    // F2Dot14: the clamped extremes are exactly -1 and +1.
    var low = try loadVariableFontForTest(gpa, options.test_font_noto_sans_vf, &.{.{ .tag = "wght".*, .value = -1e9 }});
    defer low.deinit();
    try std.testing.expectEqual(-16384, low.normalized[0]);
    var high = try loadVariableFontForTest(gpa, options.test_font_noto_sans_vf, &.{.{ .tag = "wght".*, .value = 1e9 }});
    defer high.deinit();
    try std.testing.expectEqual(16384, high.normalized[0]);
}

test "Font.init refuses NaN, infinite and duplicate variations" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const path = options.test_font_noto_sans_vf;
    try std.testing.expectError(error.InvalidNumber, loadVariableFontForTest(gpa, path, &.{.{ .tag = "wght".*, .value = std.math.nan(f32) }}));
    try std.testing.expectError(error.InvalidNumber, loadVariableFontForTest(gpa, path, &.{.{ .tag = "wght".*, .value = std.math.inf(f32) }}));
    // Also for a tag the font has no axis for, and for a static font: the
    // input is wrong whatever the font.
    try std.testing.expectError(error.InvalidNumber, loadVariableFontForTest(gpa, options.test_font_roboto, &.{.{ .tag = "XXXX".*, .value = -std.math.inf(f32) }}));
    try std.testing.expectError(error.DuplicateVariationTag, loadVariableFontForTest(gpa, path, &.{ .{ .tag = "wght".*, .value = 300 }, .{ .tag = "wdth".*, .value = 80 }, .{ .tag = "wght".*, .value = 700 } }));
    try std.testing.expectError(error.DuplicateVariationTag, loadVariableFontForTest(gpa, options.test_font_roboto, &.{ .{ .tag = "XXXX".*, .value = 1 }, .{ .tag = "XXXX".*, .value = 1 } }));
}

test "avar version 2: variations are refused, no variations loads and shapes" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const path = options.test_font_avar2;
    try std.testing.expectError(error.UnsupportedAvarVersion, loadVariableFontForTest(gpa, path, &.{.{ .tag = "wght".*, .value = 700 }}));
    // The rule is about the variations argument, not about which axes it names.
    try std.testing.expectError(error.UnsupportedAvarVersion, loadVariableFontForTest(gpa, path, &.{.{ .tag = "XXXX".*, .value = 1 }}));
    var font = try loadVariableFontForTest(gpa, path, &.{});
    defer font.deinit();
    var got = try shape(gpa, &font, "A", .{});
    defer got.deinit(gpa);
    // hb-shape --no-glyph-names api/fonts/TestAvar2Instance.ttf --unicodes=U+0041
    // [1=0+600]
    try expectSameAsHarfBuzz(got.glyphs, &.{.{ 1, 600, 0, 0 }});
    // An avar 1 font with variations loads (Fraunces has avar 1).
    var fraunces = try loadVariableFontForTest(gpa, options.test_font_variable, &.{.{ .tag = "wght".*, .value = 700 }});
    fraunces.deinit();
}

test "parseVariations reads hb-shape's tag=value list" {
    const gpa = std.testing.allocator;
    const got = try parseVariations(gpa, "wght=700,wdth=62.5,ab=-1");
    defer gpa.free(got);
    try std.testing.expectEqual(3, got.len);
    try std.testing.expectEqualStrings("wght", &got[0].tag);
    try std.testing.expectEqual(700, got[0].value);
    try std.testing.expectEqualStrings("wdth", &got[1].tag);
    try std.testing.expectEqual(62.5, got[1].value);
    try std.testing.expectEqualStrings("ab  ", &got[2].tag);
    try std.testing.expectEqual(-1, got[2].value);
    for ([_][]const u8{ "", "wght", "wght=", "=700", "wghtx=1", "wght=1,", "wg ht=1", "wght=1;wdth=2", "wght=abc" }) |bad| {
        try std.testing.expectError(error.InvalidVariation, parseVariations(gpa, bad));
    }
}

test "checkAllAllocationFailures: variable font at an instance, load plus shape" {
    const options = @import("build_options");
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator, path: []const u8) !void {
            var font = try loadVariableFontForTest(allocator, path, &.{ .{ .tag = "wght".*, .value = 900 }, .{ .tag = "wdth".*, .value = 80 } });
            defer font.deinit();
            var r = try shape(allocator, &font, "abc", .{});
            r.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{options.test_font_noto_sans_vf});
}

test "shape at an instance recovers from every kb allocation failure on the first shape" {
    // The context gets the instance's vector right after the push; a failed
    // shape drops the context, and the next one must push and set it again.
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const variations: []const Variation = &.{ .{ .tag = "opsz".*, .value = 144 }, .{ .tag = "wght".*, .value = 100 } };
    const want = hb_cases[3];
    comptime std.debug.assert(std.mem.eql(u8, want.text, "fluffy office"));
    var n_failed: usize = 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        var font = try loadVariableFontForTest(gpa, options.test_font_variable, variations);
        defer font.deinit();
        var failing = std.testing.FailingAllocator.init(font.kb.context_arena.allocator(), .{ .fail_index = i });
        font.kb.context_allocator = failing.allocator();
        if (shape(gpa, &font, want.text, .{})) |result| {
            var r = result;
            defer r.deinit(gpa);
            try std.testing.expect(!failing.has_induced_failure);
            try expectSameAsHarfBuzz(r.glyphs, want.hb);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            n_failed += 1;
        }
        failing.fail_index = std.math.maxInt(usize);
        var again = try shape(gpa, &font, want.text, .{});
        defer again.deinit(gpa);
        try expectSameAsHarfBuzz(again.glyphs, want.hb);
    }
    try std.testing.expect(n_failed > 0);
}

test "Pen: each glyph at the pen plus its offset, then the pen moves by the advance" {
    const g = struct {
        fn glyph(advance_x: i32, advance_y: i32, offset_x: i32, offset_y: i32) Glyph {
            return .{ .id = 1, ._reserved0 = 0, .cluster = 0, .advance_x = advance_x, .advance_y = advance_y, .offset_x = offset_x, .offset_y = offset_y };
        }
    };
    var pen: Pen = .{};
    // A base, a mark placed back over it, then a vertical step.
    try std.testing.expectEqual(Pen.Origin{ .x = 0, .y = 0 }, pen.place(g.glyph(500, 0, 0, 0)));
    try std.testing.expectEqual(Pen.Origin{ .x = 300, .y = 40 }, pen.place(g.glyph(0, 0, -200, 40)));
    try std.testing.expectEqual(Pen.Origin{ .x = 510, .y = -5 }, pen.place(g.glyph(10, 70, 10, -5)));
    try std.testing.expectEqual(Pen.Origin{ .x = 510, .y = 70 }, pen.place(g.glyph(0, 0, 0, 0)));
    // Sums are i64: a line of maximal advances does not overflow.
    var long: Pen = .{};
    for (0..4) |_| _ = long.place(g.glyph(std.math.maxInt(i32), 0, 0, 0));
    try std.testing.expectEqual(@as(i64, 4) * std.math.maxInt(i32), long.place(g.glyph(0, 0, 0, 0)).x);
}

test "shape's result names its font and owns a copy of the text" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    var font = try loadVariableFontForTest(gpa, options.test_font_roboto, &.{});
    defer font.deinit();
    var result = try shape(gpa, &font, "office", .{});
    defer result.deinit(gpa);
    try std.testing.expectEqual(font.id, result.font_id);
    try std.testing.expectEqualStrings("office", result.text);
}

test "line order: how many of tests/bidi/cases.tsv match UAX #9 (kb's model, pinned)" {
    // zpdf orders a line's runs as kb's own reference editor, refpad, does
    // (see visualOrder), so lines where kb's run directions differ from UAX #9
    // (neutrals and digits next to a direction change) differ here too. This
    // pins how many of the oracle's lines match, measured when the run order
    // was added: a change in either direction fails until someone looks.
    // tools/bidi-oracle.py writes the file (python-bidi 0.4.2's UAX #9).
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const tsv = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.bidi_cases, gpa, .unlimited);
    defer gpa.free(tsv);
    var font = try loadVariableFontForTest(gpa, options.test_font_noto_hebrew, &.{});
    defer font.deinit();

    var lines: usize = 0;
    var matching: usize = 0;
    var rows = std.mem.splitScalar(u8, tsv, '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        var cols = std.mem.splitScalar(u8, row, '\t');
        const dir_text = cols.next().?;
        const order_text = cols.next().?;
        const text = cols.rest();
        const direction: Direction = if (std.mem.eql(u8, dir_text, "ltr")) .ltr else if (std.mem.eql(u8, dir_text, "rtl")) .rtl else .dont_know;
        var result = try shape(gpa, &font, text, .{ .paragraph_direction = direction });
        defer result.deinit(gpa);
        // The cases are built so the font gives one glyph per codepoint.
        try std.testing.expectEqual(try std.unicode.utf8CountCodepoints(text), result.glyphs.len);
        lines += 1;
        var want = std.mem.splitScalar(u8, order_text, ',');
        const same = for (result.glyphs) |g| {
            const index = try std.fmt.parseInt(u32, want.next().?, 10);
            if (g.cluster != index) break false;
        } else true;
        if (same) matching += 1;
    }
    try std.testing.expectEqual(@as(usize, 1422), lines);
    if (matching != 984) {
        std.debug.print("line order: {d} of {d} lines match UAX #9, pinned at 984; if the change is meant, say why in the commit and update the number\n", .{ matching, lines });
        return error.TestUnexpectedResult;
    }
}
