//! Full instances of TrueType variable fonts: gvar applied to the glyf outlines
//! of the glyphs a subset embeds, at the normalized coordinates kb gave the
//! font (zpdf.Font.normalized). kb owns metrics and normalization; this file
//! owns outlines.
//!
//! The arithmetic is fontTools' instancer (varLib.instancer, fontTools 4.67.0),
//! so `tools/instance-points.py` is an exact oracle:
//! - A tuple's scalar for one axis is computed in f64 from the F2Dot14
//!   integers, and a delta is multiplied by the axis scalars one at a time, in
//!   axis-tag order (changeTupleVariationsAxisLimits walks the axes sorted by
//!   tag and scales the deltas once per axis).
//! - Untouched points are inferred per tuple, after scaling, with fontTools'
//!   iup_contour and iup_segment, from the default (unvaried) coordinates.
//! - Each point's deltas are summed in tuple order and added to the default
//!   coordinate; the sum is rounded once, half up (otRound = floor(x + 0.5)).
//! - A component offset stays unrounded where fontTools keeps it unrounded:
//!   composite bounds are computed from it, and only the written offset is
//!   rounded.
//! - The advance is otRound(right phantom - left phantom), not below 0; the
//!   left side bearing is otRound(xMin - left phantom). A composite uses its
//!   own phantom points (fontTools does not follow USE_MY_METRICS; HarfBuzz and
//!   kb do).
//!
//! One place differs from fontTools on purpose, and only for a broken font:
//! an intermediate region whose peak is outside it, or that crosses 0, leaves
//! its axis out of the scalar (scalar 1), as the OpenType spec and HarfBuzz
//! say; fontTools drops the whole tuple.
//!
//! Fonts are untrusted input. Every read is bounded by the table, glyph or
//! tuple it belongs to, and anything that is not a well-formed gvar or glyf
//! entry (point numbers out of range or out of order, deltas past their
//! tuple, a coordinate that leaves the 16-bit range) fails the font with
//! error.InvalidFont instead of drawing a different outline. Work is bounded
//! by `work_per_byte` per byte of glyf and gvar.

const std = @import("std");
const sfnt = @import("sfnt.zig");
const ManagedList = std.array_list.Managed;

/// Point operations allowed per byte of glyf + gvar, plus `work_base`. One
/// byte of packed deltas can stand for 64 zero deltas, and a tuple of a few
/// bytes can make every point of its glyph inferred, so the bound is per byte
/// and not per point.
const work_per_byte: u64 = 64;
const work_base: u64 = 1 << 24;

pub const Point = struct { x: f64, y: f64 };

/// fontTools' otRound: round half up.
fn otRound(v: f64) f64 {
    return @floor(v + 0.5);
}

fn toI16(v: f64) !i16 {
    if (!(v >= -32768 and v <= 32767)) return error.InvalidFont;
    return @intFromFloat(v);
}

/// Big-endian reads over one slice; reading past it is error.InvalidFont.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) ![]const u8 {
        if (n > r.bytes.len - r.pos) return error.InvalidFont;
        const s = r.bytes[r.pos..][0..n];
        r.pos += n;
        return s;
    }

    fn u8_(r: *Reader) !u8 {
        return (try r.take(1))[0];
    }

    fn i8_(r: *Reader) !i8 {
        return @bitCast(try r.u8_());
    }

    fn u16_(r: *Reader) !u16 {
        return std.mem.readInt(u16, (try r.take(2))[0..2], .big);
    }

    fn i16_(r: *Reader) !i16 {
        return std.mem.readInt(i16, (try r.take(2))[0..2], .big);
    }

    fn u32_(r: *Reader) !u32 {
        return std.mem.readInt(u32, (try r.take(4))[0..4], .big);
    }

    fn i32_(r: *Reader) !i32 {
        return std.mem.readInt(i32, (try r.take(4))[0..4], .big);
    }
};

fn sliceAt(bytes: []const u8, offset: usize, len: usize) ![]const u8 {
    if (offset > bytes.len or len > bytes.len - offset) return error.InvalidFont;
    return bytes[offset..][0..len];
}

/// The gvar header: glyphVariationData of glyph `gid` is `glyphData(gid)`.
const Gvar = struct {
    axis_count: usize,
    shared_tuples: []const u8,
    shared_count: usize,
    offsets: []const u8,
    long_offsets: bool,
    data: []const u8,

    /// `axis_count` is fvar's and `num_glyphs` maxp's; gvar must agree with both.
    fn init(table: []const u8, axis_count: usize, num_glyphs: u16) !Gvar {
        var r: Reader = .{ .bytes = table };
        if (try r.u16_() != 1) return error.InvalidFont;
        _ = try r.u16_();
        if (try r.u16_() != axis_count) return error.InvalidFont;
        const shared_count = try r.u16_();
        const shared_offset = try r.u32_();
        if (try r.u16_() != num_glyphs) return error.InvalidFont;
        const long_offsets = (try r.u16_()) & 1 != 0;
        const data_offset = try r.u32_();
        const entry: usize = if (long_offsets) 4 else 2;
        return .{
            .axis_count = axis_count,
            .shared_tuples = try sliceAt(table, shared_offset, shared_count * axis_count * 2),
            .shared_count = shared_count,
            .offsets = try sliceAt(table, 20, (@as(usize, num_glyphs) + 1) * entry),
            .long_offsets = long_offsets,
            .data = try sliceAt(table, data_offset, table.len -| data_offset),
        };
    }

    fn glyphData(self: *const Gvar, gid: u16) ![]const u8 {
        const start, const end = if (self.long_offsets) .{
            std.mem.readInt(u32, self.offsets[@as(usize, gid) * 4 ..][0..4], .big),
            std.mem.readInt(u32, self.offsets[(@as(usize, gid) + 1) * 4 ..][0..4], .big),
        } else .{
            @as(u32, std.mem.readInt(u16, self.offsets[@as(usize, gid) * 2 ..][0..2], .big)) * 2,
            @as(u32, std.mem.readInt(u16, self.offsets[(@as(usize, gid) + 1) * 2 ..][0..2], .big)) * 2,
        };
        if (end < start) return error.InvalidFont;
        return sliceAt(self.data, start, end - start);
    }
};

/// The instance: kb's normalized coordinates (fvar order) and the fvar axis
/// indices sorted by tag, the order fontTools scales deltas in.
const Instance = struct {
    coords: []const i16,
    tag_order: []const usize,
};

/// Reads fvar's axis tags and returns the axis indices sorted by tag; axes
/// with one tag stay in fvar order. fontTools keys axes by tag, so it has no
/// order for such axes (HarfBuzz's tests have a font with three axes tagged
/// "0001"); the spec, HarfBuzz and kb treat axes by index, and only the order
/// of the scalar multiplications depends on this.
fn axisTagOrder(arena: std.mem.Allocator, fvar: []const u8, axis_count: usize) ![]const usize {
    var r: Reader = .{ .bytes = fvar };
    _ = try r.u32_();
    const axes_offset = try r.u16_();
    _ = try r.u16_();
    if (try r.u16_() != axis_count) return error.InvalidFont;
    const axis_size = try r.u16_();
    if (axis_size < 20) return error.InvalidFont;
    const tags = try arena.alloc([4]u8, axis_count);
    for (tags, 0..) |*tag, i| {
        tag.* = (try sliceAt(fvar, @as(usize, axes_offset) + i * axis_size, 20))[0..4].*;
    }
    const order = try arena.alloc(usize, axis_count);
    for (order, 0..) |*o, i| o.* = i;
    const Ctx = struct {
        tags: []const [4]u8,
        fn less(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, &ctx.tags[a], &ctx.tags[b]);
        }
    };
    std.mem.sort(usize, order, Ctx{ .tags = tags }, Ctx.less);
    return order;
}

/// The scalar of one axis of a tuple at coordinate `v` (OpenType "Algorithm
/// for interpolation of instance values"; fontTools' supportScalar). All
/// values are F2Dot14 integers; the ratios are exact f64 quotients, so they
/// equal fontTools' quotients of the same values divided by 16384.
fn axisScalar(v: i32, peak: i32, region: ?[2]i32) f64 {
    if (peak == 0 or v == peak) return 1;
    if (region) |se| {
        const start = se[0];
        const end = se[1];
        if (start > peak or peak > end or (start < 0 and end > 0)) return 1;
        if (v <= start or v >= end) return 0;
        if (v < peak) return @as(f64, @floatFromInt(v - start)) / @as(f64, @floatFromInt(peak - start));
        return @as(f64, @floatFromInt(end - v)) / @as(f64, @floatFromInt(end - peak));
    }
    if (v == 0 or v < @min(0, peak) or v > @max(0, peak)) return 0;
    return @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(peak));
}

/// Packed point numbers. Returns null for "all points". Point numbers must
/// increase and be below `point_count`.
fn readPoints(arena: std.mem.Allocator, r: *Reader, point_count: usize, work: *u64) !?[]const u32 {
    const first = try r.u8_();
    const count: usize = if (first & 0x80 != 0) (@as(usize, first & 0x7F) << 8) | try r.u8_() else first;
    if (count == 0) return null;
    if (count > point_count) return error.InvalidFont;
    try spend(work, count);
    const points = try arena.alloc(u32, count);
    var i: usize = 0;
    var prev: u32 = 0;
    while (i < count) {
        const control = try r.u8_();
        const run = @as(usize, control & 0x7F) + 1;
        if (run > count - i) return error.InvalidFont;
        for (0..run) |_| {
            const step: u32 = if (control & 0x80 != 0) try r.u16_() else try r.u8_();
            if (i != 0 and step == 0) return error.InvalidFont;
            const p = prev + step;
            if (p >= point_count) return error.InvalidFont;
            points[i] = p;
            prev = p;
            i += 1;
        }
    }
    return points;
}

/// Packed deltas, exactly `out.len` of them.
fn readDeltas(r: *Reader, out: []i32) !void {
    var i: usize = 0;
    while (i < out.len) {
        const control = try r.u8_();
        const run = @as(usize, control & 0x3F) + 1;
        if (run > out.len - i) return error.InvalidFont;
        for (out[i..][0..run]) |*d| {
            d.* = switch (control & 0xC0) {
                0x00 => try r.i8_(),
                0x40 => try r.i16_(),
                0x80 => 0,
                else => try r.i32_(),
            };
        }
        i += run;
    }
}

fn spend(work: *u64, cost: usize) !void {
    if (cost > work.*) return error.InvalidFont;
    work.* -= cost;
}

/// Adds glyph `gid`'s deltas at the instance to `total` (one entry per point
/// of `orig`, phantom points included). `ends` are the contour end points of
/// a simple glyph, whose untouched points are inferred; a composite glyph
/// passes null, and an untouched component offset or phantom point gets no
/// delta.
fn addGlyphDeltas(
    arena: std.mem.Allocator,
    gvar: *const Gvar,
    gid: u16,
    inst: Instance,
    orig: []const Point,
    ends: ?[]const u16,
    total: []Point,
    work: *u64,
) !void {
    const data = try gvar.glyphData(gid);
    if (data.len == 0) return;
    var hr: Reader = .{ .bytes = data };
    const count_field = try hr.u16_();
    const data_offset = try hr.u16_();
    // The tuple headers lie between the 4-byte header and the serialized data.
    if (data_offset < 4 or data_offset > data.len) return error.InvalidFont;
    hr.bytes = data[0..data_offset];
    var sr: Reader = .{ .bytes = data[data_offset..] };
    const n = orig.len;

    var shared: ?[]const u32 = null;
    if (count_field & 0x8000 != 0) shared = try readPoints(arena, &sr, n, work);

    const axis_count = gvar.axis_count;
    const scalars = try arena.alloc(f64, axis_count);
    const xs = try arena.alloc(i32, n);
    const ys = try arena.alloc(i32, n);
    const tuple = try arena.alloc(Point, n);
    const touched = try arena.alloc(bool, n);

    for (0..count_field & 0x0FFF) |_| {
        const size = try hr.u16_();
        const index = try hr.u16_();
        const peak = if (index & 0x8000 != 0)
            try hr.take(axis_count * 2)
        else blk: {
            const shared_index = index & 0x0FFF;
            if (shared_index >= gvar.shared_count) return error.InvalidFont;
            break :blk gvar.shared_tuples[shared_index * axis_count * 2 ..][0 .. axis_count * 2];
        };
        var start: ?[]const u8 = null;
        var end: ?[]const u8 = null;
        if (index & 0x4000 != 0) {
            start = try hr.take(axis_count * 2);
            end = try hr.take(axis_count * 2);
        }
        var tr: Reader = .{ .bytes = try sr.take(size) };
        const points = if (index & 0x2000 != 0) try readPoints(arena, &tr, n, work) else shared;
        const m = if (points) |p| p.len else n;
        try spend(work, 2 * m);
        try readDeltas(&tr, xs[0..m]);
        try readDeltas(&tr, ys[0..m]);

        // Scalars in tag order; a zero scalar drops the tuple.
        var zero = false;
        var n_scalars: usize = 0;
        for (inst.tag_order) |axis| {
            const p = std.mem.readInt(i16, peak[axis * 2 ..][0..2], .big);
            const region: ?[2]i32 = if (start) |s| .{
                std.mem.readInt(i16, s[axis * 2 ..][0..2], .big),
                std.mem.readInt(i16, end.?[axis * 2 ..][0..2], .big),
            } else null;
            const s = axisScalar(inst.coords[axis], p, region);
            if (s == 0) {
                zero = true;
                break;
            }
            if (s != 1) {
                scalars[n_scalars] = s;
                n_scalars += 1;
            }
        }
        if (zero) continue;

        if (points) |list| {
            try spend(work, n);
            @memset(touched, false);
            for (list, 0..) |p, i| {
                tuple[p] = .{ .x = scaled(xs[i], scalars[0..n_scalars]), .y = scaled(ys[i], scalars[0..n_scalars]) };
                touched[p] = true;
            }
            var contour_start: usize = 0;
            if (ends) |e| {
                for (e) |last| {
                    iupContour(orig[contour_start .. @as(usize, last) + 1], tuple[contour_start .. @as(usize, last) + 1], touched[contour_start .. @as(usize, last) + 1]);
                    contour_start = @as(usize, last) + 1;
                }
            }
            for (contour_start..n) |i| {
                if (!touched[i]) tuple[i] = .{ .x = 0, .y = 0 };
            }
        } else {
            for (tuple, 0..) |*t, i| t.* = .{ .x = scaled(xs[i], scalars[0..n_scalars]), .y = scaled(ys[i], scalars[0..n_scalars]) };
        }
        for (total, tuple) |*t, d| {
            t.x += d.x;
            t.y += d.y;
        }
    }
}

fn scaled(raw: i32, scalars: []const f64) f64 {
    var d: f64 = @floatFromInt(raw);
    for (scalars) |s| d *= s;
    return d;
}

/// fontTools' iup_contour: fills the untouched entries of `deltas` from the
/// touched ones around them.
fn iupContour(coords: []const Point, deltas: []Point, touched: []const bool) void {
    const n = coords.len;
    var first: ?usize = null;
    var last: usize = 0;
    var all = true;
    for (touched, 0..) |t, i| {
        if (t) {
            if (first == null) first = i;
            last = i;
        } else all = false;
    }
    if (all) return;
    const f = first orelse {
        for (deltas) |*d| d.* = .{ .x = 0, .y = 0 };
        return;
    };
    if (f != 0) iupSegment(coords, deltas, 0, f, f, last);
    var prev = f;
    for (f + 1..n) |i| {
        if (!touched[i]) continue;
        if (i - prev > 1) iupSegment(coords, deltas, prev + 1, i, prev, i);
        prev = i;
    }
    if (prev != n - 1) iupSegment(coords, deltas, prev + 1, n, prev, f);
}

/// fontTools' iup_segment over points [from, to) with reference points r1, r2.
fn iupSegment(coords: []const Point, deltas: []Point, from: usize, to: usize, r1: usize, r2: usize) void {
    inline for (.{ "x", "y" }) |axis| {
        var x1 = @field(coords[r1], axis);
        var x2 = @field(coords[r2], axis);
        var d1 = @field(deltas[r1], axis);
        var d2 = @field(deltas[r2], axis);
        if (x1 == x2) {
            const d: f64 = if (d1 == d2) d1 else 0;
            for (deltas[from..to]) |*p| @field(p, axis) = d;
        } else {
            if (x1 > x2) {
                std.mem.swap(f64, &x1, &x2);
                std.mem.swap(f64, &d1, &d2);
            }
            const scale = (d2 - d1) / (x2 - x1);
            for (coords[from..to], deltas[from..to]) |c, *p| {
                const x = @field(c, axis);
                @field(p, axis) = if (x <= x1) d1 else if (x >= x2) d2 else d1 + (x - x1) * scale;
            }
        }
    }
}

const flag_on_curve: u8 = 0x01;
const flag_x_short: u8 = 0x02;
const flag_y_short: u8 = 0x04;
const flag_repeat: u8 = 0x08;
const flag_cubic: u8 = 0x80;
const flag_x_same: u8 = 0x10;
const flag_y_same: u8 = 0x20;
/// The point flags an instanced glyph keeps: on-curve, OVERLAP_SIMPLE, and
/// bit 7 (cubic in newer glyf), as fontTools does.
const kept_point_flags: u8 = 0xC1;

const arg_words: u16 = 0x0001;
const args_are_xy: u16 = 0x0002;
const has_scale: u16 = 0x0008;
const more_components: u16 = 0x0020;
const has_xy_scale: u16 = 0x0040;
const has_two_by_two: u16 = 0x0080;
const has_instructions: u16 = 0x0100;
const scaled_offset: u16 = 0x0800;
const unscaled_offset: u16 = 0x1000;
const any_scale = has_scale | has_xy_scale | has_two_by_two;

pub const Component = struct {
    flags: u16,
    gid: u16,
    /// The offset (ARGS_ARE_XY_VALUES) or the parent and child point numbers.
    arg1: i32,
    arg2: i32,
    /// The scale as stored, F2Dot14: 1, 2 or 4 values.
    scale: [4]i16 = .{ 0, 0, 0, 0 },
    scale_len: u8 = 0,
    /// The instanced offset, unrounded.
    dx: f64 = 0,
    dy: f64 = 0,

    fn hasScale(self: Component) bool {
        return self.flags & any_scale != 0;
    }

    /// fontTools' 2x2 transform [[xx, xy], [yx, yy]].
    fn transform(self: Component) [4]f64 {
        const f = struct {
            fn f(v: i16) f64 {
                return @as(f64, @floatFromInt(v)) / 16384.0;
            }
        }.f;
        return switch (self.scale_len) {
            1 => .{ f(self.scale[0]), 0, 0, f(self.scale[0]) },
            2 => .{ f(self.scale[0]), 0, 0, f(self.scale[1]) },
            else => .{ f(self.scale[0]), f(self.scale[1]), f(self.scale[2]), f(self.scale[3]) },
        };
    }
};

pub const Glyph = struct {
    kind: enum { empty, simple, composite },
    /// The glyph header's xMin (0 without one), for the default left phantom.
    header_x_min: i16 = 0,
    /// Simple: the points (instanced, unrounded, once instanced), the flags
    /// masked to kept_point_flags, and the contour ends.
    points: []Point = &.{},
    flags: []u8 = &.{},
    ends: []u16 = &.{},
    components: []Component = &.{},
};

/// Decodes one glyf entry. Only the outline is kept; instructions are dropped.
pub fn decodeGlyph(arena: std.mem.Allocator, data: []const u8) !Glyph {
    if (data.len == 0) return .{ .kind = .empty };
    var r: Reader = .{ .bytes = data };
    const contours = try r.i16_();
    const x_min = try r.i16_();
    _ = try r.take(6);
    if (contours == 0) return .{ .kind = .empty, .header_x_min = x_min };
    if (contours > 0) {
        const ends = try arena.alloc(u16, @intCast(contours));
        for (ends, 0..) |*e, i| {
            e.* = try r.u16_();
            if (i != 0 and e.* <= ends[i - 1]) return error.InvalidFont;
        }
        const n = @as(usize, ends[ends.len - 1]) + 1;
        _ = try r.take(try r.u16_());
        const flags = try arena.alloc(u8, n);
        var i: usize = 0;
        while (i < n) {
            const f = try r.u8_();
            flags[i] = f;
            i += 1;
            if (f & flag_repeat != 0) {
                const repeat = try r.u8_();
                if (repeat > n - i) return error.InvalidFont;
                @memset(flags[i..][0..repeat], f);
                i += repeat;
            }
        }
        const points = try arena.alloc(Point, n);
        var x: i64 = 0;
        for (points, flags) |*p, f| {
            if (f & flag_x_short != 0) {
                const d: i64 = try r.u8_();
                x += if (f & flag_x_same != 0) d else -d;
            } else if (f & flag_x_same == 0) {
                x += try r.i16_();
            }
            p.x = @floatFromInt(x);
        }
        var y: i64 = 0;
        for (points, flags) |*p, f| {
            if (f & flag_y_short != 0) {
                const d: i64 = try r.u8_();
                y += if (f & flag_y_same != 0) d else -d;
            } else if (f & flag_y_same == 0) {
                y += try r.i16_();
            }
            p.y = @floatFromInt(y);
        }
        for (flags) |*f| f.* &= kept_point_flags;
        return .{ .kind = .simple, .header_x_min = x_min, .points = points, .flags = flags, .ends = ends };
    }
    var list = ManagedList(Component).init(arena);
    while (true) {
        const flags = try r.u16_();
        const gid = try r.u16_();
        var c: Component = .{ .flags = flags, .gid = gid, .arg1 = 0, .arg2 = 0 };
        if (flags & arg_words != 0) {
            if (flags & args_are_xy != 0) {
                c.arg1 = try r.i16_();
                c.arg2 = try r.i16_();
            } else {
                c.arg1 = try r.u16_();
                c.arg2 = try r.u16_();
            }
        } else if (flags & args_are_xy != 0) {
            c.arg1 = try r.i8_();
            c.arg2 = try r.i8_();
        } else {
            c.arg1 = try r.u8_();
            c.arg2 = try r.u8_();
        }
        c.scale_len = if (flags & has_scale != 0) 1 else if (flags & has_xy_scale != 0) 2 else if (flags & has_two_by_two != 0) 4 else 0;
        for (c.scale[0..c.scale_len]) |*s| s.* = try r.i16_();
        c.dx = @floatFromInt(c.arg1);
        c.dy = @floatFromInt(c.arg2);
        if (flags & scaled_offset != 0 and flags & unscaled_offset != 0) return error.InvalidFont;
        try list.append(c);
        if (flags & more_components == 0) break;
    }
    return .{ .kind = .composite, .header_x_min = x_min, .components = try list.toOwnedSlice() };
}

/// One embedded glyph at the instance.
const Instanced = struct {
    glyph: Glyph,
    left: f64,
    right: f64,
    bbox: ?[4]i32 = null,
};

/// Instances glyph `gid`: the glyph's points, its component offsets and its
/// phantom points get the instance's deltas.
fn instanceGlyph(arena: std.mem.Allocator, face: sfnt.Face, gvar: ?*const Gvar, inst: Instance, gid: u16, work: *u64) !Instanced {
    const g = try decodeGlyph(arena, try sfnt.glyphData(face, gid));
    const left: f64 = @floatFromInt(@as(i32, g.header_x_min) - try sfnt.glyphLsb(face, gid));
    const right = left + @as(f64, @floatFromInt(try sfnt.glyphAdvance(face, gid)));
    const own: usize = switch (g.kind) {
        .empty => 0,
        .simple => g.points.len,
        .composite => g.components.len,
    };
    const orig = try arena.alloc(Point, own + 4);
    switch (g.kind) {
        .empty => {},
        .simple => @memcpy(orig[0..own], g.points),
        .composite => for (g.components, 0..) |c, i| {
            // fontTools reads a point-matched component as the point (0, 0) and
            // ignores its deltas.
            orig[i] = if (c.flags & args_are_xy != 0) .{ .x = c.dx, .y = c.dy } else .{ .x = 0, .y = 0 };
        },
    }
    orig[own] = .{ .x = left, .y = 0 };
    orig[own + 1] = .{ .x = right, .y = 0 };
    orig[own + 2] = .{ .x = 0, .y = 0 };
    orig[own + 3] = .{ .x = 0, .y = 0 };
    const total = try arena.alloc(Point, own + 4);
    @memset(total, .{ .x = 0, .y = 0 });
    if (gvar) |gv| {
        try spend(work, own + 4);
        try addGlyphDeltas(arena, gv, gid, inst, orig, if (g.kind == .simple) g.ends else null, total, work);
    }
    switch (g.kind) {
        .empty => {},
        .simple => for (g.points, orig[0..own], total[0..own]) |*p, o, t| {
            p.* = .{ .x = o.x + t.x, .y = o.y + t.y };
        },
        .composite => for (g.components, total[0..own]) |*c, t| {
            if (c.flags & args_are_xy != 0) {
                c.dx += t.x;
                c.dy += t.y;
            }
        },
    }
    return .{ .glyph = g, .left = left + total[own].x, .right = right + total[own + 1].x };
}

const Glyphs = struct {
    arena: std.mem.Allocator,
    items: []?Instanced,
    work: *u64,

    fn glyphAt(gs: *Glyphs, gid: u16) !*const Glyph {
        return if (gs.items[gid]) |*ig| &ig.glyph else error.InvalidFont;
    }
};

/// fontTools' recalcBounds for glyph `gid`.
fn bounds(gs: *Glyphs, gid: u16) ![4]i32 {
    const ig: *Instanced = if (gs.items[gid]) |*p| p else return error.InvalidFont;
    if (ig.bbox) |b| return b;
    const b: [4]i32 = switch (ig.glyph.kind) {
        .empty => .{ 0, 0, 0, 0 },
        .simple => blk: {
            var b: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
            for (ig.glyph.points) |p| extend(&b, otRound(p.x), otRound(p.y));
            break :blk try intBounds(b);
        },
        .composite => blk: {
            const fast = for (ig.glyph.components) |c| {
                if (c.flags & args_are_xy == 0 or c.hasScale() or @floor(c.dx) != c.dx or @floor(c.dy) != c.dy) break false;
            } else true;
            if (fast) {
                // Untransformed components at integer offsets: the union of
                // their bounds; a component with no area adds nothing.
                var b: ?[4]i32 = null;
                for (ig.glyph.components) |c| {
                    const cb = try bounds(gs, c.gid);
                    if (cb[0] == cb[2] and cb[1] == cb[3]) continue;
                    const dx: i32 = try toI16(c.dx);
                    const dy: i32 = try toI16(c.dy);
                    const moved = try intBounds(.{
                        @floatFromInt(cb[0] + dx), @floatFromInt(cb[1] + dy),
                        @floatFromInt(cb[2] + dx), @floatFromInt(cb[3] + dy),
                    });
                    b = if (b) |u| .{ @min(u[0], moved[0]), @min(u[1], moved[1]), @max(u[2], moved[2]), @max(u[3], moved[3]) } else moved;
                }
                break :blk b orelse .{ 0, 0, 0, 0 };
            }
            var flat: Flat = .init(gs.arena, false);
            try flatten(gs, gid, &flat, gs.work);
            if (flat.points.items.len == 0) break :blk .{ 0, 0, 0, 0 };
            var b: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
            for (flat.points.items) |p| extend(&b, p.x, p.y);
            break :blk try intBounds(.{ otRound(b[0]), otRound(b[1]), otRound(b[2]), otRound(b[3]) });
        },
    };
    ig.bbox = b;
    return b;
}

fn extend(b: *[4]f64, x: f64, y: f64) void {
    b[0] = @min(b[0], x);
    b[1] = @min(b[1], y);
    b[2] = @max(b[2], x);
    b[3] = @max(b[3], y);
}

fn intBounds(b: [4]f64) ![4]i32 {
    return .{ try toI16(b[0]), try toI16(b[1]), try toI16(b[2]), try toI16(b[3]) };
}

/// A glyph flattened: its points, every component's placed, and when
/// `contours` is set the kept point flags and the contour ends (indices into
/// `points`; u32, because a flattened composite can pass 65535 points).
const Flat = struct {
    points: ManagedList(Point),
    flags: ManagedList(u8),
    ends: ManagedList(u32),
    contours: bool,

    fn init(arena: std.mem.Allocator, contours: bool) Flat {
        return .{ .points = .init(arena), .flags = .init(arena), .ends = .init(arena), .contours = contours };
    }
};

/// fontTools' getCoordinates(round=otRound) of glyph `gid`: every
/// component's points, placed. A simple component's points are rounded
/// before they are transformed; a nested composite's are not rounded at all.
/// `src` gives each glyph (`glyphAt(gid) !*const Glyph`): the instanced
/// glyphs for bounds, the rounded ones for Outlines. A component tree can
/// repeat a glyph many times, so every placed point and every component
/// visited spends `work` (a tree of empty glyphs places no point, and would
/// otherwise expand with no bound). The caller has checked the tree for
/// cycles and depth (sfnt.collectUsed).
fn flatten(src: anytype, gid: u16, out: *Flat, work: *u64) !void {
    const g = try src.glyphAt(gid);
    switch (g.kind) {
        .empty => {},
        .simple => {
            try spend(work, g.points.len);
            const base: u32 = @intCast(out.points.items.len);
            for (g.points) |p| try out.points.append(.{ .x = otRound(p.x), .y = otRound(p.y) });
            if (out.contours) {
                try out.flags.appendSlice(g.flags);
                for (g.ends) |e| try out.ends.append(base + e);
            }
        },
        .composite => for (g.components) |c| {
            try spend(work, 1);
            var child: Flat = .init(out.points.allocator, out.contours);
            try flatten(src, c.gid, &child, work);
            const pts = child.points.items;
            const t = c.transform();
            if (c.flags & args_are_xy == 0) {
                if (c.hasScale()) transformPoints(pts, t);
                const p1: usize = @intCast(c.arg1);
                const p2: usize = @intCast(c.arg2);
                if (p1 >= out.points.items.len or p2 >= pts.len) return error.InvalidFont;
                translate(pts, out.points.items[p1].x - pts[p2].x, out.points.items[p1].y - pts[p2].y);
            } else if (!c.hasScale()) {
                translate(pts, c.dx, c.dy);
            } else if (c.flags & scaled_offset != 0) {
                translate(pts, c.dx, c.dy);
                transformPoints(pts, t);
            } else {
                transformPoints(pts, t);
                translate(pts, c.dx, c.dy);
            }
            const base = std.math.cast(u32, out.points.items.len) orelse return error.InvalidFont;
            try out.points.appendSlice(pts);
            if (out.contours) {
                try out.flags.appendSlice(child.flags.items);
                for (child.ends.items) |e| try out.ends.append(std.math.add(u32, base, e) catch return error.InvalidFont);
            }
        },
    }
}

fn translate(pts: []Point, dx: f64, dy: f64) void {
    for (pts) |*p| {
        p.x += dx;
        p.y += dy;
    }
}

fn transformPoints(pts: []Point, t: [4]f64) void {
    for (pts) |*p| {
        const x = p.x;
        const y = p.y;
        p.* = .{ .x = x * t[0] + y * t[2], .y = x * t[1] + y * t[3] };
    }
}

fn appendU16(list: *ManagedList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try list.appendSlice(&b);
}

fn appendI16(list: *ManagedList(u8), v: i16) !void {
    try appendU16(list, @bitCast(v));
}

fn appendU32(list: *ManagedList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try list.appendSlice(&b);
}

/// The glyph as an instanced subset stores it: points and component offsets
/// rounded with otRound, each in the 16-bit range. encodeGlyph writes this
/// and Outlines draws it, so a canvas draws the outline the PDF embeds.
fn roundedGlyph(arena: std.mem.Allocator, g: Glyph) !Glyph {
    var r = g;
    switch (g.kind) {
        .empty => {},
        .simple => {
            r.points = try arena.alloc(Point, g.points.len);
            for (r.points, g.points) |*to, from| {
                to.* = .{ .x = @floatFromInt(try toI16(otRound(from.x))), .y = @floatFromInt(try toI16(otRound(from.y))) };
            }
        },
        .composite => {
            r.components = try arena.dupe(Component, g.components);
            for (r.components) |*c| {
                if (c.flags & args_are_xy == 0) continue;
                c.dx = @floatFromInt(try toI16(otRound(c.dx)));
                c.dy = @floatFromInt(try toI16(otRound(c.dy)));
            }
        },
    }
    return r;
}

/// `g` with its own copies of every slice, in `arena`.
fn cloneGlyph(arena: std.mem.Allocator, g: Glyph) !Glyph {
    var c = g;
    c.points = try arena.dupe(Point, g.points);
    c.flags = try arena.dupe(u8, g.flags);
    c.ends = try arena.dupe(u16, g.ends);
    c.components = try arena.dupe(Component, g.components);
    return c;
}

/// Writes an instanced glyph after roundedGlyph: its points or offsets, the
/// recomputed bounds, no instructions.
fn encodeGlyph(out: *ManagedList(u8), g: Glyph, b: [4]i32) !void {
    if (g.kind == .empty) return;
    const start = out.items.len;
    try appendI16(out, if (g.kind == .simple) @intCast(g.ends.len) else -1);
    for (b) |v| try appendI16(out, @intCast(v));
    if (g.kind == .simple) {
        for (g.ends) |e| try appendU16(out, e);
        try appendU16(out, 0);
        const n = g.points.len;
        const arena = out.allocator;
        const flags = try arena.alloc(u8, n);
        defer arena.free(flags);
        const xs = try arena.alloc(i32, n);
        defer arena.free(xs);
        const ys = try arena.alloc(i32, n);
        defer arena.free(ys);
        var px: i32 = 0;
        var py: i32 = 0;
        for (g.points, g.flags, flags, xs, ys) |p, kept, *f, *dx, *dy| {
            const x = try toI16(p.x);
            const y = try toI16(p.y);
            dx.* = x - px;
            dy.* = y - py;
            px = x;
            py = y;
            if (dx.* < -32768 or dx.* > 32767 or dy.* < -32768 or dy.* > 32767) return error.InvalidFont;
            f.* = kept;
            if (dx.* == 0) {
                f.* |= flag_x_same;
            } else if (@abs(dx.*) <= 255) {
                f.* |= flag_x_short;
                if (dx.* > 0) f.* |= flag_x_same;
            }
            if (dy.* == 0) {
                f.* |= flag_y_same;
            } else if (@abs(dy.*) <= 255) {
                f.* |= flag_y_short;
                if (dy.* > 0) f.* |= flag_y_same;
            }
        }
        var i: usize = 0;
        while (i < n) {
            var run: usize = 1;
            while (i + run < n and run < 256 and flags[i + run] == flags[i]) run += 1;
            if (run > 1) {
                try out.append(flags[i] | flag_repeat);
                try out.append(@intCast(run - 1));
            } else {
                try out.append(flags[i]);
            }
            i += run;
        }
        for (flags, xs) |f, d| {
            if (f & flag_x_short != 0) {
                try out.append(@intCast(@abs(d)));
            } else if (f & flag_x_same == 0) {
                try appendI16(out, @intCast(d));
            }
        }
        for (flags, ys) |f, d| {
            if (f & flag_y_short != 0) {
                try out.append(@intCast(@abs(d)));
            } else if (f & flag_y_same == 0) {
                try appendI16(out, @intCast(d));
            }
        }
    } else {
        for (g.components, 0..) |c, i| {
            var flags = c.flags & ~(arg_words | more_components | has_instructions);
            if (i + 1 < g.components.len) flags |= more_components;
            if (c.flags & args_are_xy != 0) {
                try appendU16(out, flags | arg_words);
                try appendU16(out, c.gid);
                try appendI16(out, try toI16(c.dx));
                try appendI16(out, try toI16(c.dy));
            } else if (c.flags & arg_words != 0) {
                try appendU16(out, flags | arg_words);
                try appendU16(out, c.gid);
                try appendU16(out, @intCast(c.arg1));
                try appendU16(out, @intCast(c.arg2));
            } else {
                try appendU16(out, flags);
                try appendU16(out, c.gid);
                try out.append(@intCast(c.arg1));
                try out.append(@intCast(c.arg2));
            }
            for (c.scale[0..c.scale_len]) |s| try appendI16(out, s);
        }
    }
    while ((out.items.len - start) % 4 != 0) try out.append(0);
}

/// Where hmtx advances come from instead of the phantom points.
pub const AdvanceSource = struct {
    context: *const anyopaque,
    advance: *const fn (context: *const anyopaque, gid: u16) i32,
};

pub const Subset = struct {
    /// The sfnt, owned by the caller's allocator.
    bytes: []u8,
    /// head's recomputed bounding box: the union of the embedded glyphs.
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

/// Subsets `face` at the instance `normalized` (kb's normalized coordinates,
/// fvar order; not all zero). Like sfnt.subset, glyph ids are kept and `seed`
/// gets GID 0 and every component added. The subset holds:
/// - glyf: each embedded glyph at the instance (points or component offsets
///   rounded, bounds recomputed), with no instructions; other glyphs empty;
/// - loca (long), hmtx for every glyph (numberOfHMetrics = numGlyphs; a
///   glyph not embedded gets 0 and 0): the advance from the instanced phantom
///   points, or from `advances` when it is not null, and the left side
///   bearing from the left phantom point;
/// - head with the union of the embedded glyphs' bounds; hhea with
///   numberOfHMetrics, advanceWidthMax, minLeftSideBearing,
///   minRightSideBearing and xMaxExtent recomputed as fontTools does; maxp
///   with its hinting limits set to none;
/// - no cvt, fpgm or prep: hinting is dropped for instances, since hinting
///   programs are written for the default outlines (and cvar is not applied).
/// No variation table is copied.
pub fn subsetInstance(gpa: std.mem.Allocator, face: sfnt.Face, seed: []const u16, normalized: []const i16, advances: ?AdvanceSource) !Subset {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fvar = try sfnt.faceTable(face, "fvar") orelse return error.InvalidFont;
    const inst: Instance = .{ .coords = normalized, .tag_order = try axisTagOrder(arena, fvar, normalized.len) };
    const gvar_table = try sfnt.faceTable(face, "gvar");
    var gvar: ?Gvar = null;
    if (gvar_table) |t| gvar = try Gvar.init(t, normalized.len, face.num_glyphs);

    var used = try sfnt.collectUsed(arena, face, seed);
    const glyf_len: u64 = face.glyf.length;
    var work: u64 = work_base + work_per_byte * (glyf_len + if (gvar_table) |t| t.len else 0);

    var gs: Glyphs = .{ .arena = arena, .items = try arena.alloc(?Instanced, face.num_glyphs), .work = &work };
    @memset(gs.items, null);
    var gid: u16 = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        if (!used.isSet(gid)) continue;
        gs.items[gid] = try instanceGlyph(arena, face, if (gvar) |*g| g else null, inst, gid, &work);
    }

    var glyf = ManagedList(u8).init(arena);
    var loca = ManagedList(u8).init(arena);
    var hmtx = ManagedList(u8).init(arena);
    var head_box: ?[4]i32 = null;
    var advance_max: u16 = 0;
    var min_lsb: i32 = std.math.maxInt(i32);
    var min_rsb: i32 = std.math.maxInt(i32);
    var max_extent: i32 = std.math.minInt(i32);
    var any_outline = false;
    gid = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        try appendU32(&loca, @intCast(glyf.items.len));
        const ig = gs.items[gid] orelse {
            try appendU32(&hmtx, 0);
            continue;
        };
        const b = try bounds(&gs, gid);
        try encodeGlyph(&glyf, try roundedGlyph(arena, ig.glyph), b);
        const advance_f = if (advances) |a|
            @max(0, @as(f64, @floatFromInt(a.advance(a.context, gid))))
        else
            @max(0, otRound(ig.right - ig.left));
        if (advance_f > 65535) return error.InvalidFont;
        const advance: u16 = @intFromFloat(advance_f);
        const lsb = try toI16(otRound(@as(f64, @floatFromInt(b[0])) - ig.left));
        try appendU16(&hmtx, advance);
        try appendI16(&hmtx, lsb);
        advance_max = @max(advance_max, advance);
        if (ig.glyph.kind != .empty) {
            any_outline = true;
            const width = b[2] - b[0];
            min_lsb = @min(min_lsb, lsb);
            min_rsb = @min(min_rsb, @as(i32, advance) - lsb - width);
            max_extent = @max(max_extent, @as(i32, lsb) + width);
            head_box = if (head_box) |u| .{ @min(u[0], b[0]), @min(u[1], b[1]), @max(u[2], b[2]), @max(u[3], b[3]) } else b;
        }
    }
    try appendU32(&loca, @intCast(glyf.items.len));
    if (!any_outline) {
        min_lsb = 0;
        min_rsb = 0;
        max_extent = 0;
    }
    const box = head_box orelse .{ 0, 0, 0, 0 };

    const head = try arena.dupe(u8, try sfnt.tableSlice(face.bytes, face.head));
    if (head.len < 54) return error.InvalidFont;
    std.mem.writeInt(u32, head[8..12], 0, .big);
    for (box, 0..) |v, i| std.mem.writeInt(i16, head[36 + 2 * i ..][0..2], @intCast(v), .big);
    std.mem.writeInt(i16, head[50..52], 1, .big);

    const hhea = try arena.dupe(u8, try sfnt.tableSlice(face.bytes, face.hhea));
    if (hhea.len < 36) return error.InvalidFont;
    std.mem.writeInt(u16, hhea[10..12], advance_max, .big);
    std.mem.writeInt(i16, hhea[12..14], try toI16(@floatFromInt(min_lsb)), .big);
    std.mem.writeInt(i16, hhea[14..16], try toI16(@floatFromInt(min_rsb)), .big);
    std.mem.writeInt(i16, hhea[16..18], try toI16(@floatFromInt(max_extent)), .big);
    std.mem.writeInt(u16, hhea[34..36], face.num_glyphs, .big);

    const maxp = try arena.dupe(u8, try sfnt.tableSlice(face.bytes, face.maxp));
    if (maxp.len >= 32 and std.mem.readInt(u32, maxp[0..4], .big) == 0x00010000) {
        // maxZones 1; no twilight points, storage, functions, instruction
        // definitions, stack or instructions.
        std.mem.writeInt(u16, maxp[14..16], 1, .big);
        @memset(maxp[16..28], 0);
    }

    var tables = [_]sfnt.OutTable{
        .{ .tag = "glyf".*, .bytes = glyf.items },
        .{ .tag = "head".*, .bytes = head },
        .{ .tag = "hhea".*, .bytes = hhea },
        .{ .tag = "hmtx".*, .bytes = hmtx.items },
        .{ .tag = "loca".*, .bytes = loca.items },
        .{ .tag = "maxp".*, .bytes = maxp },
    };
    return .{
        .bytes = try sfnt.assemble(gpa, &tables),
        .x_min = @intCast(box[0]),
        .y_min = @intCast(box[1]),
        .x_max = @intCast(box[2]),
        .y_max = @intCast(box[3]),
    };
}

/// One step of a glyph's outline, in font units, y up. A contour is a move,
/// then lines and quadratic curves, then a close; fill with the nonzero
/// winding rule, as TrueType does.
pub const PathCommand = union(enum) {
    move: Point,
    line: Point,
    /// A quadratic Bezier from the current point through `control` to `to`.
    quad: struct { control: Point, to: Point },
    close,
};

/// A font's glyph outlines at its instance: the outlines the PDF embeds.
/// Each glyph is decoded, given the instance's gvar deltas (none at the
/// default instance or for a font without axes), and rounded as an instanced
/// subset stores it (roundedGlyph), so drawing these paths draws what the
/// PDF draws. Glyphs are kept after first use; the memory grows with the
/// number of distinct glyphs asked for, up to the font's glyph count.
///
/// TrueType outlines only: init returns error.UnsupportedFontFormat for a
/// CFF font, and `path` returns it for a glyph with cubic contours.
/// `bytes` must outlive the Outlines; zpdf.Font.outlines passes the font's.
pub const Outlines = struct {
    arena_state: std.heap.ArenaAllocator,
    face: sfnt.Face,
    gvar: ?Gvar,
    inst: Instance,
    /// Decoded, instanced and rounded on first use.
    glyphs: []?Glyph,
    /// The budget each `path` call starts with, as subsetInstance's.
    work_budget: u64,

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8, index: i32, normalized: []const i16) !Outlines {
        const face = try sfnt.open(bytes, index);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const gvar_table = try sfnt.faceTable(face, "gvar");
        const instanced = std.mem.indexOfNone(i16, normalized, &.{0}) != null;
        var gvar: ?Gvar = null;
        var inst: Instance = .{ .coords = &.{}, .tag_order = &.{} };
        if (instanced) {
            const fvar = try sfnt.faceTable(face, "fvar") orelse return error.InvalidFont;
            inst = .{ .coords = try arena.dupe(i16, normalized), .tag_order = try axisTagOrder(arena, fvar, normalized.len) };
            if (gvar_table) |t| gvar = try Gvar.init(t, normalized.len, face.num_glyphs);
        }
        const glyphs = try arena.alloc(?Glyph, face.num_glyphs);
        @memset(glyphs, null);
        const glyf_len: u64 = face.glyf.length;
        return .{
            .arena_state = arena_state,
            .face = face,
            .gvar = gvar,
            .inst = inst,
            .glyphs = glyphs,
            .work_budget = work_base + work_per_byte * (glyf_len + if (gvar_table) |t| t.len else 0),
        };
    }

    pub fn deinit(self: *Outlines) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    fn glyphAt(self: *Outlines, gid: u16) !*const Glyph {
        return if (self.glyphs[gid]) |*g| g else error.InvalidFont;
    }

    /// Glyph `gid`'s outline, every component placed, allocated with
    /// `allocator` and owned by the caller. Empty for a glyph with no
    /// contours. Contours are drawn as fontTools' glyf `draw` draws them
    /// (the same starting point, implied on-curve points and segments), with
    /// each string of off-curve points split into single quadratic curves.
    pub fn path(self: *Outlines, allocator: std.mem.Allocator, gid: u16) ![]PathCommand {
        if (gid >= self.face.num_glyphs) return error.InvalidFont;
        var work = self.work_budget;
        var scratch_state: std.heap.ArenaAllocator = .init(self.arena_state.child_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        // The component tree: no cycles, bounded depth, every gid in range.
        var used = try sfnt.collectUsed(scratch, self.face, &.{gid});
        var it = used.iterator(.{});
        while (it.next()) |i| {
            const g: u16 = @intCast(i);
            if (self.glyphs[g] != null) continue;
            // Built in scratch and kept only when complete, so a glyph that
            // fails (a broken gvar, the budget) leaves nothing behind in the
            // long-lived arena however often it is asked for.
            const ig = try instanceGlyph(scratch, self.face, if (self.gvar) |*gv| gv else null, self.inst, g, &work);
            self.glyphs[g] = try cloneGlyph(self.arena_state.allocator(), try roundedGlyph(scratch, ig.glyph));
        }

        var flat: Flat = .init(scratch, true);
        try flatten(self, gid, &flat, &work);
        var out = ManagedList(PathCommand).init(allocator);
        errdefer out.deinit();
        try drawContours(&out, flat.points.items, flat.flags.items, flat.ends.items);
        return out.toOwnedSlice();
    }
};

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = 0.5 * (a.x + b.x), .y = 0.5 * (a.y + b.y) };
}

/// fontTools' _g_l_y_f.Glyph.draw for quadratic contours, through BasePen's
/// qCurveTo, which splits each string of off-curve points at the implied
/// on-curve midpoints:
/// - a contour with an on-curve point is rotated to end at its first one,
///   which is the move; the line back to that point is left to the close;
/// - a contour with no on-curve point starts at the midpoint of its last and
///   first points.
fn drawContours(out: *ManagedList(PathCommand), points: []const Point, flags: []const u8, ends: []const u32) !void {
    var start: usize = 0;
    for (ends) |end_index| {
        const end = @as(usize, end_index) + 1;
        if (end <= start or end > points.len) return error.InvalidFont;
        const pts = points[start..end];
        const fl = flags[start..end];
        start = end;
        for (fl) |f| if (f & flag_cubic != 0) return error.UnsupportedFontFormat;
        const n = pts.len;
        const first_on = for (fl, 0..) |f, i| {
            if (f & flag_on_curve != 0) break i;
        } else {
            const begin = midpoint(pts[n - 1], pts[0]);
            try out.append(.{ .move = begin });
            for (0..n - 1) |i| try out.append(.{ .quad = .{ .control = pts[i], .to = midpoint(pts[i], pts[i + 1]) } });
            try out.append(.{ .quad = .{ .control = pts[n - 1], .to = begin } });
            try out.append(.close);
            continue;
        };
        // Position k of the rotated contour is point (first_on + 1 + k) % n,
        // so the last position is first_on.
        const at = struct {
            fn at(p: []const Point, f: []const u8, first: usize, k: usize) struct { Point, bool } {
                const i = (first + 1 + k) % p.len;
                return .{ p[i], f[i] & flag_on_curve != 0 };
            }
        }.at;
        try out.append(.{ .move = pts[first_on] });
        var k: usize = 0;
        while (k < n) {
            var j = k;
            while (!at(pts, fl, first_on, j)[1]) j += 1;
            const on = at(pts, fl, first_on, j)[0];
            if (j == k) {
                // The last point is the move's: close draws that line.
                if (k != n - 1) try out.append(.{ .line = on });
            } else {
                var i = k;
                while (i + 1 < j) : (i += 1) {
                    const off = at(pts, fl, first_on, i)[0];
                    try out.append(.{ .quad = .{ .control = off, .to = midpoint(off, at(pts, fl, first_on, i + 1)[0]) } });
                }
                try out.append(.{ .quad = .{ .control = at(pts, fl, first_on, j - 1)[0], .to = on } });
            }
            k = j + 1;
        }
        try out.append(.close);
    }
}

/// The canonical text of a subset's glyphs and horizontal metrics, the form
/// `tools/instance-points.py` prints (its docstring has the format). Owned by
/// `gpa`.
pub fn instanceDump(gpa: std.mem.Allocator, subset_bytes: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const face = try sfnt.open(subset_bytes, 0);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var gid: u16 = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        const data = try sfnt.glyphData(face, gid);
        const g = try decodeGlyph(arena, data);
        const adv = try sfnt.glyphAdvance(face, gid);
        const lsb = try sfnt.glyphLsb(face, gid);
        if (g.kind == .empty) {
            try w.print("{d} e {d} {d}\n", .{ gid, adv, lsb });
            continue;
        }
        var r: Reader = .{ .bytes = data[2..10] };
        const head = .{ adv, lsb, try r.i16_(), try r.i16_(), try r.i16_(), try r.i16_() };
        if (g.kind == .composite) {
            try w.print("{d} c {d} {d} {d} {d} {d} {d} |", .{ gid, head[0], head[1], head[2], head[3], head[4], head[5] });
            for (g.components, 0..) |c, i| {
                if (i != 0) try w.writeAll(" ;");
                const flags = c.flags & (0x0004 | 0x0200 | 0x0400 | 0x0800 | 0x1000);
                try w.print(" {d} {d} {s} {d} {d}", .{ c.gid, flags, if (c.flags & args_are_xy != 0) "x" else "a", c.arg1, c.arg2 });
                if (c.hasScale()) {
                    const t = c.transform();
                    try w.writeAll(" t");
                    for (t) |v| try w.print(" {d}", .{@as(i32, @intFromFloat(@round(v * 16384)))});
                }
            }
            try w.writeByte('\n');
        } else {
            try w.print("{d} s {d} {d} {d} {d} {d} {d} |", .{ gid, head[0], head[1], head[2], head[3], head[4], head[5] });
            for (g.ends) |e| try w.print(" {d}", .{e});
            try w.writeAll(" |");
            for (g.points, g.flags) |p, f| try w.print(" {d} {d} {d}", .{ @as(i32, @intFromFloat(p.x)), @as(i32, @intFromFloat(p.y)), f });
            try w.writeByte('\n');
        }
    }
    return out.toOwnedSlice();
}

pub const OracleCase = struct {
    font: []const u8,
    variations: []const u8,
    /// fontTools' normalized coordinates, which must equal kb's.
    normalized: []const i16,
    sha256: []const u8,
};

// Each case: cd harfbuzz/test && uv run tools/instance-points.py <font> --variations=<variations>
// (fontTools 4.67.0, pinned in the script). It prints `normalized` and `sha256`.
pub const oracle_cases = [_]OracleCase{
    .{ .font = "roboto_flex", .variations = "wght=900,wdth=25,opsz=144", .normalized = &.{ 13653, -16384, 16384, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .sha256 = "51b756c819f70fdcd8eb97378610a6def0573fd227acbc7f85f05da0ec083e79" },
    .{ .font = "roboto_flex", .variations = "wght=100,wdth=151,GRAD=-200,slnt=-10", .normalized = &.{ -16384, 16384, 0, -16384, -16384, 0, 0, 0, 0, 0, 0, 0, 0 }, .sha256 = "7610c3ff75ce46b12b87af4a3241de25486815e0b4497d2fbfef00fa2dc411a4" },
    .{ .font = "roboto_flex", .variations = "wght=650,opsz=36,XTRA=380,YTUC=600", .normalized = &.{ 6827, 0, 8060, 0, 0, -9943, 0, 0, 0, -9973, 0, 0, 0 }, .sha256 = "864c017d9cbc4058e46d85f51ff73342692749e4dee24b0b259100771e44b284" },
    .{ .font = "variable", .variations = "opsz=144,wght=100", .normalized = &.{ 16384, -16384, 0, 0 }, .sha256 = "b58d9c8990578826332f76a126143e5a486f82d651f0193d3ad3b7985e54e5ab" },
    .{ .font = "variable", .variations = "opsz=72,wght=500,SOFT=100,WONK=0", .normalized = &.{ 7646, -8192, 16384, -16384 }, .sha256 = "455fe2b45558cad62febc7ade51583d013c15129f34bb1e89a4a1c9b1f321c40" },
    .{ .font = "variable", .variations = "wght=300,SOFT=50", .normalized = &.{ 0, -13107, 8192, 0 }, .sha256 = "28eec0f69610f7415b194268abe476eb7b3b758526ca6e348fbb6e24eb79dfd0" },
    .{ .font = "noto_sans_vf", .variations = "wght=100,wdth=62.5,CTGR=100", .normalized = &.{ -16384, -16384, 16384 }, .sha256 = "f871d2ad340f5b5896f6b47d138a05bf7c48a95b4efb659bb8ff66f94abadc61" },
    .{ .font = "noto_sans_vf", .variations = "wght=900,wdth=80", .normalized = &.{ 16384, -9284, 0 }, .sha256 = "2c026eaacce6a6d72583a7a9a79064c9161ff30b06f08352de868120713af1aa" },
    .{ .font = "noto_sans_vf", .variations = "wght=250,CTGR=40", .normalized = &.{ -10624, 0, 6554 }, .sha256 = "56132426b6c3be880230fe4c90d63af868a9c34db995026b34e931cd770b68cb" },
    .{ .font = "gpos_four", .variations = "wght=100,wdth=70", .normalized = &.{ -16384, -16384 }, .sha256 = "a0e1456c3bfa1288d311ad6915a3a23cc7b0a7791d74617638787b604d2606ff" },
    .{ .font = "gpos_four", .variations = "wght=900", .normalized = &.{ 16384, 0 }, .sha256 = "b1d28f4cd46a67a1592a2477d52cccf5c8b20b8240d662be56c766b778880202" },
    .{ .font = "gpos_four", .variations = "wght=650,wdth=85", .normalized = &.{ 8110, -8192 }, .sha256 = "2d948dab3c16c2369af0d5e0f3991c93911e1bc0a73f367ddca8c0fd6cfb6ec3" },
    .{ .font = "mada", .variations = "wght=100", .normalized = &.{-16384}, .sha256 = "65e25d429062f862939c8c62d0a1eda142e701def019fa330a72fee8d37527e4" },
    .{ .font = "mada", .variations = "wght=1000", .normalized = &.{16384}, .sha256 = "39ed680b59464742d171b99f21c4e04f900d9fa8a32fae67f7c87e6daf6a82e8" },
    .{ .font = "mada", .variations = "wght=777", .normalized = &.{8772}, .sha256 = "9abe802e428fa5b9887579ae3ac1e023d75608ec26b4fb86dd07c6f7e774ea08" },
    // Hinted (fpgm, cvar, instructions in 517 composites), so the subset's lack of hinting is checked on a font that has it.
    .{ .font = "roboto_variable", .variations = "wght=900,wdth=75", .normalized = &.{ 16384, -16384 }, .sha256 = "0e520ee74b363cc64e56a2d56279f2bd5253d1f93d4b14bc4e5ab1920af94bc6" },
    .{ .font = "roboto_variable", .variations = "wght=250,wdth=100", .normalized = &.{ -10695, 0 }, .sha256 = "edce7df57a69913e1b9aa0d40c404cefb7ef1c56f288b176a4f886f6c3a54aa7" },
};

pub fn oracleFontPath(comptime name: []const u8) []const u8 {
    return @field(@import("build_options"), "test_font_" ++ name);
}

/// Loads `path` with `variations` through zpdf.Font, so the coordinates are kb's.
pub fn loadInstance(gpa: std.mem.Allocator, path: []const u8, variations: []const u8) !@import("root.zig").Font {
    const zpdf = @import("root.zig");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const vars = if (variations.len == 0) try gpa.alloc(zpdf.Variation, 0) else try zpdf.parseVariations(gpa, variations);
    defer gpa.free(vars);
    return zpdf.Font.init(gpa, bytes, 0, vars);
}

/// Every glyph of the font, instanced, as the canonical text. Also checks
/// that the subset carries no hinting: maxp's limits say none, no simple
/// glyph has instructions and no component says WE_HAVE_INSTRUCTIONS.
fn instanceAllGlyphsDump(gpa: std.mem.Allocator, font: anytype) ![]u8 {
    const face = try sfnt.open(font.bytes, 0);
    const seed = try gpa.alloc(u16, face.num_glyphs);
    defer gpa.free(seed);
    for (seed, 0..) |*s, i| s.* = @intCast(i);
    const sub = try subsetInstance(gpa, face, seed, font.normalized, null);
    defer gpa.free(sub.bytes);
    try expectNoHinting(sub.bytes);
    return instanceDump(gpa, sub.bytes);
}

fn expectNoHinting(subset_bytes: []const u8) !void {
    const face = try sfnt.open(subset_bytes, 0);
    const maxp = try sfnt.tableSlice(subset_bytes, face.maxp);
    if (maxp.len >= 32) {
        try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, maxp[14..16], .big));
        for (0..6) |i| try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, maxp[16 + 2 * i ..][0..2], .big));
    }
    for ([_]*const [4]u8{ "cvt ", "fpgm", "prep", "gvar", "fvar", "HVAR", "MVAR", "avar" }) |tag| {
        try std.testing.expect(try sfnt.faceTable(face, tag) == null);
    }
    var gid: u16 = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        const data = try sfnt.glyphData(face, gid);
        if (data.len == 0) continue;
        const contours = std.mem.readInt(i16, data[0..2], .big);
        if (contours > 0) {
            const at = 10 + 2 * @as(usize, @intCast(contours));
            try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, data[at..][0..2], .big));
        } else if (contours < 0) {
            var r: Reader = .{ .bytes = data, .pos = 10 };
            while (true) {
                const flags = try r.u16_();
                try std.testing.expect(flags & has_instructions == 0);
                _ = try r.take(2 + @as(usize, if (flags & arg_words != 0) 4 else 2));
                _ = try r.take(@as(usize, if (flags & has_scale != 0) 2 else if (flags & has_xy_scale != 0) 4 else if (flags & has_two_by_two != 0) 8 else 0));
                if (flags & more_components == 0) break;
            }
        }
    }
}

/// Every glyph's Outlines.path, in the text `tools/instance-points.py --paths`
/// prints (its docstring has the format). Owned by `gpa`.
pub fn pathsDump(gpa: std.mem.Allocator, outlines: *Outlines) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    var gid: u16 = 0;
    while (gid < outlines.face.num_glyphs) : (gid += 1) {
        const cmds = try outlines.path(gpa, gid);
        defer gpa.free(cmds);
        try w.print("{d}", .{gid});
        for (cmds) |c| switch (c) {
            .move => |p| try w.print(" M {d} {d}", .{ p.x + 0.0, p.y + 0.0 }),
            .line => |p| try w.print(" L {d} {d}", .{ p.x + 0.0, p.y + 0.0 }),
            .quad => |q| try w.print(" Q {d} {d} {d} {d}", .{ q.control.x + 0.0, q.control.y + 0.0, q.to.x + 0.0, q.to.y + 0.0 }),
            .close => try w.writeAll(" Z"),
        };
        try w.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

const PathCase = struct { font: []const u8, variations: []const u8, sha256: []const u8 };

// Each case: cd harfbuzz/test && uv run tools/instance-points.py <font> [--variations=<v>] --paths
// (fontTools 4.67.0). The oracle_cases instances, plus: SourceSansVariable-Roman.anchor (the
// harfbuzz corpus's only point-matched component) at its default and two instances, and three
// static fonts with many composites (Noto IKEA Hebrew: 1,945 scaled components; Amiri; Roboto).
const path_cases = [_]PathCase{
    .{ .font = "roboto_flex", .variations = "wght=900,wdth=25,opsz=144", .sha256 = "1bef3f97559a15d5588a021511c137bda7bfbb47a252874d90771f2e9e9a7ef8" },
    .{ .font = "roboto_flex", .variations = "wght=100,wdth=151,GRAD=-200,slnt=-10", .sha256 = "9427024ed0cbf36e6854b498bfdd5a50457466d26cd7cc0930ad3e4a3bfe9f09" },
    .{ .font = "roboto_flex", .variations = "wght=650,opsz=36,XTRA=380,YTUC=600", .sha256 = "4af86f6be2da02b3b5aa8b414a813356e2759dff0fbbfddb06d29a5344914971" },
    .{ .font = "variable", .variations = "opsz=144,wght=100", .sha256 = "3db0a0e6e0a29dedca3a2e362a7f73bbab02cb252ecea24eaf433e365989a49b" },
    .{ .font = "variable", .variations = "opsz=72,wght=500,SOFT=100,WONK=0", .sha256 = "59d8efef76ba3059286121d69b015010146f861ba52e4fc5f46b1bb92af0e8a0" },
    .{ .font = "variable", .variations = "wght=300,SOFT=50", .sha256 = "476de2219fbd2fd27f9140b7d31b887fdaf3fc61cb316fb18465751f9e2f8f15" },
    .{ .font = "noto_sans_vf", .variations = "wght=100,wdth=62.5,CTGR=100", .sha256 = "daedae72c7be79e7e29015c1cf34eec666c1ba6ddefee2e516a698ed2c4d3a40" },
    .{ .font = "noto_sans_vf", .variations = "wght=900,wdth=80", .sha256 = "d6816ee7d20555d5037d52426ebebb0bdf357aafa54798da8b4263c55dbb1e51" },
    .{ .font = "noto_sans_vf", .variations = "wght=250,CTGR=40", .sha256 = "31cff951826d4b23aaf277c29a100a95a50a19d47bfbef504a7d6ae6a4cfd98b" },
    .{ .font = "gpos_four", .variations = "wght=100,wdth=70", .sha256 = "a2531a196248a586b9c82be31956b2b204196519187b27e5292cf50756ae5a85" },
    .{ .font = "gpos_four", .variations = "wght=900", .sha256 = "e838c9b9e2c9acd7e787571a54b8ffdc73b18fcb855525fd365e3d38defcfe7c" },
    .{ .font = "gpos_four", .variations = "wght=650,wdth=85", .sha256 = "df4ff8d07efd1bee4bcde448527bcaf005c085bacba7b5735f5ed7e284333956" },
    .{ .font = "mada", .variations = "wght=100", .sha256 = "75a38bdc324a508c494a72b6a38cc2f8efca44644070fab5864aaca7f48cee90" },
    .{ .font = "mada", .variations = "wght=1000", .sha256 = "0f458aceb91ae233c94405141fcd7afbfefe0b8b52b0bc722512139bf09f1511" },
    .{ .font = "mada", .variations = "wght=777", .sha256 = "bbea8849e69a42af9d31307e9af2f9847186fc958ff1ac0f045a32ce1bde204c" },
    .{ .font = "roboto_variable", .variations = "wght=900,wdth=75", .sha256 = "4237a53fb75b0ecd1d092f285aa356f881e289ee65199c05a381c5ca3dc41397" },
    .{ .font = "roboto_variable", .variations = "wght=250,wdth=100", .sha256 = "769dcf7b341dcc8e87c2d4ddd63984f9b9245b1968d648d07c6d03ddcf1ca690" },
    .{ .font = "anchor", .variations = "", .sha256 = "d02211819d5535108ea6fe08cd1e249e9af51e1dbb1d301aa5eb3d6e4be1beaf" },
    .{ .font = "anchor", .variations = "wght=900", .sha256 = "173a1e8ae3b58d6890a23fb1bc9efd2d049d84f924d98aceb19dd79d461948b2" },
    .{ .font = "anchor", .variations = "wght=350", .sha256 = "c619d7860a9d5e74148c858adf08119ccc078b59cdbf88096829682bb0790e85" },
    .{ .font = "noto_hebrew", .variations = "", .sha256 = "203320acdaf4e89093439e34d68d06bc6d431de5c6083c3e533998387832bbfc" },
    .{ .font = "amiri", .variations = "", .sha256 = "982ce5394bd62f31055245232e4edb5f0aa05615575e85cca93fc51921799a00" },
    .{ .font = "roboto", .variations = "", .sha256 = "cf565aa844f2166b8a0ef505ab73d9c18037c60f44557e39d2f4ec3b0bfe19da" },
};

test "every glyph's outline path equals fontTools' drawing of the instance" {
    const gpa = std.testing.allocator;
    inline for (path_cases) |case| {
        var font = try loadInstance(gpa, oracleFontPath(case.font), case.variations);
        defer font.deinit();
        var outlines = try font.outlines(gpa);
        defer outlines.deinit();
        const dump = try pathsDump(gpa, &outlines);
        defer gpa.free(dump);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(dump, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, case.sha256)) {
            std.debug.print("{s} {s}: zpdf's paths follow\n{s}", .{ case.font, case.variations, dump });
            return error.TestUnexpectedResult;
        }
    }
}

test "instanced outlines, bounds and hmtx equal fontTools' instancer for every glyph" {
    const gpa = std.testing.allocator;
    inline for (oracle_cases) |case| {
        var font = try loadInstance(gpa, oracleFontPath(case.font), case.variations);
        defer font.deinit();
        if (!std.mem.eql(i16, case.normalized, font.normalized)) {
            std.debug.print("{s} {s}: kb normalized {any}, fontTools {any}\n", .{ case.font, case.variations, font.normalized, case.normalized });
            return error.TestUnexpectedResult;
        }
        const dump = try instanceAllGlyphsDump(gpa, &font);
        defer gpa.free(dump);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(dump, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, case.sha256)) {
            std.debug.print("{s} {s}: zpdf's canonical text follows\n{s}", .{ case.font, case.variations, dump });
            return error.TestUnexpectedResult;
        }
    }
}

test "phantom-point advances equal kb's for every glyph of the fonts without HVAR" {
    // kb takes these fonts' advances from gvar's phantom points (HarfBuzz's
    // float32 arithmetic); zpdf computes them in f64 with fontTools' order.
    // This is the check that the two have not drifted apart.
    const gpa = std.testing.allocator;
    var n_checked: usize = 0;
    inline for (oracle_cases) |case| {
        var font = try loadInstance(gpa, oracleFontPath(case.font), case.variations);
        defer font.deinit();
        const face = try sfnt.open(font.bytes, 0);
        if (try sfnt.faceTable(face, "HVAR") == null) {
            const seed = try gpa.alloc(u16, face.num_glyphs);
            defer gpa.free(seed);
            for (seed, 0..) |*s, i| s.* = @intCast(i);
            const sub = try subsetInstance(gpa, face, seed, font.normalized, null);
            defer gpa.free(sub.bytes);
            const sub_face = try sfnt.open(sub.bytes, 0);
            var n_varied: usize = 0;
            var gid: u16 = 0;
            while (gid < face.num_glyphs) : (gid += 1) {
                const phantom: i32 = try sfnt.glyphAdvance(sub_face, gid);
                try std.testing.expectEqual(font.glyphAdvanceX(gid), phantom);
                if (phantom != try sfnt.glyphAdvance(face, gid)) n_varied += 1;
                n_checked += 1;
            }
            try std.testing.expect(n_varied > 0);
        }
    }
    // TestGPOSFour (13 glyphs) and Mada-VF (529), 3 instances each.
    try std.testing.expectEqual(@as(usize, 3 * (13 + 529)), n_checked);
}

test "three axes with one tag are instanced by index, as HarfBuzz does" {
    // fvar has three axes all tagged "0001", so fontTools (which keys axes by
    // tag) is no oracle. HarfBuzz's points, unrounded:
    //   hb-view --glyphs --font-size=upem -O svg --variations=0001=500 <font> gid2
    // starts "M -481.125 -608.75 C -481.125 -623.5 -475.9375 -636.1875" (SVG y
    // is down; Cairo writes TrueType's quadratic off-curve point q as the
    // cubic control point p0 + 2/3 (q - p0), so q = p0 + 3/2 (c1 - p0):
    // (-481.125, 630.875)), and test/shape/data/in-house/tests/variations.tests
    // gives the period an advance of 681 at 0001=500. At 0001=1000 the path
    // starts "M 708 -54 C 708 -69.332031", so q = (708, 76.998).
    const gpa = std.testing.allocator;
    const Case = struct { variations: []const u8, points: []const [2]i32, advance: u16 };
    const cases = [_]Case{
        .{ .variations = "0001=500", .points = &.{ .{ -481, 609 }, .{ -481, 631 } }, .advance = 681 },
        .{ .variations = "0001=1000", .points = &.{ .{ 708, 54 }, .{ 708, 77 } }, .advance = 1000 },
    };
    for (cases) |case| {
        var font = try loadInstance(gpa, oracleFontPath("duplicate_axes"), case.variations);
        defer font.deinit();
        try std.testing.expectEqual(@as(usize, 3), font.normalized.len);
        const face = try sfnt.open(font.bytes, 0);
        // The font has HVAR, so the PDF writer takes kb's advances (HarfBuzz's
        // 681); its gvar phantom points disagree with its HVAR.
        const kb_advance = struct {
            fn f(context: *const anyopaque, gid: u16) i32 {
                const f_: *const @import("root.zig").Font = @ptrCast(@alignCast(context));
                return f_.glyphAdvanceX(gid);
            }
        }.f;
        const sub = try subsetInstance(gpa, face, &.{2}, font.normalized, .{ .context = &font, .advance = kb_advance });
        defer gpa.free(sub.bytes);
        const sub_face = try sfnt.open(sub.bytes, 0);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const g = try decodeGlyph(arena.allocator(), try sfnt.glyphData(sub_face, 2));
        for (case.points, 0..) |want, i| {
            try std.testing.expectEqual(@as(f64, @floatFromInt(want[0])), g.points[i].x);
            try std.testing.expectEqual(@as(f64, @floatFromInt(want[1])), g.points[i].y);
        }
        try std.testing.expectEqual(case.advance, try sfnt.glyphAdvance(sub_face, 2));
        try std.testing.expectEqual(@as(i32, case.advance), font.glyphAdvanceX(2));
    }
}

/// The bytes of glyph `gid`'s gvar data inside `bytes` (a font file).
fn gvarGlyphDataAt(bytes: []u8, gid: u16) ![]u8 {
    const face = try sfnt.open(bytes, 0);
    const table = (try sfnt.faceTable(face, "gvar")).?;
    const gv = try Gvar.init(table, std.mem.readInt(u16, table[4..6], .big), face.num_glyphs);
    const data = try gv.glyphData(gid);
    const at = @intFromPtr(data.ptr) - @intFromPtr(bytes.ptr);
    return bytes[at..][0..data.len];
}

test "a glyph's gvar data offset inside its own header is InvalidFont" {
    // Found by the corrupt-font sweep: the reader's position (4) lay past the
    // new end of the header slice.
    const gpa = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, oracleFontPath("mada"), gpa, .unlimited);
    defer gpa.free(bytes);
    const face = try sfnt.open(bytes, 0);
    var gid: u16 = 1;
    while ((try gvarGlyphDataAt(bytes, gid)).len < 8) gid += 1;
    const data = try gvarGlyphDataAt(bytes, gid);
    const normalized = [_]i16{16384};
    for ([_]u16{ 0, 2, 3 }) |bad| {
        const saved = data[2..4].*;
        std.mem.writeInt(u16, data[2..4], bad, .big);
        try std.testing.expectError(error.InvalidFont, subsetInstance(gpa, face, &.{gid}, &normalized, null));
        data[2..4].* = saved;
    }
    const ok = try subsetInstance(gpa, face, &.{gid}, &normalized, null);
    gpa.free(ok.bytes);
}

test "a composite whose instanced bounds leave the 16-bit range is InvalidFont" {
    // Found by the corrupt-font sweep: the union of component bounds was
    // narrowed to 16 bits unchecked. Fraunces gid 8 is a composite; its first
    // component's offset becomes 32767, which a component wider than 0 units
    // pushes past 32767.
    const gpa = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, oracleFontPath("variable"), gpa, .unlimited);
    defer gpa.free(bytes);
    const face = try sfnt.open(bytes, 0);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var gid: u16 = 1;
    const record = while (gid < face.num_glyphs) : (gid += 1) {
        const data = try sfnt.glyphData(face, gid);
        const g = try decodeGlyph(arena.allocator(), data);
        if (g.kind != .composite) continue;
        const flags = std.mem.readInt(u16, data[10..12], .big);
        if (flags & args_are_xy == 0 or flags & arg_words == 0 or flags & any_scale != 0) continue;
        break @constCast(data[10..18]);
    } else return error.TestUnexpectedResult;
    std.mem.writeInt(i16, record[4..6], 32767, .big);
    const normalized = [_]i16{ 0, -16384, 0, 0 };
    try std.testing.expectError(error.InvalidFont, subsetInstance(gpa, face, &.{gid}, &normalized, null));
    // With gvar hidden there are no deltas: the offset stays 32767, inside the
    // 16-bit range, and only the component's moved bounds leave it.
    const num_tables = std.mem.readInt(u16, bytes[4..6], .big);
    for (0..num_tables) |i| {
        const tag = bytes[12 + 16 * i ..][0..4];
        if (std.mem.eql(u8, tag, "gvar")) tag.* = "zvar".*;
    }
    try std.testing.expect(try sfnt.faceTable(face, "gvar") == null);
    try std.testing.expectError(error.InvalidFont, subsetInstance(gpa, face, &.{gid}, &normalized, null));
}

test "decodeGlyph refuses contour ends that do not increase and flag repeats past the points" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Two contours, bbox, ends 3 then 3, no instructions, then flags.
    const same_end = [_]u8{ 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 3, 0, 0, 0x31, 0x31, 0x31, 0x31 };
    try std.testing.expectError(error.InvalidFont, decodeGlyph(arena.allocator(), &same_end));
    // One contour of 2 points; the first flag repeats 5 times.
    const long_repeat = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0x39, 5 };
    try std.testing.expectError(error.InvalidFont, decodeGlyph(arena.allocator(), &long_repeat));
    // The same glyph with a repeat of 1 decodes: both points at (0, 0).
    const ok = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0x39, 1 };
    const g = try decodeGlyph(arena.allocator(), &ok);
    try std.testing.expectEqual(@as(usize, 2), g.points.len);
}

test "a gvar header that disagrees with fvar or maxp is InvalidFont" {
    const gpa = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, oracleFontPath("mada"), gpa, .unlimited);
    defer gpa.free(bytes);
    const face = try sfnt.open(bytes, 0);
    const table = (try sfnt.faceTable(face, "gvar")).?;
    const gvar = bytes[@intFromPtr(table.ptr) - @intFromPtr(bytes.ptr) ..][0..table.len];
    const normalized = [_]i16{16384};
    // major version, axis count, glyph count, shared tuple offset past the table
    const Field = struct { at: usize, value: u32, size: u8 };
    for ([_]Field{
        .{ .at = 0, .value = 2, .size = 2 },
        .{ .at = 4, .value = 2, .size = 2 },
        .{ .at = 12, .value = face.num_glyphs - 1, .size = 2 },
        .{ .at = 8, .value = @intCast(table.len), .size = 4 },
    }) |f| {
        var saved: [4]u8 = undefined;
        @memcpy(saved[0..f.size], gvar[f.at..][0..f.size]);
        if (f.size == 2) std.mem.writeInt(u16, gvar[f.at..][0..2], @intCast(f.value), .big) else std.mem.writeInt(u32, gvar[f.at..][0..4], f.value, .big);
        // gid 3 is "!", a simple glyph with variation data.
        try std.testing.expectError(error.InvalidFont, subsetInstance(gpa, face, &.{3}, &normalized, null));
        @memcpy(gvar[f.at..][0..f.size], saved[0..f.size]);
    }
    const ok = try subsetInstance(gpa, face, &.{3}, &normalized, null);
    gpa.free(ok.bytes);
}

test "instancing stops with InvalidFont when the work budget runs out" {
    // The budget (work_per_byte per byte of glyf + gvar) is what bounds a
    // hostile gvar; here it is armed with a tiny allowance on a real glyph.
    const gpa = std.testing.allocator;
    var font = try loadInstance(gpa, oracleFontPath("mada"), "wght=1000");
    defer font.deinit();
    const face = try sfnt.open(font.bytes, 0);
    const gvar = try Gvar.init((try sfnt.faceTable(face, "gvar")).?, 1, face.num_glyphs);
    const fvar = (try sfnt.faceTable(face, "fvar")).?;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const inst: Instance = .{ .coords = font.normalized, .tag_order = try axisTagOrder(arena.allocator(), fvar, 1) };
    var plenty: u64 = 1 << 30;
    const ig = try instanceGlyph(arena.allocator(), face, &gvar, inst, 3, &plenty);
    try std.testing.expect(ig.glyph.points.len > 4);
    var tiny: u64 = 8;
    try std.testing.expectError(error.InvalidFont, instanceGlyph(arena.allocator(), face, &gvar, inst, 3, &tiny));
}

test "axisScalar follows the OpenType interpolation algorithm" {
    // Values are F2Dot14. Without a region the implied one is
    // [min(0, peak), max(0, peak)].
    try std.testing.expectEqual(@as(f64, 1), axisScalar(8192, 0, null));
    try std.testing.expectEqual(@as(f64, 1), axisScalar(16384, 16384, null));
    try std.testing.expectEqual(@as(f64, 0.5), axisScalar(8192, 16384, null));
    try std.testing.expectEqual(@as(f64, 0.25), axisScalar(-4096, -16384, null));
    try std.testing.expectEqual(@as(f64, 0), axisScalar(0, 16384, null));
    try std.testing.expectEqual(@as(f64, 0), axisScalar(-8192, 16384, null));
    try std.testing.expectEqual(@as(f64, 0), axisScalar(16384, 8192, null));
    // An intermediate region [4096, 8192, 16384].
    try std.testing.expectEqual(@as(f64, 0.5), axisScalar(6144, 8192, .{ 4096, 16384 }));
    try std.testing.expectEqual(@as(f64, 0.5), axisScalar(12288, 8192, .{ 4096, 16384 }));
    try std.testing.expectEqual(@as(f64, 0), axisScalar(4096, 8192, .{ 4096, 16384 }));
    try std.testing.expectEqual(@as(f64, 0), axisScalar(2048, 8192, .{ 4096, 16384 }));
    try std.testing.expectEqual(@as(f64, 1), axisScalar(8192, 8192, .{ 8192, 8192 }));
    // A region that does not hold its peak, or that crosses 0, leaves the
    // axis out (scalar 1), as the spec and HarfBuzz say.
    try std.testing.expectEqual(@as(f64, 1), axisScalar(6144, 8192, .{ 12288, 16384 }));
    try std.testing.expectEqual(@as(f64, 1), axisScalar(6144, 8192, .{ 0, 4096 }));
    try std.testing.expectEqual(@as(f64, 1), axisScalar(6144, 8192, .{ -4096, 16384 }));
}

test "readPoints decodes packed point numbers, and refuses bad ones" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var work: u64 = 1 << 20;
    // 0: all points.
    var r: Reader = .{ .bytes = &.{0} };
    try std.testing.expectEqual(@as(?[]const u32, null), try readPoints(arena.allocator(), &r, 10, &work));
    // 3 points in one byte run: 1, +2, +3 = 1, 3, 6.
    r = .{ .bytes = &.{ 3, 0x02, 1, 2, 3 } };
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 6 }, (try readPoints(arena.allocator(), &r, 10, &work)).?);
    try std.testing.expectEqual(@as(usize, 5), r.pos);
    // A count in two bytes (0x80 | high, low), then a run of 2 words and a run
    // of 1 byte: 300, +400, +5 = 300, 700, 705.
    r = .{ .bytes = &.{ 0x80, 3, 0x81, 0x01, 0x2C, 0x01, 0x90, 0x00, 5 } };
    try std.testing.expectEqualSlices(u32, &.{ 300, 700, 705 }, (try readPoints(arena.allocator(), &r, 800, &work)).?);
    // A byte run of 65 (control 0x40): bit 6 is part of the count.
    var long: [67]u8 = undefined;
    long[0] = 65;
    long[1] = 0x40;
    @memset(long[2..], 1);
    r = .{ .bytes = &long };
    const p = (try readPoints(arena.allocator(), &r, 100, &work)).?;
    try std.testing.expectEqual(@as(usize, 65), p.len);
    try std.testing.expectEqual(@as(u32, 65), p[64]);
    // Refused: a repeated point, a point past the glyph, a run past the count.
    r = .{ .bytes = &.{ 2, 0x01, 1, 0 } };
    try std.testing.expectError(error.InvalidFont, readPoints(arena.allocator(), &r, 10, &work));
    r = .{ .bytes = &.{ 1, 0x00, 10 } };
    try std.testing.expectError(error.InvalidFont, readPoints(arena.allocator(), &r, 10, &work));
    r = .{ .bytes = &.{ 1, 0x01, 1, 2 } };
    try std.testing.expectError(error.InvalidFont, readPoints(arena.allocator(), &r, 10, &work));
}

test "readDeltas decodes packed deltas, and refuses a run past the count" {
    var out: [9]i32 = undefined;
    // 2 signed bytes, 3 zeros, 2 words, 2 longs.
    var r: Reader = .{ .bytes = &.{ 0x01, 0xFF, 0x05, 0x82, 0x41, 0x80, 0x00, 0x7F, 0xFF, 0xC1, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFE } };
    try readDeltas(&r, &out);
    try std.testing.expectEqualSlices(i32, &.{ -1, 5, 0, 0, 0, -32768, 32767, 65536, -2 }, &out);
    try std.testing.expectEqual(r.bytes.len, r.pos);
    var two: [2]i32 = undefined;
    r = .{ .bytes = &.{ 0x82, 0, 0, 0 } };
    try std.testing.expectError(error.InvalidFont, readDeltas(&r, &two));
}

test "drawContours follows fontTools' glyf draw" {
    const gpa = std.testing.allocator;
    const on = flag_on_curve;
    const P = struct {
        fn p(x: f64, y: f64) Point {
            return .{ .x = x, .y = y };
        }
    }.p;
    var out = ManagedList(PathCommand).init(gpa);
    defer out.deinit();
    // Contour 1 starts off-curve: it is rotated to end at its first on-curve
    // point (0,0), with two off-curve points split at their midpoint.
    // Contour 2 is all lines; the line back to the start is left to close.
    // Contour 3 has no on-curve point. Contour 4 is one point.
    const points = [_]Point{
        P(10, 20), P(0, 0),   P(20, 0),  P(30, 10),
        P(0, 50),  P(10, 50), P(10, 60), P(4, 0),
        P(8, 4),   P(4, 8),   P(0, 4),   P(7, 7),
    };
    const flags = [_]u8{ 0, on, 0, 0, on, on, on, 0, 0, 0, 0, on };
    try drawContours(&out, &points, &flags, &.{ 3, 6, 10, 11 });
    const want = [_]PathCommand{
        .{ .move = P(0, 0) },
        .{ .quad = .{ .control = P(20, 0), .to = P(25, 5) } },
        .{ .quad = .{ .control = P(30, 10), .to = P(20, 15) } },
        .{ .quad = .{ .control = P(10, 20), .to = P(0, 0) } },
        .close,
        .{ .move = P(0, 50) },
        .{ .line = P(10, 50) },
        .{ .line = P(10, 60) },
        .close,
        .{ .move = P(2, 2) },
        .{ .quad = .{ .control = P(4, 0), .to = P(6, 2) } },
        .{ .quad = .{ .control = P(8, 4), .to = P(6, 6) } },
        .{ .quad = .{ .control = P(4, 8), .to = P(2, 6) } },
        .{ .quad = .{ .control = P(0, 4), .to = P(2, 2) } },
        .close,
        .{ .move = P(7, 7) },
        .close,
    };
    try std.testing.expectEqualSlices(PathCommand, &want, out.items);

    out.clearRetainingCapacity();
    try std.testing.expectError(error.UnsupportedFontFormat, drawContours(&out, &.{ P(0, 0), P(1, 1), P(2, 0) }, &.{ on, flag_cubic, on }, &.{2}));
    try std.testing.expectError(error.InvalidFont, drawContours(&out, &.{P(0, 0)}, &.{on}, &.{1}));
}

test "Outlines: CFF is refused at init, a bad gid and a spent budget are InvalidFont, a space is empty" {
    const gpa = std.testing.allocator;
    var cff = try loadInstance(gpa, oracleFontPath("cff"), "");
    defer cff.deinit();
    try std.testing.expectError(error.UnsupportedFontFormat, cff.outlines(gpa));

    var font = try loadInstance(gpa, oracleFontPath("roboto_flex"), "wght=900");
    defer font.deinit();
    var outlines = try font.outlines(gpa);
    defer outlines.deinit();
    try std.testing.expectError(error.InvalidFont, outlines.path(gpa, outlines.face.num_glyphs));
    // gid 3 is "space" in Roboto Flex: no contours.
    const space = try outlines.path(gpa, 3);
    defer gpa.free(space);
    try std.testing.expectEqual(0, space.len);

    // A budget too small for one glyph's deltas stops the glyph, and the
    // glyphs it did not reach stay uncached, so a later call fails the same way.
    outlines.work_budget = 10;
    try std.testing.expectError(error.InvalidFont, outlines.path(gpa, 36));
    try std.testing.expectError(error.InvalidFont, outlines.path(gpa, 36));

    // Static Roboto has no gvar, so placing points is all the work there is:
    // "colon" (gid 30) is two components, 20 points in all.
    var static = try loadInstance(gpa, oracleFontPath("roboto"), "");
    defer static.deinit();
    var plain = try static.outlines(gpa);
    defer plain.deinit();
    plain.work_budget = 19;
    try std.testing.expectError(error.InvalidFont, plain.path(gpa, 30));
    plain.work_budget = 40;
    const colon = try plain.path(gpa, 30);
    defer gpa.free(colon);
    try std.testing.expect(colon.len > 0);
}

/// A glyph source for flatten tests: glyph i is `glyphs[i]`.
const TestGlyphs = struct {
    glyphs: []const Glyph,

    fn glyphAt(self: *const TestGlyphs, gid: u16) !*const Glyph {
        return if (gid < self.glyphs.len) &self.glyphs[gid] else error.InvalidFont;
    }
};

test "flatten charges every component visited, so a tree of empty glyphs stops" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Glyph 0 is the leaf; glyph k (1..10) is 32 references to glyph k-1.
    // 32^10 visits, and with an empty leaf not one point is placed.
    const fan = struct {
        fn build(a: std.mem.Allocator, leaf: Glyph, levels: usize, width: usize) ![]Glyph {
            const gs = try a.alloc(Glyph, levels + 1);
            gs[0] = leaf;
            for (1..levels + 1) |k| {
                const comps = try a.alloc(Component, width);
                for (comps) |*c| c.* = .{ .flags = args_are_xy, .gid = @intCast(k - 1), .arg1 = 0, .arg2 = 0 };
                gs[k] = .{ .kind = .composite, .components = comps };
            }
            return gs;
        }
    }.build;
    // The charge is exact: 2 levels of 3 over a one-point leaf visit 3 + 9
    // components and place 9 points. Checked first, so a missing charge fails
    // here at once instead of walking the large tree below.
    var point = [_]Point{.{ .x = 1, .y = 2 }};
    var flag = [_]u8{flag_on_curve};
    var end = [_]u16{0};
    const small: TestGlyphs = .{ .glyphs = try fan(arena, .{ .kind = .simple, .points = &point, .flags = &flag, .ends = &end }, 2, 3) };
    var flat2: Flat = .init(arena, true);
    var work2: u64 = 1000;
    try flatten(&small, 2, &flat2, &work2);
    try std.testing.expectEqual(@as(u64, 1000 - 12 - 9), work2);
    try std.testing.expectEqual(@as(usize, 9), flat2.points.items.len);
    try std.testing.expectEqual(@as(usize, 9), flat2.ends.items.len);

    const empty_tree: TestGlyphs = .{ .glyphs = try fan(arena, .{ .kind = .empty }, 10, 32) };
    var flat: Flat = .init(arena, true);
    var work: u64 = 100_000;
    try std.testing.expectError(error.InvalidFont, flatten(&empty_tree, 10, &flat, &work));
}

test "Outlines: a glyph that keeps failing leaves nothing in the long-lived arena" {
    const gpa = std.testing.allocator;
    var font = try loadInstance(gpa, oracleFontPath("roboto_flex"), "wght=900");
    defer font.deinit();
    var outlines = try font.outlines(gpa);
    defer outlines.deinit();
    outlines.work_budget = 10;
    try std.testing.expectError(error.InvalidFont, outlines.path(gpa, 36));
    const capacity = outlines.arena_state.queryCapacity();
    for (0..50) |_| try std.testing.expectError(error.InvalidFont, outlines.path(gpa, 36));
    try std.testing.expectEqual(capacity, outlines.arena_state.queryCapacity());
}
