//! zpdf.read's encoding CMaps (ISO 32000-1 9.7.5, 9.7.6.2): how a Type0 font's strings split
//! into codes, and the CID each code selects.
//!
//! A CMap is a Map: bytes in the format below, read in place, so a lookup allocates nothing.
//! - Identity-H and Identity-V: two-byte codes, each code its own CID. No data.
//! - The 59 predefined CJK CMaps of Table 118 (src/cmap, from Adobe's cmap-resources): compiled
//!   at build time by tools/gen-cmaps.zig into one blob, which build.zig embeds as "cid_cmaps".
//!   Each stores only the codes where it differs from a parent: its usecmap (a -V map's -H map),
//!   or, for a UCS2 map, the UTF16 map of its collection. The parent answers the rest.
//! - A CMap stream in a file: parsed and encoded into the same format when its font loads.
//!
//! Splitting a string (9.7.6.2): the first byte is matched against the one-byte codespace ranges,
//! then two bytes against the two-byte ones, up to four. A code matches a range when each of its
//! bytes lies between the matching bytes of the range's bounds, not when the code lies between
//! them as a number. A string whose next bytes match no range is invalid there: the code's length
//! is that of the range with the longest partial match (the shortest such range on a tie, the
//! shortest range of all when not even the first byte matches), and the code selects CID 0.
//!
//! A code with no CID mapping takes the CID of its notdef mapping if it has one, else CID 0. The
//! glyph drawn is that CID's, but the code has no character: callers count it as unmapped.
//!
//! Map format, little-endian, at no particular alignment:
//!   u8 wmode, u8 flags (bit 0: identity), u8 codespace_count, u8 0,
//!   u16 parent (an index in the predefined blob, or no_parent), u16 0,
//!   u32 run_count[4] (for codes of 1, 2, 3 and 4 bytes), u32 notdef_count
//!   codespace_count ranges {u8 len, u8 lo[4], u8 hi[4]}: the bounds' bytes, from the first
//!   for each length n, run_count[n - 1] runs {code: u16 when n <= 2 else u32, u16 count, u16 cid}:
//!     code + i selects CID cid + i, for i below count. Sorted by code, not overlapping. CID 0
//!     means the code has no mapping, here or in the parent.
//!   notdef_count notdef ranges {u32 lo, u32 hi, u16 cid, u8 len, u8 0}: every code from lo to hi
//!     has notdef CID cid (Adobe TN 5014, beginnotdefrange). A later one wins over an earlier one.
//!
//! Blob format: u32 count, then count entries {u32 name_at, u32 name_len, u32 map_at, u32 map_len},
//! sorted by name; offsets are from the blob's start.

const std = @import("std");
const Allocator = std.mem.Allocator;
const read = @import("read.zig");
const Error = read.Error;

/// False in zpdf.wasm (build.zig, addCidMaps): there, only Identity-H and Identity-V and a
/// file's own CMap streams without usecmap are read.
const cid_tables = @import("read_options").cid_tables;

const predefined_blob: []const u8 = if (cid_tables) @embedFile("cid_cmaps") else "";

pub const no_parent: u16 = 0xFFFF;
const header_len = 28;
const codespace_len = 9;
const notdef_len = 12;
/// The most codespace ranges a CMap may have; Adobe's have at most 4.
const max_codespace = 32;
/// The most mapping and notdef ranges a CMap stream in a file may define (Adobe's largest has
/// about 26,000). Each is kept while the CMap is built.
pub const max_ranges = 1 << 17;

/// One code taken from a string.
pub const Code = struct {
    value: u32,
    /// Bytes, 1 to 4.
    len: u3,
    /// Matches a codespace range; an invalid code selects CID 0.
    valid: bool,
};

pub const Map = struct {
    bytes: []const u8,
    /// The blob its parent index is in.
    blob: []const u8,

    pub const identity_h: Map = .{ .bytes = &identityBytes(0), .blob = "" };
    pub const identity_v: Map = .{ .bytes = &identityBytes(1), .blob = "" };

    fn identityBytes(comptime wmode: u8) [header_len + codespace_len]u8 {
        var b: [header_len + codespace_len]u8 = @splat(0);
        b[0] = wmode;
        b[1] = 1;
        b[2] = 1;
        std.mem.writeInt(u16, b[4..6], no_parent, .little);
        b[header_len..][0..codespace_len].* = .{ 2, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0 };
        return b;
    }

    fn int(self: Map, comptime T: type, at: usize) T {
        return std.mem.readInt(T, self.bytes[at..][0..@sizeOf(T)], .little);
    }

    pub const Codespace = struct { len: u8, lo: [4]u8, hi: [4]u8 };

    /// Its codespace ranges, in order.
    pub fn codespaces(self: Map) CodespaceIterator {
        return .{ .map = self };
    }

    pub const CodespaceIterator = struct {
        map: Map,
        i: usize = 0,

        pub fn next(self: *CodespaceIterator) ?Codespace {
            if (self.i >= self.map.codespaceCount()) return null;
            const cs = self.map.bytes[header_len + self.i * codespace_len ..][0..codespace_len];
            self.i += 1;
            return .{ .len = cs[0], .lo = cs[1..5].*, .hi = cs[5..9].* };
        }
    };

    /// /WMode 1: vertical writing.
    pub fn vertical(self: Map) bool {
        return self.bytes[0] == 1;
    }

    fn identity(self: Map) bool {
        return self.bytes[1] & 1 != 0;
    }

    fn codespaceCount(self: Map) usize {
        return self.bytes[2];
    }

    fn runCount(self: Map, len: usize) usize {
        return self.int(u32, 8 + (len - 1) * 4);
    }

    fn notdefCount(self: Map) usize {
        return self.int(u32, 24);
    }

    fn runLen(len: usize) usize {
        return if (len <= 2) 6 else 8;
    }

    fn runsAt(self: Map, len: usize) usize {
        var at = header_len + self.codespaceCount() * codespace_len;
        for (1..len) |n| at += self.runCount(n) * runLen(n);
        return at;
    }

    fn notdefsAt(self: Map) usize {
        return self.runsAt(4) + self.runCount(4) * runLen(4);
    }

    fn parent(self: Map) ?Map {
        const p = self.int(u16, 4);
        if (p == no_parent) return null;
        return mapAt(self.blob, p);
    }

    /// The code at the start of `s`, which must not be empty.
    pub fn split(self: Map, s: []const u8) Code {
        std.debug.assert(s.len > 0);
        // Identity's one range, <0000> to <FFFF>, matches any two bytes: the common case, taken
        // without the loop below, which gives the same code.
        if (self.identity() and s.len >= 2) return .{ .value = std.mem.readInt(u16, s[0..2], .big), .len = 2, .valid = true };
        const ranges = self.codespaceCount();
        const avail = @min(s.len, 4);
        for (1..avail + 1) |n| {
            for (0..ranges) |r| {
                const at = header_len + r * codespace_len;
                if (self.bytes[at] != n) continue;
                if (matches(self.bytes[at + 1 ..][0..4], self.bytes[at + 5 ..][0..4], s[0..n])) {
                    return .{ .value = std.mem.readVarInt(u32, s[0..n], .big), .len = @intCast(n), .valid = true };
                }
            }
        }
        // Invalid: the longest partial match picks the length; ties and no match at all go to
        // the shortest range.
        var best_partial: usize = 0;
        var best_len: usize = 0;
        for (0..ranges) |r| {
            const at = header_len + r * codespace_len;
            const len = self.bytes[at];
            var k: usize = 0;
            while (k < len - 1 and k < avail and matches(self.bytes[at + 1 ..][0..4], self.bytes[at + 5 ..][0..4], s[0 .. k + 1])) k += 1;
            if (best_len == 0 or k > best_partial or (k == best_partial and len < best_len)) {
                best_partial = k;
                best_len = len;
            }
        }
        const n = @max(1, @min(best_len, s.len));
        return .{ .value = std.mem.readVarInt(u32, s[0..n], .big), .len = @intCast(n), .valid = false };
    }

    fn matches(lo: *const [4]u8, hi: *const [4]u8, code: []const u8) bool {
        for (code, 0..) |b, i| {
            if (b < lo[i] or b > hi[i]) return false;
        }
        return true;
    }

    /// The CID a valid code selects by its mappings, or null when it has none (it then takes
    /// its notdef mapping's CID, or 0).
    pub fn cid(self: Map, code: Code) ?u16 {
        if (!code.valid) return null;
        // Identity's one codespace range is two bytes, so a valid code is two bytes.
        if (self.identity()) return @intCast(code.value);
        var m = self;
        while (true) {
            if (m.runCid(code.len, code.value)) |c| return if (c == 0) null else c;
            m = m.parent() orelse return null;
        }
    }

    fn runCid(self: Map, len: usize, code: u32) ?u16 {
        const count = self.runCount(len);
        const at = self.runsAt(len);
        const rl = runLen(len);
        const code_len: usize = if (len <= 2) 2 else 4;
        // The last run starting at or before the code.
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.codeAt(at + mid * rl, code_len) <= code) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const r = at + (lo - 1) * rl;
        const first = self.codeAt(r, code_len);
        if (code - first >= self.int(u16, r + code_len)) return null;
        const c = self.int(u16, r + code_len + 2);
        if (c == 0) return 0;
        return @intCast(c + (code - first));
    }

    fn codeAt(self: Map, at: usize, code_len: usize) u32 {
        return if (code_len == 2) self.int(u16, at) else self.int(u32, at);
    }

    /// The CID of a code's notdef mapping, or null.
    pub fn notdef(self: Map, code: Code) ?u16 {
        const at = self.notdefsAt();
        var i = self.notdefCount();
        while (i > 0) {
            i -= 1;
            const r = at + i * notdef_len;
            if (self.bytes[r + 10] != code.len) continue;
            if (code.value >= self.int(u32, r) and code.value <= self.int(u32, r + 4)) return self.int(u16, r + 8);
        }
        return null;
    }
};

/// The predefined CMap named `name`, or null when it is not one of Table 118's (or the build has
/// no tables).
pub fn predefined(name: []const u8) ?Map {
    if (std.mem.eql(u8, name, "Identity-H")) return Map.identity_h;
    if (std.mem.eql(u8, name, "Identity-V")) return Map.identity_v;
    return find(predefined_blob, name);
}

/// The Map named `name` in a blob, or null.
pub fn find(blob: []const u8, name: []const u8) ?Map {
    return mapAt(blob, index(blob, name) orelse return null);
}

/// The index of `name` in a blob, which a Map's parent field names.
pub fn index(blob: []const u8, name: []const u8) ?u16 {
    if (blob.len == 0) return null;
    const count = std.mem.readInt(u32, blob[0..4], .little);
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const e = 4 + mid * 16;
        const at = std.mem.readInt(u32, blob[e..][0..4], .little);
        const len = std.mem.readInt(u32, blob[e + 4 ..][0..4], .little);
        switch (std.mem.order(u8, blob[at..][0..len], name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @intCast(mid),
        }
    }
    return null;
}

fn mapAt(blob: []const u8, i: u16) Map {
    const e = 4 + @as(usize, i) * 16;
    const map_at = std.mem.readInt(u32, blob[e + 8 ..][0..4], .little);
    const len = std.mem.readInt(u32, blob[e + 12 ..][0..4], .little);
    return .{ .bytes = blob[map_at..][0..len], .blob = blob };
}

/// A Map encoded from a CMap stream (encode, encodeOver): its parent, if any, is predefined.
pub fn fromStream(bytes: []const u8) Map {
    return .{ .bytes = bytes, .blob = predefined_blob };
}

/// The predefined blob's index of `name`, for a CMap stream's usecmap.
pub fn predefinedIndex(name: []const u8) ?u16 {
    return index(predefined_blob, name);
}

/// Encodes a CMap stream that uses predefined CMap `parent` (usecmap): its codespace ranges and
/// notdef mappings are the parent's, then its own, and its /WMode is its own or else the parent's.
/// Codes it does not map fall to the parent.
pub fn encodeOver(gpa: Allocator, b: *const Builder, parent: u16) Error![]u8 {
    const p = mapAt(predefined_blob, parent);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var merged: Builder = .{ .wmode = b.wmode orelse p.bytes[0], .runs = b.runs };
    for (0..p.codespaceCount()) |r| {
        const cs = p.bytes[header_len + r * codespace_len ..][0..codespace_len];
        try merged.codespace.append(a, .{ .len = cs[0], .lo = cs[1..5].*, .hi = cs[5..9].* });
    }
    try merged.codespace.appendSlice(a, b.codespace.items);
    const nd_at = p.notdefsAt();
    for (0..p.notdefCount()) |i| {
        const r = nd_at + i * notdef_len;
        try merged.notdefs.append(a, .{ .len = p.bytes[r + 10], .lo = p.int(u32, r), .hi = p.int(u32, r + 4), .cid = p.int(u16, r + 8) });
    }
    try merged.notdefs.appendSlice(a, b.notdefs.items);
    return encode(gpa, &merged, parent);
}

/// A CMap being read: its definitions so far, later ones replacing earlier ones where they
/// overlap. `parse` fills one from CMap text; `encode` writes it as a Map.
pub const Builder = struct {
    wmode: ?u8 = null,
    codespace: std.ArrayList(Codespace) = .empty,
    /// For codes of 1 to 4 bytes: sorted by lo, not overlapping.
    runs: [4]std.ArrayList(Run) = .{ .empty, .empty, .empty, .empty },
    notdefs: std.ArrayList(Notdef) = .empty,
    /// The name its usecmap operator gave, if any.
    usecmap: ?[]const u8 = null,
    /// Ranges defined so far, against max_ranges.
    defined: usize = 0,

    pub const Codespace = struct { len: u8, lo: [4]u8, hi: [4]u8 };
    /// lo selects cid, lo + 1 selects cid + 1, up to hi. A null cid: these codes have no
    /// mapping (diff writes them, where only a parent maps the codes).
    pub const Run = struct { lo: u32, hi: u32, cid: ?u32 };
    /// Every code from lo to hi has notdef CID cid.
    pub const Notdef = struct { len: u8, lo: u32, hi: u32, cid: u32 };

    /// Maps codes lo to hi, of `len` bytes, to CIDs from `cid` on, over what they mapped to.
    pub fn map(self: *Builder, a: Allocator, len: usize, lo: u32, hi: u32, cid: u32) Error!void {
        std.debug.assert(len >= 1 and len <= 4 and lo <= hi);
        if (cid + @as(u64, hi - lo) > 0xFFFF) return error.Malformed;
        const list = &self.runs[len - 1];
        // The first run that ends at or after lo.
        var i: usize = 0;
        var j: usize = list.items.len;
        while (i < j) {
            const mid = (i + j) / 2;
            if (list.items[mid].hi < lo) i = mid + 1 else j = mid;
        }
        // Runs from i to j overlap [lo, hi].
        j = i;
        while (j < list.items.len and list.items[j].lo <= hi) j += 1;
        var repl: [3]Run = undefined;
        var n: usize = 0;
        if (i < j and list.items[i].lo < lo) {
            const r = list.items[i];
            repl[n] = .{ .lo = r.lo, .hi = lo - 1, .cid = r.cid };
            n += 1;
        }
        repl[n] = .{ .lo = lo, .hi = hi, .cid = cid };
        n += 1;
        if (i < j and list.items[j - 1].hi > hi) {
            const r = list.items[j - 1];
            repl[n] = .{ .lo = hi + 1, .hi = r.hi, .cid = if (r.cid) |c| c + (hi + 1 - r.lo) else null };
            n += 1;
        }
        try list.replaceRange(a, i, j - i, repl[0..n]);
    }

    /// The CID code selects here, or null.
    pub fn lookup(self: *const Builder, len: usize, code: u32) ?u32 {
        const list = self.runs[len - 1].items;
        var lo: usize = 0;
        var hi: usize = list.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (list[mid].hi < code) lo = mid + 1 else hi = mid;
        }
        if (lo < list.len and list[lo].lo <= code) {
            const c = list[lo].cid orelse return null;
            return c + (code - list[lo].lo);
        }
        return null;
    }

    /// `base` with this one's definitions over it: what a CMap that uses `base` (usecmap)
    /// selects. Codespace ranges and notdef mappings are base's, then this one's.
    pub fn over(self: *const Builder, a: Allocator, base: *const Builder) Error!Builder {
        var out: Builder = .{ .wmode = self.wmode orelse base.wmode };
        try out.codespace.appendSlice(a, base.codespace.items);
        try out.codespace.appendSlice(a, self.codespace.items);
        try out.notdefs.appendSlice(a, base.notdefs.items);
        try out.notdefs.appendSlice(a, self.notdefs.items);
        for (0..4) |k| {
            try out.runs[k].appendSlice(a, base.runs[k].items);
            for (self.runs[k].items) |r| try out.map(a, k + 1, r.lo, r.hi, r.cid orelse return error.Malformed);
        }
        return out;
    }
};

/// Parses CMap text (a CMap stream, or one of Adobe's files): codespace ranges, cidchar,
/// cidrange, notdefchar, notdefrange, usecmap and /WMode. bfchar and bfrange (a ToUnicode
/// CMap's) are not CID mappings and are skipped, as are PostScript procedures and other
/// operators.
pub fn parse(a: Allocator, gpa: Allocator, text: []const u8) Error!Builder {
    var tokens: std.heap.ArenaAllocator = .init(gpa);
    defer tokens.deinit();
    const t_a = &tokens;
    var b: Builder = .{};
    var lx: read.Lexer = .{ .src = text, .pos = 0 };
    var operands: std.ArrayList(read.Token) = .empty;
    defer operands.deinit(gpa);
    while (true) {
        const before = lx.pos;
        const t = lx.next(t_a) catch |err| switch (err) {
            // { } procedures are PostScript, not PDF syntax; a refusal that did not move on
            // would repeat forever.
            error.Malformed => {
                if (lx.pos == before) lx.pos += 1;
                continue;
            },
            else => return err,
        };
        switch (t) {
            .eof => break,
            .keyword => |k| {
                try operator(a, &b, k, operands.items);
                operands.clearRetainingCapacity();
                _ = tokens.reset(.retain_capacity);
            },
            else => {
                if (operands.items.len >= 1 << 16) return error.TooLarge;
                try operands.append(gpa, t);
            },
        }
    }
    return b;
}

fn operator(a: Allocator, b: *Builder, k: []const u8, ops: []const read.Token) Error!void {
    const eql = std.mem.eql;
    if (eql(u8, k, "endcodespacerange")) {
        if (ops.len % 2 != 0) return error.Malformed;
        var i: usize = 0;
        while (i < ops.len) : (i += 2) {
            const lo = try codeBytes(ops[i]);
            const hi = try codeBytes(ops[i + 1]);
            if (lo.len != hi.len) return error.Malformed;
            if (b.codespace.items.len >= max_codespace) return error.TooLarge;
            var cs: Builder.Codespace = .{ .len = @intCast(lo.len), .lo = @splat(0), .hi = @splat(0) };
            @memcpy(cs.lo[0..lo.len], lo);
            @memcpy(cs.hi[0..hi.len], hi);
            try b.codespace.append(a, cs);
        }
    } else if (eql(u8, k, "endcidchar") or eql(u8, k, "endnotdefchar")) {
        if (ops.len % 2 != 0) return error.Malformed;
        var i: usize = 0;
        while (i < ops.len) : (i += 2) {
            const c = try codeBytes(ops[i]);
            const code = std.mem.readVarInt(u32, c, .big);
            try define(a, b, eql(u8, k, "endnotdefchar"), c.len, code, code, try cidOf(ops[i + 1]));
        }
    } else if (eql(u8, k, "endcidrange") or eql(u8, k, "endnotdefrange")) {
        if (ops.len % 3 != 0) return error.Malformed;
        var i: usize = 0;
        while (i < ops.len) : (i += 3) {
            const lo = try codeBytes(ops[i]);
            const hi = try codeBytes(ops[i + 1]);
            if (lo.len != hi.len) return error.Malformed;
            const lo_v = std.mem.readVarInt(u32, lo, .big);
            const hi_v = std.mem.readVarInt(u32, hi, .big);
            if (hi_v < lo_v) return error.Malformed;
            try define(a, b, eql(u8, k, "endnotdefrange"), lo.len, lo_v, hi_v, try cidOf(ops[i + 2]));
        }
    } else if (eql(u8, k, "usecmap")) {
        if (ops.len == 0 or ops[ops.len - 1] != .name) return error.Malformed;
        b.usecmap = try a.dupe(u8, ops[ops.len - 1].name);
    } else if (eql(u8, k, "def")) {
        if (ops.len >= 2 and ops[ops.len - 2] == .name and eql(u8, ops[ops.len - 2].name, "WMode")) {
            const v = ops[ops.len - 1];
            if (v != .integer or (v.integer != 0 and v.integer != 1)) return error.Malformed;
            b.wmode = @intCast(v.integer);
        }
    }
}

fn define(a: Allocator, b: *Builder, is_notdef: bool, len: usize, lo: u32, hi: u32, cid: u32) Error!void {
    if (b.defined >= max_ranges) return error.TooLarge;
    b.defined += 1;
    if (is_notdef) {
        try b.notdefs.append(a, .{ .len = @intCast(len), .lo = lo, .hi = hi, .cid = cid });
    } else try b.map(a, len, lo, hi, cid);
}

fn codeBytes(t: read.Token) Error![]const u8 {
    if (t != .string or t.string.len == 0 or t.string.len > 4) return error.Malformed;
    return t.string;
}

fn cidOf(t: read.Token) Error!u32 {
    if (t != .integer or t.integer < 0 or t.integer > 0xFFFF) return error.Malformed;
    return @intCast(t.integer);
}

/// The Map of `b`, into `gpa`. Adjacent runs that continue each other are joined; a run longer
/// than a u16 count is split. A Map's CID 0 means "no mapping", so a run that maps its first code
/// to CID 0 keeps that code as CID 0 (the glyph is CID 0's either way; only the notdef mapping,
/// consulted for an unmapped code, can then differ) and maps the rest from CID 1.
pub fn encode(gpa: Allocator, b: *const Builder, parent: u16) Error![]u8 {
    var out: Out = .{ .gpa = gpa };
    errdefer out.list.deinit(gpa);
    const w = &out;
    var runs: [4]std.ArrayList(Builder.Run) = .{ .empty, .empty, .empty, .empty };
    defer for (&runs) |*r| r.deinit(gpa);
    for (b.runs, &runs) |src, *dst| {
        for (src.items) |whole| {
            var r = whole;
            if (r.cid == 0 and r.hi > r.lo) {
                try dst.append(gpa, .{ .lo = r.lo, .hi = r.lo, .cid = null });
                r = .{ .lo = r.lo + 1, .hi = r.hi, .cid = 1 };
            } else if (r.cid == 0) r.cid = null;
            if (dst.items.len > 0) {
                const last = &dst.items[dst.items.len - 1];
                const joins = if (last.cid) |lc| (if (r.cid) |rc| lc + (last.hi - last.lo) + 1 == rc else false) else r.cid == null;
                if (last.hi + 1 == r.lo and joins) {
                    last.hi = r.hi;
                    continue;
                }
            }
            try dst.append(gpa, r);
        }
    }
    try w.writeAll(&.{ b.wmode orelse 0, 0, @intCast(b.codespace.items.len), 0 });
    try w.writeInt(u16, parent, .little);
    try w.writeInt(u16, 0, .little);
    var counts: [4]u32 = undefined;
    for (runs, &counts) |r, *c| {
        c.* = 0;
        for (r.items) |run| c.* += @intCast((@as(u64, run.hi - run.lo) + 1 + 0xFFFE) / 0xFFFF);
        try w.writeInt(u32, c.*, .little);
    }
    try w.writeInt(u32, @intCast(b.notdefs.items.len), .little);
    for (b.codespace.items) |cs| {
        try w.writeByte(cs.len);
        try w.writeAll(&cs.lo);
        try w.writeAll(&cs.hi);
    }
    for (runs, 1..) |r, len| {
        for (r.items) |run| {
            var lo = run.lo;
            var cid: u32 = run.cid orelse 0;
            while (true) {
                const left = run.hi - lo;
                const count: u16 = @intCast(@min(left, 0xFFFE) + 1);
                if (len <= 2) try w.writeInt(u16, @intCast(lo), .little) else try w.writeInt(u32, lo, .little);
                try w.writeInt(u16, count, .little);
                try w.writeInt(u16, @intCast(cid), .little);
                if (left < 0xFFFF) break;
                lo += count;
                if (cid != 0) cid += count;
            }
        }
    }
    for (b.notdefs.items) |nd| {
        try w.writeInt(u32, nd.lo, .little);
        try w.writeInt(u32, nd.hi, .little);
        try w.writeInt(u16, @intCast(nd.cid), .little);
        try w.writeAll(&.{ nd.len, 0 });
    }
    return out.list.toOwnedSlice(gpa);
}

/// encode's output: a byte list whose only failure is running out of memory.
const Out = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    fn writeAll(self: *Out, bytes: []const u8) Error!void {
        try self.list.appendSlice(self.gpa, bytes);
    }

    fn writeByte(self: *Out, byte: u8) Error!void {
        try self.list.append(self.gpa, byte);
    }

    fn writeInt(self: *Out, comptime T: type, v: T, comptime endian: std.builtin.Endian) Error!void {
        std.mem.writeInt(T, try self.list.addManyAsArray(self.gpa, @sizeOf(T)), v, endian);
    }
};

/// What `child` selects where it differs from `parent`, CID 0 where only the parent maps a
/// code, with child's codespace, notdef mappings and /WMode: the runs a Map with `parent` as its
/// parent needs to read as `child` does. Build time only (tools/gen-cmaps.zig).
pub fn diff(a: Allocator, child: *const Builder, parent: *const Builder) Error!Builder {
    var out: Builder = .{ .wmode = child.wmode };
    try out.codespace.appendSlice(a, child.codespace.items);
    try out.notdefs.appendSlice(a, child.notdefs.items);
    for (0..4) |k| {
        // Every point where either side's mapping starts or stops; between two of them each
        // side is one run or none, so it agrees everywhere or nowhere.
        var points: std.ArrayList(u64) = .empty;
        for ([_][]const Builder.Run{ child.runs[k].items, parent.runs[k].items }) |list| {
            for (list) |r| try points.appendSlice(a, &.{ r.lo, @as(u64, r.hi) + 1 });
        }
        std.mem.sort(u64, points.items, {}, std.sort.asc(u64));
        var prev: ?u64 = null;
        for (points.items) |p| {
            if (prev) |q| if (q < p) {
                const lo: u32 = @intCast(q);
                const c = child.lookup(k + 1, lo);
                const pc = parent.lookup(k + 1, lo);
                if (!std.meta.eql(c, pc)) try out.runs[k].append(a, .{ .lo = lo, .hi = @intCast(p - 1), .cid = c });
            };
            prev = p;
        }
    }
    return out;
}

// ---- tests ----

const testing = std.testing;

/// The Map of CMap text, with no parent.
fn testMap(a: Allocator, text: []const u8) !Map {
    const b = try parse(a, testing.allocator, text);
    return .{ .bytes = try encode(a, &b, no_parent), .blob = "" };
}

test "codes split by codespace byte by byte, and an invalid code takes the longest partial match" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 90ms-RKSJ-H's codespace.
    const m = try testMap(a,
        \\4 begincodespacerange <00> <80> <8140> <9FFC> <A0> <DF> <E040> <FCFC> endcodespacerange
        \\1 begincidrange <8140> <817e> 633 endcidrange
    );
    try testing.expectEqual(Code{ .value = 0x41, .len = 1, .valid = true }, m.split("AB"));
    try testing.expectEqual(Code{ .value = 0x8150, .len = 2, .valid = true }, m.split("\x81\x50\x41"));
    // 8A20 lies between 8140 and 9FFC as a number, but its second byte is below 40: invalid. The
    // first byte matched a two-byte range, so the code is two bytes.
    try testing.expectEqual(Code{ .value = 0x8A20, .len = 2, .valid = false }, m.split("\x8A\x20"));
    // No range starts with FF: the shortest range's length, one byte.
    try testing.expectEqual(Code{ .value = 0xFF, .len = 1, .valid = false }, m.split("\xFF\x41"));
    // A two-byte code cut off by the string's end is one invalid byte.
    try testing.expectEqual(Code{ .value = 0x81, .len = 1, .valid = false }, m.split("\x81"));
    try testing.expectEqual(@as(?u16, 649), m.cid(m.split("\x81\x50")));
    try testing.expectEqual(@as(?u16, null), m.cid(m.split("\x8A\x20")));

    // Partial matches of different lengths: 8130 matches 2 bytes of the four-byte range, and 1
    // of the two-byte one, so the code is four bytes (GBK2K-H's codespace).
    const g = try testMap(a, "3 begincodespacerange <00> <7F> <81308130> <FE39FE39> <8140> <FEFE> endcodespacerange");
    try testing.expectEqual(Code{ .value = 0x81302020, .len = 4, .valid = false }, g.split("\x81\x30\x20\x20"));
    // 81 then 20: one byte of each matches, a tie, so the shorter range's two bytes.
    try testing.expectEqual(Code{ .value = 0x8120, .len = 2, .valid = false }, g.split("\x81\x20\x20\x20"));
}

test "a later definition replaces an earlier one where they overlap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try testMap(a,
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\1 begincidrange <0010> <001f> 100 endcidrange
        \\1 begincidrange <0014> <0016> 500 endcidrange
        \\1 begincidchar <0018> 7 endcidchar
        \\1 begincidrange <000e> <0011> 900 endcidrange
    );
    const want = [_]struct { u32, ?u16 }{
        .{ 0x0d, null }, .{ 0x0e, 900 },  .{ 0x11, 903 }, .{ 0x12, 102 }, .{ 0x13, 103 },
        .{ 0x14, 500 },  .{ 0x16, 502 },  .{ 0x17, 107 }, .{ 0x18, 7 },   .{ 0x19, 109 },
        .{ 0x1f, 115 },  .{ 0x20, null },
    };
    for (want) |w| try testing.expectEqual(w[1], m.cid(.{ .value = w[0], .len = 2, .valid = true }));
}

test "a stored difference reads as the whole CMap, CID 0 hiding the parent's mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent = try parse(a, testing.allocator,
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\2 begincidrange <0020> <007e> 1 <3000> <30ff> 600 endcidrange
    );
    const child = try parse(a, testing.allocator,
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\2 begincidrange <0020> <007e> 1 <3000> <307f> 600 endcidrange
        \\1 begincidchar <3001> 9000 endcidchar
    );
    const d = try diff(a, &child, &parent);
    // Only 3001 (a new CID) and 3080 to 30ff (gone from the child) are stored.
    try testing.expectEqual(@as(usize, 2), d.runs[1].items.len);
    // A blob of the two: the parent first, so its index is 0.
    var blob: std.ArrayList(u8) = .empty;
    const maps = [_][]const u8{ try encode(a, &parent, no_parent), try encode(a, &d, 0) };
    const names = [_][]const u8{ "A", "B" };
    try blob.appendSlice(a, &std.mem.toBytes(@as(u32, 2)));
    var at: u32 = 4 + 2 * 16 + 2;
    for (names, maps, 0..) |n, mb, i| {
        for ([_]u32{ 4 + 2 * 16 + @as(u32, @intCast(i)), @intCast(n.len), at, @intCast(mb.len) }) |v| try blob.appendSlice(a, &std.mem.toBytes(v));
        at += @intCast(mb.len);
    }
    try blob.appendSlice(a, "AB");
    for (maps) |mb| try blob.appendSlice(a, mb);
    const m = find(blob.items, "B").?;
    for ([_]u32{ 0x20, 0x41, 0x3000, 0x3001, 0x3002, 0x307f, 0x3080, 0x30ff, 0x3100 }) |c| {
        const want = child.lookup(2, c);
        const got = m.cid(.{ .value = c, .len = 2, .valid = true });
        try testing.expectEqual(if (want) |w| @as(?u16, @intCast(w)) else null, got);
    }
}

test "notdef mappings, usecmap, /WMode, and what parse refuses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try parse(a, testing.allocator,
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\/CIDSystemInfo 3 dict dup begin /Registry (Adobe) def /Ordering (Japan1) def end def
        \\/WMode 1 def /UniJIS-UCS2-H usecmap
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\1 beginnotdefrange <0000> <001f> 1 endnotdefrange
        \\1 beginnotdefchar <0005> 50 endnotdefchar
        \\1 beginbfchar <0041> <0042> endbfchar
        \\endcmap CMapName currentdict /CMap defineresource pop end end
    );
    try testing.expectEqualStrings("UniJIS-UCS2-H", b.usecmap.?);
    try testing.expectEqual(@as(?u8, 1), b.wmode);
    const m: Map = .{ .bytes = try encode(a, &b, no_parent), .blob = "" };
    try testing.expect(m.vertical());
    // bfchar is a ToUnicode mapping, not a CID one.
    try testing.expectEqual(@as(?u16, null), m.cid(m.split("\x00\x41")));
    // A notdef range maps every code in it to its one CID (Adobe TN 5014).
    try testing.expectEqual(@as(?u16, 1), m.notdef(m.split("\x00\x02")));
    try testing.expectEqual(@as(?u16, 50), m.notdef(m.split("\x00\x05")));
    try testing.expectEqual(@as(?u16, null), m.notdef(m.split("\x00\x20")));

    for ([_][]const u8{
        "1 begincidrange <00> <ff> endcidrange", // a range is three operands
        "1 begincidrange <0010> <0001> 5 endcidrange", // high below low
        "1 begincidrange <00> <0001> 5 endcidrange", // bounds of different lengths
        "1 begincidchar <0001> 70000 endcidchar", // a CID past 65535
        "1 begincidrange <0000> <ffff> 2 endcidrange", // CIDs that run past 65535
        "1 begincidchar <0102030405> 1 endcidchar", // a code of five bytes
        "1 begincodespacerange <00> <0000> endcodespacerange",
        "/WMode 2 def",
        "usecmap",
    }) |text| try testing.expectError(error.Malformed, parse(a, testing.allocator, text));
}

test "a run from CID 0 keeps its other codes, and a long run is split into records" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // PDFTron writes a one-byte identity CMap this way.
    const m = try testMap(a, "1 begincodespacerange <00> <FF> endcodespacerange 1 begincidrange <00> <ff> 0 endcidrange");
    // Code 00 selects CID 0, which a Map cannot tell from no mapping; the glyph is CID 0's either way.
    try testing.expectEqual(@as(?u16, null), m.cid(m.split("\x00")));
    try testing.expectEqual(@as(?u16, 1), m.cid(m.split("\x01")));
    try testing.expectEqual(@as(?u16, 0x7C), m.cid(m.split("|")));
    try testing.expectEqual(@as(?u16, 0xFF), m.cid(m.split("\xFF")));

    // 70,001 four-byte codes with no mapping, then 65,536 from CID 0: records hold at most 65,535.
    var b: Builder = .{};
    try b.codespace.append(a, .{ .len = 4, .lo = .{ 0, 0, 0, 0 }, .hi = .{ 0, 2, 0xFF, 0xFF } });
    try b.runs[3].append(a, .{ .lo = 0x10, .hi = 0x10 + 70000, .cid = null });
    try b.map(a, 4, 0x20000, 0x20000 + 0xFFFF, 0);
    const long: Map = .{ .bytes = try encode(a, &b, no_parent), .blob = "" };
    try testing.expectEqual(@as(usize, 4), long.runCount(4));
    for ([_]u32{ 0x10, 0x10 + 0xFFFE, 0x10 + 0xFFFF, 0x10 + 70000 }) |c| {
        try testing.expectEqual(@as(?u16, null), long.cid(.{ .value = c, .len = 4, .valid = true }));
    }
    try testing.expectEqual(@as(?u16, 1), long.cid(.{ .value = 0x20001, .len = 4, .valid = true }));
    try testing.expectEqual(@as(?u16, 0xFFFF), long.cid(.{ .value = 0x20000 + 0xFFFF, .len = 4, .valid = true }));
}
