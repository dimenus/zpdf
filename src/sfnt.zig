//! TrueType (glyf/loca) subsetter. Glyph ids are kept; unused glyphs become
//! empty loca entries. A font is untrusted input: every read is bounds-checked.

const std = @import("std");
const ManagedList = std.array_list.Managed;

pub const max_component_depth: u32 = 16;

const Tag = [4]u8;

pub const Table = struct {
    offset: u32,
    length: u32,
};

pub const Face = struct {
    bytes: []const u8,
    directory_offset: usize,
    units_per_em: u16,
    num_glyphs: u16,
    number_of_h_metrics: u16,
    loca_format: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    ascent: i16,
    descent: i16,
    italic_angle_f16dot16: i32,
    cap_height: i16,
    postscript_name: [63]u8,
    postscript_name_len: u8,
    head: Table,
    hhea: Table,
    maxp: Table,
    hmtx: Table,
    loca: Table,
    glyf: Table,
    cvt: ?Table,
    fpgm: ?Table,
    prep: ?Table,

    pub fn postscriptName(self: *const Face) []const u8 {
        return self.postscript_name[0..self.postscript_name_len];
    }

    pub fn italicAngle(self: Face) f64 {
        return @as(f64, @floatFromInt(self.italic_angle_f16dot16)) / 65536.0;
    }

    pub fn toThousandths(self: Face, font_units: i32) i32 {
        return unitsToThousandths(font_units, self.units_per_em);
    }
};

pub fn unitsToThousandths(font_units: i32, units_per_em: u16) i32 {
    const n = @as(i64, font_units) * 1000;
    const d: i64 = units_per_em;
    if (n >= 0) {
        return @intCast(@divTrunc(n + @divTrunc(d, 2), d));
    } else {
        return @intCast(@divTrunc(n - @divTrunc(d, 2), d));
    }
}

pub fn open(bytes: []const u8, index: i32) !Face {
    const dir_off = try directoryOffset(bytes, index);
    const num_tables = try readU16(bytes, try add(dir_off, 4));
    if (num_tables == 0) return error.InvalidFont;

    var head: ?Table = null;
    var hhea: ?Table = null;
    var maxp: ?Table = null;
    var hmtx: ?Table = null;
    var loca: ?Table = null;
    var glyf: ?Table = null;
    var cvt: ?Table = null;
    var fpgm: ?Table = null;
    var prep: ?Table = null;
    var name_tbl: ?Table = null;
    var post: ?Table = null;
    var os2: ?Table = null;
    var has_cff = false;
    var has_cff2 = false;

    var i: u16 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = try add(dir_off, try add(12, @as(usize, i) * 16));
        const tag = try readTag(bytes, rec);
        const offset = try readU32(bytes, try add(rec, 8));
        const length = try readU32(bytes, try add(rec, 12));
        try checkTable(bytes, offset, length);
        const table = Table{ .offset = offset, .length = length };
        if (std.mem.eql(u8, &tag, "head")) head = table;
        if (std.mem.eql(u8, &tag, "hhea")) hhea = table;
        if (std.mem.eql(u8, &tag, "maxp")) maxp = table;
        if (std.mem.eql(u8, &tag, "hmtx")) hmtx = table;
        if (std.mem.eql(u8, &tag, "loca")) loca = table;
        if (std.mem.eql(u8, &tag, "glyf")) glyf = table;
        if (std.mem.eql(u8, &tag, "cvt ")) cvt = table;
        if (std.mem.eql(u8, &tag, "fpgm")) fpgm = table;
        if (std.mem.eql(u8, &tag, "prep")) prep = table;
        if (std.mem.eql(u8, &tag, "name")) name_tbl = table;
        if (std.mem.eql(u8, &tag, "post")) post = table;
        if (std.mem.eql(u8, &tag, "OS/2")) os2 = table;
        if (std.mem.eql(u8, &tag, "CFF ")) has_cff = true;
        if (std.mem.eql(u8, &tag, "CFF2")) has_cff2 = true;
    }

    if (glyf == null and (has_cff or has_cff2)) return error.UnsupportedFontFormat;
    const head_t = head orelse return error.InvalidFont;
    const hhea_t = hhea orelse return error.InvalidFont;
    const maxp_t = maxp orelse return error.InvalidFont;
    const hmtx_t = hmtx orelse return error.InvalidFont;
    const loca_t = loca orelse return error.InvalidFont;
    const glyf_t = glyf orelse return error.InvalidFont;

    if (head_t.length < 54) return error.InvalidFont;
    if (hhea_t.length < 36) return error.InvalidFont;
    if (maxp_t.length < 6) return error.InvalidFont;

    const units_per_em = try readU16(bytes, try add(head_t.offset, 18));
    if (units_per_em == 0) return error.InvalidFont;
    const x_min = try readI16(bytes, try add(head_t.offset, 36));
    const y_min = try readI16(bytes, try add(head_t.offset, 38));
    const x_max = try readI16(bytes, try add(head_t.offset, 40));
    const y_max = try readI16(bytes, try add(head_t.offset, 42));
    const loca_format = try readI16(bytes, try add(head_t.offset, 50));
    if (loca_format != 0 and loca_format != 1) return error.InvalidFont;

    const ascent = try readI16(bytes, try add(hhea_t.offset, 4));
    const descent = try readI16(bytes, try add(hhea_t.offset, 6));
    const number_of_h_metrics = try readU16(bytes, try add(hhea_t.offset, 34));
    const num_glyphs = try readU16(bytes, try add(maxp_t.offset, 4));
    if (num_glyphs == 0) return error.InvalidFont;
    if (number_of_h_metrics == 0 or number_of_h_metrics > num_glyphs) return error.InvalidFont;

    const loca_entries = @as(u32, num_glyphs) + 1;
    const loca_need: u32 = if (loca_format == 0) loca_entries * 2 else loca_entries * 4;
    if (loca_t.length < loca_need) return error.InvalidFont;

    const hmtx_need = @as(u32, number_of_h_metrics) * 4 +
        (@as(u32, num_glyphs) - number_of_h_metrics) * 2;
    if (hmtx_t.length < hmtx_need) return error.InvalidFont;

    try validateLoca(bytes, loca_t, glyf_t, num_glyphs, loca_format);

    var italic_angle_f16dot16: i32 = 0;
    if (post) |p| {
        if (p.length >= 8) {
            italic_angle_f16dot16 = try readI32(bytes, try add(p.offset, 4));
        }
    }

    var cap_height = ascent;
    if (os2) |t| {
        if (t.length >= 2) {
            const ver = try readU16(bytes, t.offset);
            if (ver >= 2 and t.length >= 90) {
                cap_height = try readI16(bytes, try add(t.offset, 88));
            }
        }
    }

    var face: Face = .{
        .bytes = bytes,
        .directory_offset = dir_off,
        .units_per_em = units_per_em,
        .num_glyphs = num_glyphs,
        .number_of_h_metrics = number_of_h_metrics,
        .loca_format = loca_format,
        .x_min = x_min,
        .y_min = y_min,
        .x_max = x_max,
        .y_max = y_max,
        .ascent = ascent,
        .descent = descent,
        .italic_angle_f16dot16 = italic_angle_f16dot16,
        .cap_height = cap_height,
        .postscript_name = undefined,
        .postscript_name_len = 0,
        .head = head_t,
        .hhea = hhea_t,
        .maxp = maxp_t,
        .hmtx = hmtx_t,
        .loca = loca_t,
        .glyf = glyf_t,
        .cvt = cvt,
        .fpgm = fpgm,
        .prep = prep,
    };
    face.postscript_name = @splat(0);
    fillPostscriptName(&face, name_tbl);
    return face;
}

pub fn glyphAdvance(face: Face, gid: u16) !u16 {
    if (gid >= face.num_glyphs) return error.InvalidFont;
    const metric_index = @min(gid, face.number_of_h_metrics - 1);
    const off = try add(face.hmtx.offset, @as(usize, metric_index) * 4);
    return readU16(face.bytes, off);
}

/// The left side bearing hmtx gives `gid`.
pub fn glyphLsb(face: Face, gid: u16) !i16 {
    if (gid >= face.num_glyphs) return error.InvalidFont;
    const off = if (gid < face.number_of_h_metrics)
        @as(usize, gid) * 4 + 2
    else
        @as(usize, face.number_of_h_metrics) * 4 + (@as(usize, gid) - face.number_of_h_metrics) * 2;
    return readI16(face.bytes, try add(face.hmtx.offset, off));
}

pub fn glyphData(face: Face, gid: u16) ![]const u8 {
    if (gid >= face.num_glyphs) return error.InvalidFont;
    const start = try locaOffset(face, gid);
    const end = try locaOffset(face, gid + 1);
    if (end < start) return error.InvalidFont;
    const len = end - start;
    const abs = try add(face.glyf.offset, start);
    return sliceU(face.bytes, abs, len);
}

/// Subset `face` keeping glyph ids. `seed` is the caller-used set; GID 0 and
/// composite components are added. Returns owned sfnt bytes.
pub fn subset(gpa: std.mem.Allocator, face: Face, seed: []const u16) ![]u8 {
    var used = try collectUsed(gpa, face, seed);
    defer used.deinit();
    return writeSubset(gpa, face, &used);
}

/// Six uppercase letters from a hash of the sorted used glyph ids and the
/// instance's normalized coordinates. Two instances of one file draw the same
/// glyph ids with different widths and shapes, so the prefix tells their
/// subsets apart. Coordinates
/// that are all zero (the default instance, or a font with no axes) are not
/// hashed, so such a font keeps the prefix it had before variations existed.
pub fn subsetPrefix(used_sorted: []const u16, normalized: []const i16) [6]u8 {
    var hasher = std.hash.Wyhash.init(0);
    for (used_sorted) |gid| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, gid, .big);
        hasher.update(&b);
    }
    for (normalized) |coord| {
        if (coord != 0) break;
    } else {
        return prefixLetters(hasher.final());
    }
    hasher.update("instance");
    for (normalized) |coord| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, coord, .big);
        hasher.update(&b);
    }
    return prefixLetters(hasher.final());
}

fn prefixLetters(hash: u64) [6]u8 {
    var x = hash;
    var tag: [6]u8 = undefined;
    for (&tag) |*c| {
        c.* = 'A' + @as(u8, @intCast(x % 26));
        x /= 26;
    }
    return tag;
}

pub fn sortedUsedGids(gpa: std.mem.Allocator, used: *const std.DynamicBitSet) ![]u16 {
    var list = try ManagedList(u16).initCapacity(gpa, used.count());
    errdefer list.deinit();
    var gid: usize = 0;
    while (gid < used.capacity()) : (gid += 1) {
        if (used.isSet(gid)) {
            list.appendAssumeCapacity(@intCast(gid));
        }
    }
    return list.toOwnedSlice();
}

pub fn collectUsed(gpa: std.mem.Allocator, face: Face, seed: []const u16) !std.DynamicBitSet {
    var used = try std.DynamicBitSet.initEmpty(gpa, face.num_glyphs);
    errdefer used.deinit();
    used.set(0);
    for (seed) |gid| {
        if (gid >= face.num_glyphs) return error.InvalidFont;
        used.set(gid);
    }

    var visiting = try std.DynamicBitSet.initEmpty(gpa, face.num_glyphs);
    defer visiting.deinit();
    const height = try gpa.alloc(?u32, face.num_glyphs);
    defer gpa.free(height);
    @memset(height, null);

    var gid: u16 = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        if (!used.isSet(gid)) continue;
        _ = try walkComponents(face, gid, 0, &used, &visiting, height);
    }
    return used;
}

/// Returns the subtree height (hops to a simple glyph). A cached height
/// plus the current depth is enough to enforce the depth limit without
/// walking a shared subtree again.
fn walkComponents(
    face: Face,
    gid: u16,
    depth: u32,
    used: *std.DynamicBitSet,
    visiting: *std.DynamicBitSet,
    height: []?u32,
) !u32 {
    if (depth > max_component_depth) return error.InvalidFont;
    if (visiting.isSet(gid)) return error.InvalidFont;
    if (height[gid]) |h| {
        const leaf = std.math.add(u32, depth, h) catch return error.InvalidFont;
        if (leaf > max_component_depth) return error.InvalidFont;
        return h;
    }
    visiting.set(gid);
    defer visiting.unset(gid);

    const data = try glyphData(face, gid);
    if (data.len == 0) {
        height[gid] = 0;
        return 0;
    }
    if (data.len < 2) return error.InvalidFont;
    const contours = std.mem.readInt(i16, data[0..2], .big);
    if (contours >= 0) {
        height[gid] = 0;
        return 0;
    }
    if (data.len < 10) return error.InvalidFont;

    var pos: usize = 10;
    var max_h: u32 = 0;
    while (true) {
        const flags = try readU16(data, pos);
        const child = try readU16(data, try add(pos, 2));
        pos = try add(pos, 4);
        if (child >= face.num_glyphs) return error.InvalidFont;
        used.set(child);
        const child_h = try walkComponents(face, child, depth + 1, used, visiting, height);
        max_h = @max(max_h, child_h);

        if (flags & 0x0001 != 0) {
            pos = try add(pos, 4);
        } else {
            pos = try add(pos, 2);
        }
        if (flags & 0x0008 != 0) {
            pos = try add(pos, 2);
        } else if (flags & 0x0040 != 0) {
            pos = try add(pos, 4);
        } else if (flags & 0x0080 != 0) {
            pos = try add(pos, 8);
        }
        if (flags & 0x0020 == 0) break;
    }
    const h = max_h + 1;
    height[gid] = h;
    return h;
}

fn writeSubset(gpa: std.mem.Allocator, face: Face, used: *const std.DynamicBitSet) ![]u8 {
    var glyf_buf = ManagedList(u8).init(gpa);
    defer glyf_buf.deinit();
    var loca_buf = ManagedList(u8).init(gpa);
    defer loca_buf.deinit();

    var gid: u16 = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        try appendU32(&loca_buf, @intCast(glyf_buf.items.len));
        if (used.isSet(gid)) {
            const data = try glyphData(face, gid);
            try glyf_buf.appendSlice(data);
        }
    }
    try appendU32(&loca_buf, @intCast(glyf_buf.items.len));

    var head_bytes = try gpa.dupe(u8, try tableSlice(face.bytes, face.head));
    errdefer gpa.free(head_bytes);
    if (head_bytes.len < 54) return error.InvalidFont;
    std.mem.writeInt(u32, head_bytes[8..12], 0, .big);
    std.mem.writeInt(i16, head_bytes[50..52], 1, .big);

    const hhea_bytes = try tableSlice(face.bytes, face.hhea);
    const maxp_bytes = try tableSlice(face.bytes, face.maxp);
    const hmtx_bytes = try tableSlice(face.bytes, face.hmtx);

    var tables: [9]OutTable = undefined;
    var n: usize = 0;
    tables[n] = .{ .tag = "glyf".*, .bytes = glyf_buf.items };
    n += 1;
    tables[n] = .{ .tag = "head".*, .bytes = head_bytes };
    n += 1;
    tables[n] = .{ .tag = "hhea".*, .bytes = hhea_bytes };
    n += 1;
    tables[n] = .{ .tag = "hmtx".*, .bytes = hmtx_bytes };
    n += 1;
    tables[n] = .{ .tag = "loca".*, .bytes = loca_buf.items };
    n += 1;
    tables[n] = .{ .tag = "maxp".*, .bytes = maxp_bytes };
    n += 1;
    if (face.cvt) |t| {
        tables[n] = .{ .tag = "cvt ".*, .bytes = try tableSlice(face.bytes, t) };
        n += 1;
    }
    if (face.fpgm) |t| {
        tables[n] = .{ .tag = "fpgm".*, .bytes = try tableSlice(face.bytes, t) };
        n += 1;
    }
    if (face.prep) |t| {
        tables[n] = .{ .tag = "prep".*, .bytes = try tableSlice(face.bytes, t) };
        n += 1;
    }

    const font = try assemble(gpa, tables[0..n]);
    gpa.free(head_bytes);
    head_bytes = &.{};
    return font;
}

/// Writes an sfnt holding `tables`: sorts them by tag, writes the table
/// directory with each table's checksum, pads every table to 4 bytes, and sets
/// head's checkSumAdjustment. `tables` must hold a head table whose
/// checkSumAdjustment is 0. Returns owned bytes.
pub fn assemble(gpa: std.mem.Allocator, tables: []OutTable) ![]u8 {
    if (tables.len > 32) return error.InvalidFont;
    const out_tables = tables;
    std.sort.pdq(OutTable, out_tables, {}, outTableLess);

    const num_tables: u16 = @intCast(out_tables.len);
    const params = searchParams(num_tables);
    const header_len: usize = 12 + @as(usize, num_tables) * 16;

    var offsets: [32]u32 = undefined;
    var cursor: u32 = @intCast(header_len);
    for (out_tables, 0..) |tbl, i| {
        offsets[i] = cursor;
        const padded = std.mem.alignForward(u32, @intCast(tbl.bytes.len), 4);
        cursor = try add32(cursor, padded);
    }

    var out = try ManagedList(u8).initCapacity(gpa, cursor);
    errdefer out.deinit();
    try appendU32(&out, 0x00010000);
    try appendU16(&out, num_tables);
    try appendU16(&out, params.search_range);
    try appendU16(&out, params.entry_selector);
    try appendU16(&out, params.range_shift);

    for (out_tables, 0..) |tbl, i| {
        try out.appendSlice(&tbl.tag);
        try appendU32(&out, checksum(tbl.bytes));
        try appendU32(&out, offsets[i]);
        try appendU32(&out, @intCast(tbl.bytes.len));
    }

    for (out_tables) |tbl| {
        try out.appendSlice(tbl.bytes);
        const pad = std.mem.alignForward(usize, tbl.bytes.len, 4) - tbl.bytes.len;
        var p: usize = 0;
        while (p < pad) : (p += 1) {
            try out.append(0);
        }
    }

    const font = try out.toOwnedSlice();
    errdefer gpa.free(font);
    const head_off = blk: {
        for (out_tables, 0..) |tbl, i| {
            if (std.mem.eql(u8, &tbl.tag, "head")) break :blk offsets[i];
        }
        return error.InvalidFont;
    };
    const adj_at = try add(head_off, 8);
    if (adj_at + 4 > font.len) return error.InvalidFont;
    const whole = checksum(font);
    const adj = @as(u32, 0xB1B0AFBA) -% whole;
    std.mem.writeInt(u32, font[adj_at..][0..4], adj, .big);
    return font;
}

pub const OutTable = struct {
    tag: Tag,
    bytes: []const u8,
};

fn outTableLess(_: void, a: OutTable, b: OutTable) bool {
    return std.mem.lessThan(u8, &a.tag, &b.tag);
}

fn searchParams(num_tables: u16) struct { search_range: u16, entry_selector: u16, range_shift: u16 } {
    var pow: u16 = 1;
    var n: u16 = 0;
    while (pow * 2 <= num_tables) {
        pow *= 2;
        n += 1;
    }
    const search_range = pow * 16;
    return .{
        .search_range = search_range,
        .entry_selector = n,
        .range_shift = num_tables * 16 - search_range,
    };
}

pub fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        sum +%= std.mem.readInt(u32, bytes[i..][0..4], .big);
    }
    if (i < bytes.len) {
        var pad = [_]u8{ 0, 0, 0, 0 };
        @memcpy(pad[0 .. bytes.len - i], bytes[i..]);
        sum +%= std.mem.readInt(u32, &pad, .big);
    }
    return sum;
}

/// The table `tag` of face `index`, or null when the face has none. Reads only
/// the table directory, so it works on fonts that `open` refuses (CFF).
pub fn findTable(bytes: []const u8, index: i32, tag: *const Tag) !?Table {
    return findTableAt(bytes, try directoryOffset(bytes, index), tag);
}

/// The bytes of `face`'s table `tag`, or null when the face has none.
pub fn faceTable(face: Face, tag: *const Tag) !?[]const u8 {
    const table = try findTableAt(face.bytes, face.directory_offset, tag) orelse return null;
    return try tableSlice(face.bytes, table);
}

fn findTableAt(bytes: []const u8, dir_off: usize, tag: *const Tag) !?Table {
    const num_tables = try readU16(bytes, try add(dir_off, 4));
    var i: u16 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = try add(dir_off, try add(12, @as(usize, i) * 16));
        const rec_tag = try readTag(bytes, rec);
        if (!std.mem.eql(u8, &rec_tag, tag)) continue;
        const offset = try readU32(bytes, try add(rec, 8));
        const length = try readU32(bytes, try add(rec, 12));
        try checkTable(bytes, offset, length);
        return .{ .offset = offset, .length = length };
    }
    return null;
}

/// head's unitsPerEm for face `index`. Reads only head, so it works on fonts
/// that `open` refuses (CFF), as `open` reads it for the rest.
pub fn unitsPerEm(bytes: []const u8, index: i32) !u16 {
    const head = try findTable(bytes, index, "head") orelse return error.InvalidFont;
    if (head.length < 54) return error.InvalidFont;
    const upem = try readU16(bytes, try add(head.offset, 18));
    if (upem == 0) return error.InvalidFont;
    return upem;
}

/// The major version of face `index`'s avar table, or null when it has none.
pub fn avarMajorVersion(bytes: []const u8, index: i32) !?u16 {
    const avar = try findTable(bytes, index, "avar") orelse return null;
    if (avar.length < 4) return error.InvalidFont;
    return try readU16(bytes, avar.offset);
}

pub fn directoryOffset(bytes: []const u8, index: i32) !usize {
    if (bytes.len < 4) return error.InvalidFont;
    const tag = bytes[0..4];
    if (isSingleSfnt(tag)) {
        if (index != 0) return error.InvalidFont;
        if (bytes.len < 12) return error.InvalidFont;
        return 0;
    }
    if (!std.mem.eql(u8, tag, "ttcf")) return error.InvalidFont;
    if (bytes.len < 12) return error.InvalidFont;
    const num_fonts = try readU32(bytes, 8);
    if (index < 0) return error.InvalidFont;
    const idx: u32 = @intCast(index);
    if (idx >= num_fonts) return error.InvalidFont;
    const list_bytes = try mul32(num_fonts, 4);
    const list_end = try add32(12, list_bytes);
    if (list_end > bytes.len) return error.InvalidFont;
    const off = try readU32(bytes, 12 + 4 * @as(usize, idx));
    if (off > bytes.len) return error.InvalidFont;
    if (bytes.len - off < 12) return error.InvalidFont;
    if (!isSingleSfnt(bytes[off..][0..4])) return error.InvalidFont;
    return off;
}

fn isSingleSfnt(tag: *const [4]u8) bool {
    if (std.mem.eql(u8, tag, &.{ 0x00, 0x01, 0x00, 0x00 })) return true;
    if (std.mem.eql(u8, tag, "OTTO")) return true;
    if (std.mem.eql(u8, tag, "true")) return true;
    return false;
}

fn validateLoca(bytes: []const u8, loca: Table, glyf: Table, num_glyphs: u16, loca_format: i16) !void {
    var prev: u32 = 0;
    var i: u32 = 0;
    while (i <= num_glyphs) : (i += 1) {
        const off = if (loca_format == 0)
            @as(u32, try readU16(bytes, try add(loca.offset, i * 2))) * 2
        else
            try readU32(bytes, try add(loca.offset, i * 4));
        if (off < prev) return error.InvalidFont;
        if (off > glyf.length) return error.InvalidFont;
        prev = off;
    }
}

fn locaOffset(face: Face, gid: u32) !u32 {
    if (gid > face.num_glyphs) return error.InvalidFont;
    if (face.loca_format == 0) {
        const half = try readU16(face.bytes, try add(face.loca.offset, gid * 2));
        return @as(u32, half) * 2;
    }
    return readU32(face.bytes, try add(face.loca.offset, gid * 4));
}

fn isPdfNameByte(c: u8) bool {
    if (c < 0x21 or c > 0x7E) return false;
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%', '#' => false,
        else => true,
    };
}

fn appendPdfNameByte(out: *[63]u8, len: *u8, c: u8) void {
    if (!isPdfNameByte(c)) return;
    if (len.* == out.len) return;
    out[len.*] = c;
    len.* += 1;
}

fn decodeUtf16BeAscii(out: *[63]u8, bytes: []const u8) u8 {
    if (bytes.len % 2 != 0) return 0;
    var len: u8 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const unit = std.mem.readInt(u16, bytes[i..][0..2], .big);
        // Only ASCII is kept; a surrogate half is above 0x7F too, so a pair drops out unit by unit.
        if (unit > 0x7F) continue;
        appendPdfNameByte(out, &len, @intCast(unit));
    }
    return len;
}

fn fillPostscriptName(face: *Face, name_tbl: ?Table) void {
    const fallback = "zpdf";
    const names = readNameId6(face.bytes, name_tbl);
    var len: u8 = 0;
    if (names.utf16) |s| {
        len = decodeUtf16BeAscii(&face.postscript_name, s);
    }
    if (len == 0) {
        if (names.mac) |s| {
            for (s) |c| appendPdfNameByte(&face.postscript_name, &len, c);
        }
    }
    if (len == 0) {
        @memcpy(face.postscript_name[0..fallback.len], fallback);
        face.postscript_name_len = fallback.len;
        return;
    }
    face.postscript_name_len = len;
}

const NameId6 = struct {
    utf16: ?[]const u8 = null,
    mac: ?[]const u8 = null,
};

fn readNameId6(bytes: []const u8, name_tbl: ?Table) NameId6 {
    const tbl = name_tbl orelse return .{};
    if (tbl.length < 6) return .{};
    const table_end = add(tbl.offset, tbl.length) catch return .{};
    if (table_end > bytes.len) return .{};
    const count = readU16(bytes, add(tbl.offset, 2) catch return .{}) catch return .{};
    const string_off = readU16(bytes, add(tbl.offset, 4) catch return .{}) catch return .{};
    const recs = add(tbl.offset, 6) catch return .{};

    var out: NameId6 = .{};
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const rec = add(recs, @as(usize, i) * 12) catch continue;
        const rec_end = add(rec, 12) catch continue;
        if (rec_end > table_end) continue;
        const platform = readU16(bytes, rec) catch continue;
        const encoding = readU16(bytes, add(rec, 2) catch continue) catch continue;
        const name_id = readU16(bytes, add(rec, 6) catch continue) catch continue;
        if (name_id != 6) continue;
        const length = readU16(bytes, add(rec, 8) catch continue) catch continue;
        const off = readU16(bytes, add(rec, 10) catch continue) catch continue;
        const start = add(tbl.offset, @as(usize, string_off) + off) catch continue;
        const end = add(start, length) catch continue;
        if (start < tbl.offset or end > table_end) continue;
        const s = bytes[start..end];
        if (platform == 3 and encoding == 1) {
            if (out.utf16 == null) out.utf16 = s;
        } else if (platform == 1 and encoding == 0) {
            if (out.mac == null) out.mac = s;
        }
    }
    return out;
}

/// PDF names are at most 127 bytes (PDF 1.7, Annex C) and the subset prefix
/// takes 7 of them.
pub const max_instance_name = 120;

pub const InstanceName = struct {
    buf: [max_instance_name]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const InstanceName) []const u8 {
        return self.buf[0..self.len];
    }

    fn appendByte(self: *InstanceName, c: u8) void {
        if (self.len == self.buf.len) return;
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn appendAll(self: *InstanceName, s: []const u8) void {
        for (s) |c| self.appendByte(c);
    }
};

/// The PostScript name of an instance of `face`, by Adobe Technical Note 5902
/// ("Generating PostScript Names for Fonts Using OpenType Font Variations"):
/// - The family prefix is name ID 25 (Variations PostScript Name Prefix) when
///   the font has one, else name ID 16 (else name ID 1, which the note does
///   not cover) with everything but ASCII letters and digits removed.
/// - When the coordinates are those of an fvar named instance: that
///   instance's postScriptNameID string when it has one, else the prefix,
///   "-", and the instance's subfamily name with everything but ASCII letters
///   and digits removed.
/// - Otherwise the prefix, then for each axis in fvar order whose coordinate
///   is not the default: "_", the coordinate in the fewest decimals that turn
///   back into the same 16.16 value, and the axis tag without trailing spaces
///   ("AndreVar_900wght_5.5wdth").
/// - A name longer than max_instance_name (the note's limit is 127; the PDF
///   name limit leaves 120 after the subset prefix) is the note's last resort:
///   the prefix, "-", eight hex digits of a hash of the long name, and "...".
/// `coordinates` are the user coordinates per fvar axis (zpdf.Font.coordinates);
/// each is clamped to its axis range first, in 16.16, as kb clamps. Names use
/// US English records (Windows Unicode, then any Windows Unicode, then
/// Macintosh Roman). Only bytes a PDF name may hold unescaped are kept.
pub fn instancePostscriptName(face: Face, coordinates: []const f32) !InstanceName {
    const fvar = try faceTable(face, "fvar") orelse return error.InvalidFont;
    const name_tbl = try findTableAt(face.bytes, face.directory_offset, "name");
    const axes_offset = try readU16(fvar, 4);
    const axis_count = try readU16(fvar, 8);
    const axis_size = try readU16(fvar, 10);
    const instance_count = try readU16(fvar, 12);
    const instance_size = try readU16(fvar, 14);
    if (axis_count != coordinates.len or axis_size < 20) return error.InvalidFont;

    var prefix: InstanceName = .{};
    if (!readName(face.bytes, name_tbl, 25, &prefix, isPdfNameByte)) {
        if (!readName(face.bytes, name_tbl, 16, &prefix, std.ascii.isAlphanumeric)) {
            _ = readName(face.bytes, name_tbl, 1, &prefix, std.ascii.isAlphanumeric);
        }
    }
    if (prefix.len == 0) prefix.appendAll(face.postscriptName());

    var fixed_buf: [64]i32 = undefined;
    if (axis_count > fixed_buf.len) return error.InvalidFont;
    const fixed = fixed_buf[0..axis_count];
    var defaults_buf: [64]i32 = undefined;
    const defaults = defaults_buf[0..axis_count];
    for (fixed, defaults, coordinates, 0..) |*f, *d, c, i| {
        const rec = try add(axes_offset, i * axis_size);
        const minimum = try readI32(fvar, try add(rec, 4));
        d.* = try readI32(fvar, try add(rec, 8));
        const maximum = try readI32(fvar, try add(rec, 12));
        const scaled = @round(@as(f64, c) * 65536.0);
        const v: i64 = if (scaled < -2147483648.0) std.math.minInt(i32) else if (scaled > 2147483647.0) std.math.maxInt(i32) else @intFromFloat(scaled);
        f.* = @intCast(std.math.clamp(v, @min(minimum, maximum), @max(minimum, maximum)));
    }

    const instances_at = try add(axes_offset, @as(usize, axis_count) * axis_size);
    const coords_size = @as(usize, axis_count) * 4;
    if (instance_count != 0 and instance_size < coords_size + 4) return error.InvalidFont;
    var i: usize = 0;
    while (i < instance_count) : (i += 1) {
        const rec = try add(instances_at, i * instance_size);
        for (fixed, 0..) |f, a| {
            if (try readI32(fvar, try add(rec, 4 + a * 4)) != f) break;
        } else {
            var out: InstanceName = .{};
            if (instance_size >= coords_size + 6) {
                const ps_id = try readU16(fvar, try add(rec, 4 + coords_size));
                if (ps_id != 0xFFFF and readName(face.bytes, name_tbl, ps_id, &out, isPdfNameByte)) return out;
            }
            out = prefix;
            out.appendByte('-');
            const before = out.len;
            if (readName(face.bytes, name_tbl, try readU16(fvar, rec), &out, std.ascii.isAlphanumeric) and out.len > before and out.len < max_instance_name) return out;
            break;
        }
    }

    var long: [max_instance_name + 1]u8 = undefined;
    var long_len: usize = 0;
    var full = true;
    const put = struct {
        fn f(buf: []u8, len: *usize, ok: *bool, s: []const u8) void {
            for (s) |c| {
                if (len.* == buf.len) {
                    ok.* = false;
                    return;
                }
                buf[len.*] = c;
                len.* += 1;
            }
        }
    }.f;
    put(&long, &long_len, &full, prefix.slice());
    for (fixed, defaults, 0..) |f, d, a| {
        if (f == d) continue;
        put(&long, &long_len, &full, "_");
        var num_buf: [24]u8 = undefined;
        put(&long, &long_len, &full, formatFixed(&num_buf, f));
        const tag = try sliceU(fvar, try add(axes_offset, a * axis_size), 4);
        const tag_len = std.mem.trimEnd(u8, tag, " ").len;
        for (tag[0..tag_len]) |c| {
            if (isPdfNameByte(c)) put(&long, &long_len, &full, &.{c});
        }
    }
    if (full and long_len <= max_instance_name) {
        var out: InstanceName = .{};
        out.appendAll(long[0..long_len]);
        return out;
    }

    // The last resort. The hash covers every axis value, not only the part of
    // the long name that fit.
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(prefix.slice());
    for (fixed) |f| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, f, .big);
        hasher.update(&b);
    }
    var out: InstanceName = .{};
    out.appendAll(prefix.buf[0..@min(prefix.len, max_instance_name - 12)]);
    var hex_buf: [8]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{X:0>8}", .{@as(u32, @truncate(hasher.final()))}) catch unreachable;
    out.appendByte('-');
    out.appendAll(hex);
    out.appendAll("...");
    return out;
}

/// A 16.16 value in the fewest decimals (at most 5) that turn back into it,
/// with no trailing zeros, no "+" and no decimal point for a whole number.
fn formatFixed(buf: *[24]u8, fixed: i32) []const u8 {
    var decimals: u5 = 0;
    var q: i64 = 0;
    var pow: i64 = 1;
    while (decimals <= 5) : (decimals += 1) {
        q = divRound(@as(i64, fixed) * pow, 65536);
        if (divRound(q * 65536, pow) == fixed) break;
        pow *= 10;
    }
    const mag: u64 = @abs(q);
    const whole = mag / @as(u64, @intCast(pow));
    var frac = mag % @as(u64, @intCast(pow));
    var len = (std.fmt.bufPrint(buf, "{s}{d}", .{ if (q < 0) "-" else "", whole }) catch unreachable).len;
    if (frac != 0) {
        var digits: [5]u8 = undefined;
        var k: usize = decimals;
        while (k > 0) : (k -= 1) {
            digits[k - 1] = '0' + @as(u8, @intCast(frac % 10));
            frac /= 10;
        }
        var used: usize = decimals;
        while (used > 0 and digits[used - 1] == '0') used -= 1;
        buf[len] = '.';
        len += 1;
        @memcpy(buf[len..][0..used], digits[0..used]);
        len += used;
    }
    return buf[0..len];
}

/// n / d rounded half away from zero; d > 0.
fn divRound(n: i64, d: i64) i64 {
    const q = @divTrunc(n, d);
    const r = @rem(n, d);
    if (2 * @abs(r) >= d) return if (n < 0) q - 1 else q + 1;
    return q;
}

/// Appends name `name_id`, ASCII only and only the bytes `keep` accepts, to
/// `out`. Prefers a Windows Unicode record in US English, then any Windows
/// Unicode record, then a Macintosh Roman one. Returns whether a record was
/// found and gave at least one byte.
fn readName(bytes: []const u8, name_tbl: ?Table, name_id: u16, out: *InstanceName, keep: *const fn (u8) bool) bool {
    const tbl = name_tbl orelse return false;
    const table = tableSlice(bytes, tbl) catch return false;
    const count = readU16(table, 2) catch return false;
    const string_off = readU16(table, 4) catch return false;
    var best: ?[]const u8 = null;
    var best_rank: u8 = 0;
    var best_utf16 = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rec = 6 + i * 12;
        const rec_bytes = sliceU(table, rec, 12) catch break;
        const platform = std.mem.readInt(u16, rec_bytes[0..2], .big);
        const encoding = std.mem.readInt(u16, rec_bytes[2..4], .big);
        const language = std.mem.readInt(u16, rec_bytes[4..6], .big);
        if (std.mem.readInt(u16, rec_bytes[6..8], .big) != name_id) continue;
        const rank: u8 = if (platform == 3 and encoding == 1 and language == 0x409) 3 else if (platform == 3 and encoding == 1) 2 else if (platform == 1 and encoding == 0 and language == 0) 1 else 0;
        if (rank <= best_rank) continue;
        const length = std.mem.readInt(u16, rec_bytes[8..10], .big);
        const off = std.mem.readInt(u16, rec_bytes[10..12], .big);
        const s = sliceU(table, @as(usize, string_off) + off, length) catch continue;
        best = s;
        best_rank = rank;
        best_utf16 = platform == 3;
    }
    const s = best orelse return false;
    const before = out.len;
    if (best_utf16) {
        var k: usize = 0;
        while (k + 1 < s.len) : (k += 2) {
            const unit = std.mem.readInt(u16, s[k..][0..2], .big);
            if (unit < 0x80 and keep(@intCast(unit))) out.appendByte(@intCast(unit));
        }
    } else {
        for (s) |c| {
            if (c < 0x80 and keep(c)) out.appendByte(c);
        }
    }
    return out.len > before;
}

pub fn tableSlice(bytes: []const u8, table: Table) ![]const u8 {
    return sliceU(bytes, table.offset, table.length);
}

fn checkTable(bytes: []const u8, offset: u32, length: u32) !void {
    const end = try add32(offset, length);
    if (end > bytes.len) return error.InvalidFont;
}

fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidFont;
}

fn add32(a: u32, b: u32) !u32 {
    return std.math.add(u32, a, b) catch error.InvalidFont;
}

fn mul32(a: u32, b: u32) !u32 {
    return std.math.mul(u32, a, b) catch error.InvalidFont;
}

fn sliceU(bytes: []const u8, offset: usize, length: usize) ![]const u8 {
    const end = try add(offset, length);
    if (end > bytes.len) return error.InvalidFont;
    return bytes[offset..end];
}

fn readTag(bytes: []const u8, offset: usize) !Tag {
    const s = try sliceU(bytes, offset, 4);
    return s[0..4].*;
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    const s = try sliceU(bytes, offset, 2);
    return std.mem.readInt(u16, s[0..2], .big);
}

fn readI16(bytes: []const u8, offset: usize) !i16 {
    const s = try sliceU(bytes, offset, 2);
    return std.mem.readInt(i16, s[0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    const s = try sliceU(bytes, offset, 4);
    return std.mem.readInt(u32, s[0..4], .big);
}

fn readI32(bytes: []const u8, offset: usize) !i32 {
    const s = try sliceU(bytes, offset, 4);
    return std.mem.readInt(i32, s[0..4], .big);
}

fn appendU16(list: *ManagedList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try list.appendSlice(&b);
}

fn appendU32(list: *ManagedList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try list.appendSlice(&b);
}

fn loadTestFont(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
}

fn parseDir(bytes: []const u8) !struct { num_tables: u16, search_range: u16, entry_selector: u16, range_shift: u16 } {
    return .{
        .num_tables = try readU16(bytes, 4),
        .search_range = try readU16(bytes, 6),
        .entry_selector = try readU16(bytes, 8),
        .range_shift = try readU16(bytes, 10),
    };
}

const TestTable = struct {
    tag: Tag,
    checksum: u32,
    offset: u32,
    length: u32,
};

fn readTables(gpa: std.mem.Allocator, bytes: []const u8) ![]TestTable {
    const num = try readU16(bytes, 4);
    var list = try ManagedList(TestTable).initCapacity(gpa, num);
    errdefer list.deinit();
    var i: u16 = 0;
    while (i < num) : (i += 1) {
        const rec = 12 + @as(usize, i) * 16;
        list.appendAssumeCapacity(.{
            .tag = try readTag(bytes, rec),
            .checksum = try readU32(bytes, rec + 4),
            .offset = try readU32(bytes, rec + 8),
            .length = try readU32(bytes, rec + 12),
        });
    }
    return list.toOwnedSlice();
}

/// Independent of `checksum`: accumulate 32-bit big-endian words one byte at a time.
fn testChecksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        var word: u32 = 0;
        var k: u32 = 0;
        while (k < 4) : (k += 1) {
            word <<= 8;
            if (i < bytes.len) {
                word |= bytes[i];
                i += 1;
            }
        }
        sum +%= word;
    }
    return sum;
}

test "subset Roboto keeps used glyph bytes and checksums" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);

    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("Roboto-Regular", face.postscriptName());
    try std.testing.expect(face.cvt != null);
    try std.testing.expect(face.fpgm != null);
    try std.testing.expect(face.prep != null);

    const seed = [_]u16{ 11, 30, 68 }; // .notdef is added; 30 is composite of 18
    const out = try subset(std.testing.allocator, face, &seed);
    defer std.testing.allocator.free(out);

    const sub = try open(out, 0);
    try std.testing.expectEqual(face.num_glyphs, sub.num_glyphs);
    try std.testing.expectEqual(@as(i16, 1), sub.loca_format);

    var used = try collectUsed(std.testing.allocator, face, &seed);
    defer used.deinit();
    try std.testing.expect(used.isSet(0));
    try std.testing.expect(used.isSet(18));
    try std.testing.expect(used.isSet(30));

    var gid: u16 = 0;
    while (gid < face.num_glyphs) : (gid += 1) {
        const got = try glyphData(sub, gid);
        if (used.isSet(gid)) {
            const want = try glyphData(face, gid);
            try std.testing.expectEqualSlices(u8, want, got);
        } else {
            try std.testing.expectEqual(@as(usize, 0), got.len);
        }
    }

    const dir = try parseDir(out);
    const params = searchParams(dir.num_tables);
    try std.testing.expectEqual(params.search_range, dir.search_range);
    try std.testing.expectEqual(params.entry_selector, dir.entry_selector);
    try std.testing.expectEqual(params.range_shift, dir.range_shift);

    const tables = try readTables(std.testing.allocator, out);
    defer std.testing.allocator.free(tables);
    var prev: Tag = @splat(0);
    var has_head = false;
    for (tables) |t| {
        try std.testing.expect(std.mem.lessThan(u8, &prev, &t.tag));
        prev = t.tag;
        if (std.mem.eql(u8, &t.tag, "head")) {
            has_head = true;
            var head_copy = try std.testing.allocator.dupe(u8, try sliceU(out, t.offset, t.length));
            defer std.testing.allocator.free(head_copy);
            std.mem.writeInt(u32, head_copy[8..12], 0, .big);
            try std.testing.expectEqual(t.checksum, testChecksum(head_copy));
            const whole_adj = std.mem.readInt(u32, out[t.offset + 8 ..][0..4], .big);
            var zeroed = try std.testing.allocator.dupe(u8, out);
            defer std.testing.allocator.free(zeroed);
            std.mem.writeInt(u32, zeroed[t.offset + 8 ..][0..4], 0, .big);
            try std.testing.expectEqual(@as(u32, 0xB1B0AFBA) -% testChecksum(zeroed), whole_adj);
            try std.testing.expectEqual(@as(u32, 0xB1B0AFBA), testChecksum(out));
        } else {
            const slice = try sliceU(out, t.offset, t.length);
            try std.testing.expectEqual(t.checksum, testChecksum(slice));
        }
        try std.testing.expectEqual(@as(u32, 0), t.offset % 4);
    }
    try std.testing.expect(has_head);

    const sorted = try sortedUsedGids(std.testing.allocator, &used);
    defer std.testing.allocator.free(sorted);
    const tag = subsetPrefix(sorted, &.{});
    for (tag) |c| {
        try std.testing.expect(c >= 'A' and c <= 'Z');
    }
    try std.testing.expectEqual(tag, subsetPrefix(sorted, &.{}));
}

test "composite glyph pulls in its components" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);

    const seed = [_]u16{30};
    var used = try collectUsed(std.testing.allocator, face, &seed);
    defer used.deinit();
    try std.testing.expect(used.isSet(0));
    try std.testing.expect(used.isSet(30));
    try std.testing.expect(used.isSet(18));

    const orig_30 = try glyphData(face, 30);
    try std.testing.expect(orig_30.len >= 10);
    const contours = std.mem.readInt(i16, orig_30[0..2], .big);
    try std.testing.expect(contours < 0);
}

test "ttc face index works" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_ttc);
    defer std.testing.allocator.free(bytes);

    const face0 = try open(bytes, 0);
    const face1 = try open(bytes, 1);
    try std.testing.expect(face0.directory_offset != face1.directory_offset);
    try std.testing.expectEqual(face0.num_glyphs, face1.num_glyphs);

    const out0 = try subset(std.testing.allocator, face0, &.{});
    defer std.testing.allocator.free(out0);
    const out1 = try subset(std.testing.allocator, face1, &.{});
    defer std.testing.allocator.free(out1);

    const sub0 = try open(out0, 0);
    const sub1 = try open(out1, 0);
    try std.testing.expectEqual(face0.num_glyphs, sub0.num_glyphs);
    try std.testing.expectEqual(face1.num_glyphs, sub1.num_glyphs);
    try std.testing.expectEqualSlices(u8, try glyphData(face0, 0), try glyphData(sub0, 0));
    try std.testing.expectEqualSlices(u8, try glyphData(face1, 0), try glyphData(sub1, 0));

    try std.testing.expectError(error.InvalidFont, open(bytes, 2));
    try std.testing.expectError(error.InvalidFont, open(bytes, -1));
}

test "CFF without glyf is UnsupportedFontFormat" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_cff);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.UnsupportedFontFormat, open(bytes, 0));
}

test "truncated and junk fonts are InvalidFont" {
    try std.testing.expectError(error.InvalidFont, open("not_a_font", 0));
    try std.testing.expectError(error.InvalidFont, open("", 0));
    try std.testing.expectError(error.InvalidFont, open(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x01 }, 0));

    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.InvalidFont, open(bytes[0 .. bytes.len / 2], 0));
    try std.testing.expectError(error.InvalidFont, open(bytes, 1));

    var ttc = [_]u8{
        't',  't',  'c',  'f',
        0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x64,
    };
    try std.testing.expectError(error.InvalidFont, open(&ttc, 0));
}

test "Roboto metrics in 1/1000 em" {
    const options = @import("build_options");
    const bytes = try loadTestFont(options.test_font_roboto);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqual(@as(u16, 2048), face.units_per_em);
    try std.testing.expectEqual(unitsToThousandths(1900, 2048), face.toThousandths(face.ascent));
    try std.testing.expectEqual(unitsToThousandths(-500, 2048), face.toThousandths(face.descent));
    try std.testing.expectEqual(unitsToThousandths(1456, 2048), face.toThousandths(face.cap_height));
    try std.testing.expectEqual(@as(f64, 0), face.italicAngle());
}

const TestFonts = if (!@import("builtin").is_test) struct {} else struct {
    fn appendComposite(glyf: *ManagedList(u8), children: []const u16) !void {
        try appendU16(glyf, 0xFFFF);
        try appendU16(glyf, 0);
        try appendU16(glyf, 0);
        try appendU16(glyf, 0);
        try appendU16(glyf, 0);
        for (children, 0..) |child, i| {
            var flags: u16 = 0x0002;
            if (i + 1 < children.len) flags |= 0x0020;
            try appendU16(glyf, flags);
            try appendU16(glyf, child);
            try glyf.append(0);
            try glyf.append(0);
        }
    }

    /// `children[gid]` is the component list for that glyph; empty means an empty glyph.
    fn buildCompositeFont(gpa: std.mem.Allocator, children: []const []const u16) ![]u8 {
        return buildFont(gpa, children, null);
    }

    fn buildFont(gpa: std.mem.Allocator, children: []const []const u16, name_table: ?[]const u8) ![]u8 {
        const num: u16 = @intCast(children.len);
        var glyf = ManagedList(u8).init(gpa);
        defer glyf.deinit();
        var loca = ManagedList(u8).init(gpa);
        defer loca.deinit();
        for (children) |ch| {
            try appendU32(&loca, @intCast(glyf.items.len));
            if (ch.len != 0) try appendComposite(&glyf, ch);
        }
        try appendU32(&loca, @intCast(glyf.items.len));

        var head: [54]u8 = @splat(0);
        std.mem.writeInt(u32, head[0..4], 0x00010000, .big);
        std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
        std.mem.writeInt(u16, head[18..20], 1024, .big);
        std.mem.writeInt(i16, head[50..52], 1, .big);

        var hhea: [36]u8 = @splat(0);
        std.mem.writeInt(u16, hhea[34..36], num, .big);

        var maxp: [6]u8 = @splat(0);
        std.mem.writeInt(u16, maxp[0..2], 0x5000, .big);
        std.mem.writeInt(u16, maxp[4..6], num, .big);

        const hmtx = try gpa.alloc(u8, @as(usize, num) * 4);
        defer gpa.free(hmtx);
        @memset(hmtx, 0);

        const TableRec = struct { tag: Tag, bytes: []const u8 };
        var tables = ManagedList(TableRec).init(gpa);
        defer tables.deinit();
        try tables.appendSlice(&.{
            .{ .tag = "glyf".*, .bytes = glyf.items },
            .{ .tag = "head".*, .bytes = &head },
            .{ .tag = "hhea".*, .bytes = &hhea },
            .{ .tag = "hmtx".*, .bytes = hmtx },
            .{ .tag = "loca".*, .bytes = loca.items },
            .{ .tag = "maxp".*, .bytes = &maxp },
        });
        if (name_table) |nt| try tables.append(.{ .tag = "name".*, .bytes = nt });
        const less = struct {
            fn f(_: void, a: TableRec, b: TableRec) bool {
                return std.mem.lessThan(u8, &a.tag, &b.tag);
            }
        }.f;
        std.sort.pdq(TableRec, tables.items, {}, less);

        const num_tables: u16 = @intCast(tables.items.len);
        const params = searchParams(num_tables);
        const header_len: usize = 12 + @as(usize, num_tables) * 16;
        const offsets = try gpa.alloc(u32, tables.items.len);
        defer gpa.free(offsets);
        var cursor: u32 = @intCast(header_len);
        for (tables.items, 0..) |tbl, i| {
            offsets[i] = cursor;
            cursor = try add32(cursor, @intCast(std.mem.alignForward(usize, tbl.bytes.len, 4)));
        }

        var out = try ManagedList(u8).initCapacity(gpa, cursor);
        errdefer out.deinit();
        try appendU32(&out, 0x00010000);
        try appendU16(&out, num_tables);
        try appendU16(&out, params.search_range);
        try appendU16(&out, params.entry_selector);
        try appendU16(&out, params.range_shift);
        for (tables.items, 0..) |tbl, i| {
            try out.appendSlice(&tbl.tag);
            try appendU32(&out, checksum(tbl.bytes));
            try appendU32(&out, offsets[i]);
            try appendU32(&out, @intCast(tbl.bytes.len));
        }
        for (tables.items) |tbl| {
            try out.appendSlice(tbl.bytes);
            const pad = std.mem.alignForward(usize, tbl.bytes.len, 4) - tbl.bytes.len;
            var p: usize = 0;
            while (p < pad) : (p += 1) try out.append(0);
        }
        return out.toOwnedSlice();
    }
};

test "shared composite subtree is walked in linear time" {
    // 17 glyphs. GID 1..15 each have 8 component records pointing at gid+1.
    // A naive walk is 8^15 calls; this must finish immediately.
    var child_bufs: [17][8]u16 = undefined;
    var children: [17][]const u16 = undefined;
    children[0] = &.{};
    var gid: u16 = 1;
    while (gid <= 15) : (gid += 1) {
        var k: usize = 0;
        while (k < 8) : (k += 1) child_bufs[gid][k] = gid + 1;
        children[gid] = child_bufs[gid][0..8];
    }
    children[16] = &.{};

    const bytes = try TestFonts.buildCompositeFont(std.testing.allocator, &children);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqual(@as(u16, 17), face.num_glyphs);

    const seed = [_]u16{1};
    var used = try collectUsed(std.testing.allocator, face, &seed);
    defer used.deinit();
    try std.testing.expect(used.isSet(0));
    gid = 1;
    while (gid <= 16) : (gid += 1) {
        try std.testing.expect(used.isSet(gid));
    }
}

test "composite cycle is InvalidFont" {
    const a = [_]u16{2};
    const b = [_]u16{1};
    const children = [_][]const u16{ &.{}, &a, &b };
    const bytes = try TestFonts.buildCompositeFont(std.testing.allocator, &children);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectError(error.InvalidFont, collectUsed(std.testing.allocator, face, &.{1}));
}

test "composite chain of exactly 16 levels is valid" {
    var next: [17]u16 = undefined;
    var children: [18][]const u16 = undefined;
    children[0] = &.{};
    var gid: u16 = 1;
    while (gid <= 16) : (gid += 1) {
        next[gid] = gid + 1;
        children[gid] = next[gid .. gid + 1];
    }
    children[17] = &.{};
    const bytes = try TestFonts.buildCompositeFont(std.testing.allocator, &children);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    var used = try collectUsed(std.testing.allocator, face, &.{1});
    defer used.deinit();
    try std.testing.expect(used.isSet(1));
    try std.testing.expect(used.isSet(17));
}

test "shared subtree shallow then too-deep is InvalidFont" {
    // GID 2 is a chain of height 10. GID 1 reaches it first at depth 1, then
    // through a longer chain at depth 9, where 9+10 exceeds 16.
    var next: [21]u16 = undefined;
    var children: [21][]const u16 = undefined;
    const from_one = [_]u16{ 2, 13 };
    children[0] = &.{};
    children[1] = &from_one;
    var gid: u16 = 2;
    while (gid <= 11) : (gid += 1) {
        next[gid] = gid + 1;
        children[gid] = next[gid .. gid + 1];
    }
    children[12] = &.{};
    gid = 13;
    while (gid <= 19) : (gid += 1) {
        next[gid] = gid + 1;
        children[gid] = next[gid .. gid + 1];
    }
    next[20] = 2;
    children[20] = next[20..21];
    const bytes = try TestFonts.buildCompositeFont(std.testing.allocator, &children);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectError(error.InvalidFont, collectUsed(std.testing.allocator, face, &.{1}));
}

test "over-deep composite is InvalidFont" {
    // GID 1..17 each point at the next; GID 18 is empty. Depth 17 exceeds the limit of 16.
    var single: [18]u16 = undefined;
    var children: [19][]const u16 = undefined;
    children[0] = &.{};
    var gid: u16 = 1;
    while (gid <= 17) : (gid += 1) {
        single[gid] = gid + 1;
        children[gid] = single[gid .. gid + 1];
    }
    children[18] = &.{};
    const bytes = try TestFonts.buildCompositeFont(std.testing.allocator, &children);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectError(error.InvalidFont, collectUsed(std.testing.allocator, face, &.{1}));
}

test "UTF-16 PostScript name keeps printable ASCII only" {
    // name ID 6, platform 3 encoding 1: "Ab中" → "Ab"
    var name: [24]u8 = undefined;
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], 1, .big);
    std.mem.writeInt(u16, name[4..6], 18, .big);
    std.mem.writeInt(u16, name[6..8], 3, .big);
    std.mem.writeInt(u16, name[8..10], 1, .big);
    std.mem.writeInt(u16, name[10..12], 0x0409, .big);
    std.mem.writeInt(u16, name[12..14], 6, .big);
    std.mem.writeInt(u16, name[14..16], 6, .big);
    std.mem.writeInt(u16, name[16..18], 0, .big);
    name[18] = 0x00;
    name[19] = 'A';
    name[20] = 0x00;
    name[21] = 'b';
    name[22] = 0x4E;
    name[23] = 0x2D;
    const empty = [_][]const u16{&.{}};
    const bytes = try TestFonts.buildFont(std.testing.allocator, &empty, &name);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("Ab", face.postscriptName());
}

test "hash is stripped from a PostScript name" {
    var name: [23]u8 = undefined;
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], 1, .big);
    std.mem.writeInt(u16, name[4..6], 18, .big);
    std.mem.writeInt(u16, name[6..8], 1, .big);
    std.mem.writeInt(u16, name[8..10], 0, .big);
    std.mem.writeInt(u16, name[10..12], 0, .big);
    std.mem.writeInt(u16, name[12..14], 6, .big);
    std.mem.writeInt(u16, name[14..16], 5, .big);
    std.mem.writeInt(u16, name[16..18], 0, .big);
    @memcpy(name[18..23], "Ab#cd");
    const empty = [_][]const u16{&.{}};
    const bytes = try TestFonts.buildFont(std.testing.allocator, &empty, &name);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("Abcd", face.postscriptName());
}

test "high surrogate then ASCII keeps the ASCII" {
    var name: [22]u8 = undefined;
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], 1, .big);
    std.mem.writeInt(u16, name[4..6], 18, .big);
    std.mem.writeInt(u16, name[6..8], 3, .big);
    std.mem.writeInt(u16, name[8..10], 1, .big);
    std.mem.writeInt(u16, name[10..12], 0x0409, .big);
    std.mem.writeInt(u16, name[12..14], 6, .big);
    std.mem.writeInt(u16, name[14..16], 4, .big);
    std.mem.writeInt(u16, name[16..18], 0, .big);
    std.mem.writeInt(u16, name[18..20], 0xD800, .big);
    name[20] = 0x00;
    name[21] = 'A';
    const empty = [_][]const u16{&.{}};
    const bytes = try TestFonts.buildFont(std.testing.allocator, &empty, &name);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("A", face.postscriptName());
}

test "malformed UTF-16 name falls back to a good Macintosh name" {
    var name: [39]u8 = undefined;
    @memset(&name, 0);
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], 2, .big);
    std.mem.writeInt(u16, name[4..6], 30, .big);
    std.mem.writeInt(u16, name[6..8], 3, .big);
    std.mem.writeInt(u16, name[8..10], 1, .big);
    std.mem.writeInt(u16, name[12..14], 6, .big);
    std.mem.writeInt(u16, name[14..16], 4, .big);
    std.mem.writeInt(u16, name[16..18], 0, .big);
    std.mem.writeInt(u16, name[18..20], 1, .big);
    std.mem.writeInt(u16, name[20..22], 0, .big);
    std.mem.writeInt(u16, name[24..26], 6, .big);
    std.mem.writeInt(u16, name[26..28], 5, .big);
    std.mem.writeInt(u16, name[28..30], 4, .big);
    std.mem.writeInt(u16, name[30..32], 0xD800, .big);
    std.mem.writeInt(u16, name[32..34], 0xD800, .big);
    @memcpy(name[34..39], "Hello");
    const empty = [_][]const u16{&.{}};
    const bytes = try TestFonts.buildFont(std.testing.allocator, &empty, &name);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("Hello", face.postscriptName());
}

test "truncated later name record does not drop an earlier one" {
    var name: [35]u8 = undefined;
    @memset(&name, 0);
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], 2, .big);
    std.mem.writeInt(u16, name[4..6], 30, .big);
    std.mem.writeInt(u16, name[6..8], 1, .big);
    std.mem.writeInt(u16, name[8..10], 0, .big);
    std.mem.writeInt(u16, name[12..14], 6, .big);
    std.mem.writeInt(u16, name[14..16], 5, .big);
    std.mem.writeInt(u16, name[16..18], 0, .big);
    std.mem.writeInt(u16, name[18..20], 3, .big);
    std.mem.writeInt(u16, name[20..22], 1, .big);
    std.mem.writeInt(u16, name[24..26], 6, .big);
    std.mem.writeInt(u16, name[26..28], 20, .big);
    std.mem.writeInt(u16, name[28..30], 100, .big);
    @memcpy(name[30..35], "Hello");
    const empty = [_][]const u16{&.{}};
    const bytes = try TestFonts.buildFont(std.testing.allocator, &empty, &name);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("Hello", face.postscriptName());
}

test "name record count past the table keeps an earlier name" {
    var name: [35]u8 = undefined;
    @memset(&name, 0);
    std.mem.writeInt(u16, name[0..2], 0, .big);
    std.mem.writeInt(u16, name[2..4], 3, .big);
    std.mem.writeInt(u16, name[4..6], 30, .big);
    std.mem.writeInt(u16, name[6..8], 1, .big);
    std.mem.writeInt(u16, name[8..10], 0, .big);
    std.mem.writeInt(u16, name[12..14], 6, .big);
    std.mem.writeInt(u16, name[14..16], 5, .big);
    std.mem.writeInt(u16, name[16..18], 0, .big);
    @memcpy(name[30..35], "Hello");
    const empty = [_][]const u16{&.{}};
    const bytes = try TestFonts.buildFont(std.testing.allocator, &empty, &name);
    defer std.testing.allocator.free(bytes);
    const face = try open(bytes, 0);
    try std.testing.expectEqualStrings("Hello", face.postscriptName());
}

test "subsetPrefix hashes the instance only when a coordinate is not zero" {
    const gids = [_]u16{ 0, 3, 7, 42 };
    const plain = subsetPrefix(&gids, &.{});
    // The default instance keeps the prefix a font with no axes gets, so a
    // variable font drawn with no variations writes the bytes it did before.
    try std.testing.expectEqual(plain, subsetPrefix(&gids, &.{ 0, 0, 0 }));
    const bold = subsetPrefix(&gids, &.{ 0, 16384, 0 });
    try std.testing.expect(!std.mem.eql(u8, &plain, &bold));
    try std.testing.expect(!std.mem.eql(u8, &bold, &subsetPrefix(&gids, &.{ 0, -16384, 0 })));
    try std.testing.expect(!std.mem.eql(u8, &bold, &subsetPrefix(&gids, &.{ 16384, 0, 0 })));
    try std.testing.expectEqual(bold, subsetPrefix(&gids, &.{ 0, 16384, 0 }));
}

test "avarMajorVersion reads avar 1 and 2, null without avar, InvalidFont when short" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const fraunces = try loadTestFont(options.test_font_variable);
    defer gpa.free(fraunces);
    try std.testing.expectEqual(@as(?u16, 1), try avarMajorVersion(fraunces, 0));
    const avar2 = try loadTestFont(options.test_font_avar2);
    defer gpa.free(avar2);
    try std.testing.expectEqual(@as(?u16, 2), try avarMajorVersion(avar2, 0));
    const roboto = try loadTestFont(options.test_font_roboto);
    defer gpa.free(roboto);
    try std.testing.expectEqual(@as(?u16, null), try avarMajorVersion(roboto, 0));
    // A CFF font has no glyf, so `open` refuses it; findTable still reads it.
    const cff = try loadTestFont(options.test_font_cff);
    defer gpa.free(cff);
    try std.testing.expectError(error.UnsupportedFontFormat, open(cff, 0));
    try std.testing.expect(try findTable(cff, 0, "CFF ") != null);

    // Shrink the directory's avar length to 3 bytes.
    const num_tables = std.mem.readInt(u16, avar2[4..6], .big);
    for (0..num_tables) |i| {
        const rec = avar2[12 + 16 * i ..][0..16];
        if (std.mem.eql(u8, rec[0..4], "avar")) std.mem.writeInt(u32, rec[12..16], 3, .big);
    }
    try std.testing.expectError(error.InvalidFont, avarMajorVersion(avar2, 0));
}

test "instance PostScript names follow Adobe TN 5902" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const Case = struct { font: []const u8, coords: []const f32, want: []const u8 };
    // Coordinates are user values in fvar order.
    const cases = [_]Case{
        // A named instance with a postScriptNameID: Fraunces Thin is
        // opsz 9, wght 100, SOFT 0, WONK 1.
        .{ .font = options.test_font_variable, .coords = &.{ 9, 100, 0, 1 }, .want = "Fraunces-Thin" },
        // The same after clamping: opsz below its minimum of 9.
        .{ .font = options.test_font_variable, .coords = &.{ 2, 100, 0, 1 }, .want = "Fraunces-Thin" },
        // Arbitrary: name ID 25 "Fraunces", axes at their defaults left out.
        .{ .font = options.test_font_variable, .coords = &.{ 144, 100, 0, 1 }, .want = "Fraunces_144opsz_100wght" },
        .{ .font = options.test_font_mada, .coords = &.{100}, .want = "Mada-Light" },
        .{ .font = options.test_font_mada, .coords = &.{5000}, .want = "Mada-Black" },
        // No name ID 25: name ID 16 "Mada".
        .{ .font = options.test_font_mada, .coords = &.{777}, .want = "Mada_777wght" },
        // Named instances without postScriptNameID, and no name ID 25 or 16:
        // name ID 1 "Noto Sans" without its space, "-", the subfamily.
        .{ .font = options.test_font_noto_sans_vf, .coords = &.{ 100, 100, 0 }, .want = "NotoSans-Thin" },
        .{ .font = options.test_font_noto_sans_vf, .coords = &.{ 250, 62.5, 40 }, .want = "NotoSans_250wght_62.5wdth_40CTGR" },
        .{ .font = options.test_font_noto_sans_vf, .coords = &.{ 100.25, 99.99, 0.00002 }, .want = "NotoSans_100.25wght_99.99wdth_0.00002CTGR" },
        // Name ID 25 of Roboto Flex is 73 characters; three axes still fit.
        .{ .font = options.test_font_roboto_flex, .coords = &.{ 900, 25, 144, 0, -10, 468, 96, 79, 514, 712, 750, -203, 738 }, .want = "RobotoFlexNormalNormalNormalNormalNormalNormalNormalNormalNormalDefault_900wght_25wdth_144opsz_-10slnt" },
    };
    for (cases) |case| {
        const bytes = try loadTestFont(case.font);
        defer gpa.free(bytes);
        const face = try open(bytes, 0);
        const name = try instancePostscriptName(face, case.coords);
        try std.testing.expectEqualStrings(case.want, name.slice());
    }

    // Every Roboto Flex axis away from its default is longer than 120: the
    // last resort, prefix "-" eight hex digits "...", different per instance.
    const bytes = try loadTestFont(options.test_font_roboto_flex);
    defer gpa.free(bytes);
    const face = try open(bytes, 0);
    const prefix = "RobotoFlexNormalNormalNormalNormalNormalNormalNormalNormalNormalDefault-";
    const a = try instancePostscriptName(face, &.{ 100, 151, 8, -200, -10, 400, 30, 30, 420, 530, 650, -300, 600 });
    const b = try instancePostscriptName(face, &.{ 101, 151, 8, -200, -10, 400, 30, 30, 420, 530, 650, -300, 600 });
    for ([_][]const u8{ a.slice(), b.slice() }) |name| {
        try std.testing.expectEqual(prefix.len + 11, name.len);
        try std.testing.expect(std.mem.startsWith(u8, name, prefix));
        try std.testing.expect(std.mem.endsWith(u8, name, "..."));
        for (name[prefix.len..][0..8]) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'A' and c <= 'F'));
    }
    try std.testing.expect(!std.mem.eql(u8, a.slice(), b.slice()));
    try std.testing.expectError(error.InvalidFont, instancePostscriptName(face, &.{ 100, 151 }));
}

test "a named instance's postScriptNameID string wins over prefix-Subfamily" {
    // In every test font the postScriptNameID string equals prefix "-"
    // subfamily ("Fraunces-Thin"), so point Fraunces' Thin instance at name ID
    // 6 ("Fraunces-9ptBlack") to tell the two rules apart.
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const bytes = try loadTestFont(options.test_font_variable);
    defer gpa.free(bytes);
    const face = try open(bytes, 0);
    const fvar = (try faceTable(face, "fvar")).?;
    const at = @intFromPtr(fvar.ptr) - @intFromPtr(bytes.ptr);
    const axes_offset = std.mem.readInt(u16, fvar[4..6], .big);
    const axis_count = std.mem.readInt(u16, fvar[8..10], .big);
    const axis_size = std.mem.readInt(u16, fvar[10..12], .big);
    const instance = at + axes_offset + @as(usize, axis_count) * axis_size;
    const ps_id = bytes[instance + 4 + @as(usize, axis_count) * 4 ..][0..2];
    try std.testing.expectEqual(@as(u16, 261), std.mem.readInt(u16, ps_id, .big));
    std.mem.writeInt(u16, ps_id, 6, .big);
    const name = try instancePostscriptName(face, &.{ 9, 100, 0, 1 });
    try std.testing.expectEqualStrings("Fraunces-9ptBlack", name.slice());
    // 0xFFFF means none: prefix "-" subfamily.
    std.mem.writeInt(u16, ps_id, 0xFFFF, .big);
    try std.testing.expectEqualStrings("Fraunces-Thin", (try instancePostscriptName(face, &.{ 9, 100, 0, 1 })).slice());
}

test "formatFixed writes the fewest decimals that give back the 16.16 value" {
    var buf: [24]u8 = undefined;
    const Case = struct { fixed: i32, want: []const u8 };
    const cases = [_]Case{
        .{ .fixed = 0, .want = "0" },
        .{ .fixed = 900 * 65536, .want = "900" },
        .{ .fixed = 5 * 65536 + 32768, .want = "5.5" },
        .{ .fixed = -190054, .want = "-2.9" },
        .{ .fixed = 1, .want = "0.00002" },
        .{ .fixed = -1, .want = "-0.00002" },
        .{ .fixed = std.math.maxInt(i32), .want = "32767.99998" },
        .{ .fixed = std.math.minInt(i32), .want = "-32768" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.want, formatFixed(&buf, case.fixed));
}
