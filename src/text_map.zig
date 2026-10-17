//! Group rule, per-glyph text, CID allocation, and the ToUnicode CMap.
//! kb clusters are a hint; the source codepoints are the authority.

const std = @import("std");
const zpdf = @import("root.zig");
const ManagedList = std.array_list.Managed;

pub const CidKey = struct {
    gid: u16,
    text: []const u21,
};

const CidContext = struct {
    pub fn hash(_: @This(), key: CidKey) u32 {
        var hasher = std.hash.Wyhash.init(0);
        var gid_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &gid_bytes, key.gid, .little);
        hasher.update(&gid_bytes);
        for (key.text) |cp| {
            var cp_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &cp_bytes, cp, .little);
            hasher.update(&cp_bytes);
        }
        return @truncate(hasher.final());
    }
    pub fn eql(_: @This(), a: CidKey, b: CidKey, _: usize) bool {
        return a.gid == b.gid and std.mem.eql(u21, a.text, b.text);
    }
};

pub const CidRegistry = struct {
    gpa: std.mem.Allocator,
    map: std.array_hash_map.Custom(CidKey, u16, CidContext, true) = .empty,

    pub fn init(gpa: std.mem.Allocator) CidRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *CidRegistry) void {
        for (self.map.keys()) |key| {
            self.gpa.free(@constCast(key.text));
        }
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// CID 0 is reserved. Pairs are numbered from 1 in first-use order.
    pub fn intern(self: *CidRegistry, gid: u16, text: []const u21) !u16 {
        if (self.map.get(.{ .gid = gid, .text = text })) |cid| return cid;
        if (self.map.count() >= 65535) return error.TooManyCids;
        const owned = try self.gpa.dupe(u21, text);
        errdefer self.gpa.free(owned);
        const gop = try self.map.getOrPut(self.gpa, .{ .gid = gid, .text = owned });
        if (gop.found_existing) {
            self.gpa.free(owned);
            return gop.value_ptr.*;
        }
        const cid: u16 = @intCast(self.map.count());
        gop.value_ptr.* = cid;
        return cid;
    }

    pub fn count(self: *const CidRegistry) usize {
        return self.map.count();
    }

    pub fn truncate(self: *CidRegistry, keep: usize) void {
        while (self.map.count() > keep) {
            const popped = self.map.pop().?;
            self.gpa.free(@constCast(popped.key.text));
        }
    }

    pub fn gidForCid(self: *const CidRegistry, cid: u16) u16 {
        if (cid == 0) return 0;
        return self.map.keys()[cid - 1].gid;
    }

    pub fn textForCid(self: *const CidRegistry, cid: u16) []const u21 {
        if (cid == 0) return &.{};
        return self.map.keys()[cid - 1].text;
    }
};

pub const ActualTextSpan = struct {
    start: u32,
    end: u32,
    text: []u21,
};

/// What one drawText records for the PDF: a CID per glyph, and the
/// ActualText spans. Owned by whatever arena `map` was given.
pub const Mapping = struct {
    cids: []u16,
    spans: []ActualTextSpan,
};

pub fn utf8ToCodepoints(arena: std.mem.Allocator, utf8: []const u8) ![]u21 {
    const view = try std.unicode.Utf8View.init(utf8);
    const out = try arena.alloc(u21, std.unicode.utf8CountCodepoints(utf8) catch unreachable);
    var it = view.iterator();
    for (out) |*cp| cp.* = it.nextCodepoint().?;
    return out;
}

/// One operation: everything, including the returned Mapping, is allocated in
/// `arena` and nothing is freed. `cids` is the exception: it outlives the call
/// and owns its own memory.
pub fn map(
    arena: std.mem.Allocator,
    codepoints: []const u21,
    glyphs: []const zpdf.Glyph,
    runs: []const zpdf.Run,
    cids: *CidRegistry,
) !Mapping {
    return mapWith(true, arena, codepoints, glyphs, runs, cids);
}

/// `map` with its fast paths on or off (`fast`); the two must give the same
/// Mapping, which the "fast and general paths agree" test checks.
fn mapWith(
    comptime fast: bool,
    arena: std.mem.Allocator,
    codepoints: []const u21,
    glyphs: []const zpdf.Glyph,
    runs: []const zpdf.Run,
    cids: *CidRegistry,
) !Mapping {
    const n: u32 = @intCast(codepoints.len);
    try checkClusters(glyphs, n);
    const intervals = try runIntervals(arena, glyphs, runs, n);

    // Per-glyph text, read only while mapping: the CID registry keeps its own copy.
    const texts = try arena.alloc([]const u21, glyphs.len);
    @memset(texts, &.{});

    var spans = ManagedList(ActualTextSpan).init(arena);
    for (runs, intervals) |run, iv| {
        try mapRun(fast, arena, codepoints, glyphs, run, iv.start, iv.end, texts, &spans);
    }

    const cid_slice = try arena.alloc(u16, glyphs.len);
    for (glyphs, texts, cid_slice) |glyph, text, *cid| {
        cid.* = try cids.intern(glyph.id, text);
    }

    return .{
        .cids = cid_slice,
        .spans = try spans.toOwnedSlice(),
    };
}

const RunInterval = struct {
    start: u32,
    end: u32,
};

fn checkClusters(glyphs: []const zpdf.Glyph, n: u32) !void {
    for (glyphs) |glyph| {
        if (glyph.cluster >= n) return error.UnsupportedShaping;
    }
}

fn runIntervals(
    arena: std.mem.Allocator,
    glyphs: []const zpdf.Glyph,
    runs: []const zpdf.Run,
    n: u32,
) ![]RunInterval {
    if (runs.len == 0) {
        if (glyphs.len != 0) return error.UnsupportedShaping;
        return &.{};
    }

    const SortRun = struct {
        index: usize,
        min_c: u32,
        max_c: u32,
    };
    var items = try arena.alloc(SortRun, runs.len);
    for (runs, 0..) |run, i| {
        const end = std.math.add(u32, run.glyph_start, run.glyph_count) catch return error.UnsupportedShaping;
        if (end > glyphs.len) return error.UnsupportedShaping;
        if (run.glyph_count == 0) return error.UnsupportedShaping;
        var min_c: u32 = std.math.maxInt(u32);
        var max_c: u32 = 0;
        for (glyphs[run.glyph_start..end]) |glyph| {
            min_c = @min(min_c, glyph.cluster);
            max_c = @max(max_c, glyph.cluster);
        }
        items[i] = .{ .index = i, .min_c = min_c, .max_c = max_c };
    }

    const lessThan = struct {
        fn f(_: void, a: SortRun, b: SortRun) bool {
            if (a.min_c != b.min_c) return a.min_c < b.min_c;
            return a.index < b.index;
        }
    }.f;
    std.sort.pdq(SortRun, items, {}, lessThan);

    var i: usize = 0;
    while (i + 1 < items.len) : (i += 1) {
        if (items[i].max_c >= items[i + 1].min_c) return error.UnsupportedShaping;
    }

    var out = try arena.alloc(RunInterval, runs.len);
    for (items, 0..) |item, sorted_i| {
        const start: u32 = if (sorted_i == 0) 0 else item.min_c;
        const end: u32 = if (sorted_i + 1 == items.len) n else items[sorted_i + 1].min_c;
        out[item.index] = .{ .start = start, .end = end };
    }
    return out;
}

const Group = struct {
    start: u32,
    end: u32,
    /// kb-relative glyph indices, kept in logical order
    glyphs: ManagedList(u32),
};

fn mapRun(
    comptime fast: bool,
    arena: std.mem.Allocator,
    codepoints: []const u21,
    all_glyphs: []const zpdf.Glyph,
    run: zpdf.Run,
    cp_start: u32,
    cp_end: u32,
    texts: [][]const u21,
    spans: *ManagedList(ActualTextSpan),
) !void {
    const rtl = run.direction == @backingInt(zpdf.Direction.rtl);
    const gs = run.glyph_start;
    const gc = run.glyph_count;
    const glyphs = all_glyphs[gs .. gs + gc];

    const groups = try buildGroups(fast, arena, glyphs, gc, rtl, cp_start, cp_end);

    for (groups.items) |*group| {
        try assignTexts(fast, arena, group, glyphs, codepoints, gs, texts);
    }

    for (groups.items) |*group| {
        if (!groupNeedsActualText(group, codepoints, texts, gs)) continue;
        const lo_hi = logicalRange(group, gc, rtl);
        const kb_lo = kbIndex(rtl, gc, lo_hi.min);
        const kb_hi = kbIndex(rtl, gc, lo_hi.max);
        const a = @min(kb_lo, kb_hi);
        const b = @max(kb_lo, kb_hi);
        try spans.append(.{ .start = gs + a, .end = gs + b + 1, .text = try arena.dupe(u21, codepoints[group.start..group.end]) });
    }
}

fn buildGroups(
    comptime fast: bool,
    arena: std.mem.Allocator,
    glyphs: []const zpdf.Glyph,
    gc: u32,
    rtl: bool,
    cp_start: u32,
    cp_end: u32,
) !ManagedList(Group) {
    // Most runs have one glyph per cluster, clusters rising in logical order.
    // Then the sorted unique clusters are that sequence and group i holds the
    // i-th logical glyph alone: build it directly, without the two hash maps
    // the general case needs. Both paths give the same groups.
    if (fast) increasing: {
        var li: u32 = 1;
        while (li < gc) : (li += 1) {
            if (glyphs[kbIndex(rtl, gc, li)].cluster <= glyphs[kbIndex(rtl, gc, li - 1)].cluster) break :increasing;
        }
        var groups = try ManagedList(Group).initCapacity(arena, gc);
        li = 0;
        while (li < gc) : (li += 1) {
            const kb = kbIndex(rtl, gc, li);
            var one = try ManagedList(u32).initCapacity(arena, 1);
            one.appendAssumeCapacity(kb);
            groups.appendAssumeCapacity(.{
                .start = if (li == 0) cp_start else glyphs[kb].cluster,
                .end = if (li + 1 < gc) glyphs[kbIndex(rtl, gc, li + 1)].cluster else cp_end,
                .glyphs = one,
            });
        }
        try mergeGroupsLinear(&groups, gc, rtl);
        return groups;
    }

    var cluster_map: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    for (glyphs) |glyph| {
        try cluster_map.put(arena, glyph.cluster, {});
    }
    const unique = cluster_map.keys();
    const u32less = struct {
        fn f(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.f;
    std.sort.pdq(u32, unique, {}, u32less);

    var groups = ManagedList(Group).init(arena);

    var cluster_index: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    for (unique, 0..) |cluster, i| {
        const start: u32 = if (i == 0) cp_start else cluster;
        const end: u32 = if (i + 1 < unique.len) unique[i + 1] else cp_end;
        try cluster_index.put(arena, cluster, i);
        try groups.append(.{ .start = start, .end = end, .glyphs = ManagedList(u32).init(arena) });
    }
    var li: u32 = 0;
    while (li < gc) : (li += 1) {
        const kb = kbIndex(rtl, gc, li);
        const gi = cluster_index.get(glyphs[kb].cluster) orelse return error.UnsupportedShaping;
        try groups.items[gi].glyphs.append(kb);
    }

    try mergeGroupsLinear(&groups, gc, rtl);
    return groups;
}

fn logicalIndex(rtl: bool, gc: u32, kb: u32) u32 {
    return if (rtl) gc - 1 - kb else kb;
}

fn kbIndex(rtl: bool, gc: u32, logical: u32) u32 {
    return if (rtl) gc - 1 - logical else logical;
}

const Range = struct { min: u32, max: u32 };

fn logicalRange(group: *const Group, gc: u32, rtl: bool) Range {
    var min_l: u32 = std.math.maxInt(u32);
    var max_l: u32 = 0;
    for (group.glyphs.items) |kb| {
        const l = logicalIndex(rtl, gc, kb);
        min_l = @min(min_l, l);
        max_l = @max(max_l, l);
    }
    return .{ .min = min_l, .max = max_l };
}

/// Rule (a) is implied by rule (b) at the fixed point, so it is not applied.
/// Candidates tile the run in index order. Rule (b) merges only index-adjacent
/// classes, so classes stay contiguous index ranges. At the fixed point
/// max_l(A) < min_l(B); chained, ranges are disjoint and increasing, so every
/// slot in a class's range belongs to that class and rule (a) has nothing to
/// merge. Every merge the sweep makes is forced in any settled partition whose
/// classes are contiguous, so the result is unique and equals a219011's.
///
/// One stack sweep in candidate-index order: while the top class's first
/// glyph sits before the class below's last glyph, merge them. A merge can
/// invert with the new neighbor, so this is a loop. O(G + n).
fn mergeGroupsLinear(groups: *ManagedList(Group), gc: u32, rtl: bool) !void {
    const nG = groups.items.len;
    if (nG <= 1) return;
    const arena = groups.allocator;

    const Class = struct {
        start: u32,
        end: u32,
        min_l: u32,
        max_l: u32,
        orig_lo: u32,
        orig_hi: u32,
        n_glyphs: u32,
    };
    const stack = try arena.alloc(Class, nG);

    var sp: usize = 0;
    for (groups.items, 0..) |*g, i| {
        const lr = logicalRange(g, gc, rtl);
        var cur = Class{
            .start = g.start,
            .end = g.end,
            .min_l = lr.min,
            .max_l = lr.max,
            .orig_lo = @intCast(i),
            .orig_hi = @intCast(i),
            .n_glyphs = @intCast(g.glyphs.items.len),
        };
        while (sp > 0) {
            const below = stack[sp - 1];
            if (cur.min_l < below.max_l) {
                sp -= 1;
                cur = .{
                    .start = @min(below.start, cur.start),
                    .end = @max(below.end, cur.end),
                    .min_l = @min(below.min_l, cur.min_l),
                    .max_l = @max(below.max_l, cur.max_l),
                    .orig_lo = below.orig_lo,
                    .orig_hi = cur.orig_hi,
                    .n_glyphs = below.n_glyphs + cur.n_glyphs,
                };
            } else break;
        }
        stack[sp] = cur;
        sp += 1;
    }

    var out = ManagedList(Group).init(arena);
    try out.ensureTotalCapacity(sp);

    const out_of = try arena.alloc(usize, nG);
    for (stack[0..sp], 0..) |c, oi| {
        out.appendAssumeCapacity(.{
            .start = c.start,
            .end = c.end,
            .glyphs = ManagedList(u32).init(arena),
        });
        try out.items[oi].glyphs.ensureTotalCapacity(c.n_glyphs);
        var k = c.orig_lo;
        while (k <= c.orig_hi) : (k += 1) {
            out_of[k] = oi;
        }
    }

    const owner = try arena.alloc(u32, gc);
    for (groups.items, 0..) |*g, gi| {
        for (g.glyphs.items) |kb| {
            owner[logicalIndex(rtl, gc, kb)] = @intCast(gi);
        }
    }
    var li: u32 = 0;
    while (li < gc) : (li += 1) {
        out.items[out_of[owner[li]]].glyphs.appendAssumeCapacity(kbIndex(rtl, gc, li));
    }

    groups.* = out;
}

fn utf16Units(cps: []const u21) usize {
    var n: usize = 0;
    // Every u21 here was decoded from valid UTF-8, so it is at most U+10FFFF.
    for (cps) |cp| n += std.unicode.utf16CodepointSequenceLength(cp) catch unreachable;
    return n;
}

fn assignTexts(
    comptime fast: bool,
    arena: std.mem.Allocator,
    group: *const Group,
    glyphs: []const zpdf.Glyph,
    codepoints: []const u21,
    glyph_start: u32,
    texts: [][]const u21,
) !void {
    // One glyph: its cluster runs to the group's end and it is the first
    // glyph of its cluster, which is what the general path below computes.
    if (fast and group.glyphs.items.len == 1) {
        const kb = group.glyphs.items[0];
        const slice = codepoints[glyphs[kb].cluster..group.end];
        texts[glyph_start + kb] = if (utf16Units(slice) <= 256) slice else &.{};
        return;
    }
    var cluster_next: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var clusters = ManagedList(u32).init(arena);
    for (group.glyphs.items) |kb| {
        const c = glyphs[kb].cluster;
        const gop = try cluster_next.getOrPut(arena, c);
        if (!gop.found_existing) try clusters.append(c);
        gop.value_ptr.* = 0;
    }
    const cless = struct {
        fn f(_: void, a: u32, b: u32) bool {
            return a < b;
        }
    }.f;
    std.sort.pdq(u32, clusters.items, {}, cless);
    for (clusters.items, 0..) |cluster, ci| {
        const next: u32 = if (ci + 1 < clusters.items.len) clusters.items[ci + 1] else group.end;
        cluster_next.getPtr(cluster).?.* = next;
    }

    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (group.glyphs.items) |kb| {
        const cluster = glyphs[kb].cluster;
        const to = cluster_next.get(cluster).?;
        const slice = codepoints[cluster..to];
        const first = seen.get(cluster) == null;
        try seen.put(arena, cluster, {});
        const abs = glyph_start + kb;
        // Only the first glyph of a cluster gets text, so only it pays for
        // the length check. Checking every glyph is O(glyphs x codepoints)
        // when one cluster spans many of both.
        // The text points into `codepoints`; the CID registry copies it.
        texts[abs] = if (first and utf16Units(slice) <= 256) slice else &.{};
    }
}

fn groupNeedsActualText(
    group: *const Group,
    codepoints: []const u21,
    texts: []const []const u21,
    glyph_start: u32,
) bool {
    var joined_len: usize = 0;
    var any_empty = false;
    for (group.glyphs.items) |kb| {
        const t = texts[glyph_start + kb];
        if (t.len == 0) any_empty = true;
        joined_len += t.len;
    }
    if (any_empty) return true;
    if (joined_len != group.end - group.start) return true;
    var off: usize = 0;
    for (group.glyphs.items) |kb| {
        const t = texts[glyph_start + kb];
        const want = codepoints[group.start..group.end][off .. off + t.len];
        if (!std.mem.eql(u21, t, want)) return true;
        off += t.len;
    }
    return false;
}

pub fn writeUtf16BeHex(w: *std.Io.Writer, cps: []const u21, bom: bool) !void {
    if (bom) try w.writeAll("FEFF");
    for (cps) |cp| {
        if (cp >= 0x10000) {
            const u = cp - 0x10000;
            const hi: u16 = @intCast(0xD800 + (u >> 10));
            const lo: u16 = @intCast(0xDC00 + (u & 0x3FF));
            try w.print("{X:0>4}{X:0>4}", .{ hi, lo });
        } else {
            try w.print("{X:0>4}", .{@as(u16, @intCast(cp))});
        }
    }
}

pub fn writeToUnicode(w: *std.Io.Writer, cids: *const CidRegistry) !void {
    try w.writeAll(
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        \\/CMapName /Adobe-Identity-UCS def
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\
    );
    var mapped: usize = 0;
    for (1..cids.count() + 1) |cid| {
        if (cids.textForCid(@intCast(cid)).len != 0) mapped += 1;
    }
    var remaining = mapped;
    var cid: usize = 1;
    while (remaining > 0) {
        const chunk: usize = @min(remaining, 100);
        try w.print("{d} beginbfchar\n", .{chunk});
        var written: usize = 0;
        while (cid <= cids.count() and written < chunk) : (cid += 1) {
            const text = cids.textForCid(@intCast(cid));
            if (text.len == 0) continue;
            try w.writeByte('<');
            try w.print("{X:0>4}", .{@as(u16, @intCast(cid))});
            try w.writeAll("> <");
            try writeUtf16BeHex(w, text, false);
            try w.writeAll(">\n");
            written += 1;
            remaining -= 1;
        }
        try w.writeAll("endbfchar\n");
    }
    try w.writeAll(
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    );
}

/// a219011 merge, frozen as the test oracle. Same control flow as the code at
/// that commit. The Stats writes are kept only to stay close to a219011;
/// nothing reads them. The drift guard is `Diff.stackOutcome` and the two
/// gates at the end of the differential test.
const RefMerge = if (!@import("builtin").is_test) struct {} else struct {
    const Self = @This();
    const Stats = struct {
        rule_a: bool = false,
        interval: bool = false,
        rule_b: bool = false,
    };

    fn buildGroups(
        gpa: std.mem.Allocator,
        glyphs: []const zpdf.Glyph,
        gc: u32,
        rtl: bool,
        cp_start: u32,
        cp_end: u32,
        stats: *Stats,
    ) !ManagedList(Group) {
        var cluster_map: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        defer cluster_map.deinit(gpa);
        for (glyphs) |glyph| {
            try cluster_map.put(gpa, glyph.cluster, {});
        }
        const unique = try gpa.dupe(u32, cluster_map.keys());
        defer gpa.free(unique);
        const u32less = struct {
            fn f(_: void, a: u32, b: u32) bool {
                return a < b;
            }
        }.f;
        std.sort.pdq(u32, unique, {}, u32less);

        var groups = ManagedList(Group).init(gpa);
        errdefer {
            for (groups.items) |*group| group.glyphs.deinit();
            groups.deinit();
        }

        var cluster_index: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer cluster_index.deinit(gpa);
        for (unique, 0..) |cluster, i| {
            const start: u32 = if (i == 0) cp_start else cluster;
            const end: u32 = if (i + 1 < unique.len) unique[i + 1] else cp_end;
            try cluster_index.put(gpa, cluster, i);
            try groups.append(.{ .start = start, .end = end, .glyphs = ManagedList(u32).init(gpa) });
        }
        var li: u32 = 0;
        while (li < gc) : (li += 1) {
            const kb = kbIndex(rtl, gc, li);
            const gi = cluster_index.get(glyphs[kb].cluster) orelse return error.UnsupportedShaping;
            try groups.items[gi].glyphs.append(kb);
        }

        while (true) {
            if (try Self.mergeNonConsecutive(&groups, gc, rtl, stats)) continue;
            if (try Self.mergeOverlappingLogical(&groups, gc, rtl, stats)) continue;
            break;
        }
        return groups;
    }

    fn logicalRange(group: *const Group, gc: u32, rtl: bool) Range {
        var min_l: u32 = std.math.maxInt(u32);
        var max_l: u32 = 0;
        for (group.glyphs.items) |kb| {
            const l = logicalIndex(rtl, gc, kb);
            min_l = @min(min_l, l);
            max_l = @max(max_l, l);
        }
        return .{ .min = min_l, .max = max_l };
    }

    fn isConsecutive(group: *const Group, gc: u32, rtl: bool) bool {
        if (group.glyphs.items.len == 0) return true;
        const lr = Self.logicalRange(group, gc, rtl);
        const span = lr.max - lr.min + 1;
        if (span != group.glyphs.items.len) return false;
        var slot: u32 = lr.min;
        while (slot <= lr.max) : (slot += 1) {
            const kb = kbIndex(rtl, gc, slot);
            var found = false;
            for (group.glyphs.items) |gkb| {
                if (gkb == kb) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn mergeNonConsecutive(groups: *ManagedList(Group), gc: u32, rtl: bool, stats: *Stats) !bool {
        var i: usize = 0;
        while (i < groups.items.len) : (i += 1) {
            if (Self.isConsecutive(&groups.items[i], gc, rtl)) continue;
            const lr = Self.logicalRange(&groups.items[i], gc, rtl);
            var merge = try std.DynamicBitSet.initEmpty(groups.allocator, groups.items.len);
            defer merge.deinit();
            merge.set(i);
            var j: usize = 0;
            while (j < groups.items.len) : (j += 1) {
                if (j == i) continue;
                for (groups.items[j].glyphs.items) |kb| {
                    const l = logicalIndex(rtl, gc, kb);
                    if (l > lr.min and l < lr.max) {
                        merge.set(j);
                        break;
                    }
                }
            }
            var min_s = groups.items[i].start;
            var max_e = groups.items[i].end;
            j = 0;
            while (j < groups.items.len) : (j += 1) {
                if (!merge.isSet(j)) continue;
                min_s = @min(min_s, groups.items[j].start);
                max_e = @max(max_e, groups.items[j].end);
            }
            j = 0;
            while (j < groups.items.len) : (j += 1) {
                if (groups.items[j].start >= min_s and groups.items[j].end <= max_e) {
                    if (!merge.isSet(j)) stats.interval = true;
                    merge.set(j);
                }
            }
            if (merge.count() > 1) {
                stats.rule_a = true;
                try Self.collapse(groups, &merge, gc, rtl);
                return true;
            }
        }
        return false;
    }

    fn mergeOverlappingLogical(groups: *ManagedList(Group), gc: u32, rtl: bool, stats: *Stats) !bool {
        if (groups.items.len < 2) return false;
        const Order = struct {
            fn f(ctx: *ManagedList(Group), a: usize, b: usize) bool {
                const ga = ctx.items[a];
                const gb = ctx.items[b];
                if (ga.start != gb.start) return ga.start < gb.start;
                return ga.end < gb.end;
            }
        };
        const order = try groups.allocator.alloc(usize, groups.items.len);
        defer groups.allocator.free(order);
        for (order, 0..) |*o, k| o.* = k;
        const less = struct {
            fn f(ctx: *ManagedList(Group), a: usize, b: usize) bool {
                return Order.f(ctx, a, b);
            }
        }.f;
        std.sort.pdq(usize, order, groups, less);

        var k: usize = 1;
        while (k < order.len) : (k += 1) {
            const prev = &groups.items[order[k - 1]];
            const cur = &groups.items[order[k]];
            if (prev.glyphs.items.len == 0 or cur.glyphs.items.len == 0) continue;
            const prev_last = Self.logicalRange(prev, gc, rtl).max;
            const cur_first = Self.logicalRange(cur, gc, rtl).min;
            if (cur_first < prev_last) {
                var merge = try std.DynamicBitSet.initEmpty(groups.allocator, groups.items.len);
                defer merge.deinit();
                merge.set(order[k - 1]);
                merge.set(order[k]);
                stats.rule_b = true;
                try Self.collapse(groups, &merge, gc, rtl);
                return true;
            }
        }
        return false;
    }

    fn collapse(groups: *ManagedList(Group), merge: *const std.DynamicBitSet, gc: u32, rtl: bool) !void {
        var survivor: ?usize = null;
        var j: usize = 0;
        while (j < groups.items.len) : (j += 1) {
            if (merge.isSet(j)) {
                survivor = j;
                break;
            }
        }
        const s = survivor orelse return;
        var k: usize = groups.items.len;
        while (k > 0) {
            k -= 1;
            if (k == s or !merge.isSet(k)) continue;
            groups.items[s].start = @min(groups.items[s].start, groups.items[k].start);
            groups.items[s].end = @max(groups.items[s].end, groups.items[k].end);
            try groups.items[s].glyphs.appendSlice(groups.items[k].glyphs.items);
            groups.items[k].glyphs.deinit();
            _ = groups.orderedRemove(k);
        }
        const LogicalCtx = struct { gc: u32, rtl: bool };
        const lessKbLogical = struct {
            fn f(ctx: LogicalCtx, a: u32, b: u32) bool {
                const la = logicalIndex(ctx.rtl, ctx.gc, a);
                const lb = logicalIndex(ctx.rtl, ctx.gc, b);
                return la < lb;
            }
        }.f;
        std.sort.pdq(u32, groups.items[s].glyphs.items, LogicalCtx{ .gc = gc, .rtl = rtl }, lessKbLogical);
    }

    fn expectEqual(got: []const Group, want: []const Group) !void {
        try std.testing.expectEqual(want.len, got.len);
        for (got, want) |g, w| {
            try std.testing.expectEqual(w.start, g.start);
            try std.testing.expectEqual(w.end, g.end);
            try std.testing.expectEqualSlices(u32, w.glyphs.items, g.glyphs.items);
        }
    }

    fn toGlyphs(gpa: std.mem.Allocator, clusters: []const u32) ![]zpdf.Glyph {
        const glyphs = try gpa.alloc(zpdf.Glyph, clusters.len);
        for (clusters, glyphs, 0..) |cluster, *glyph, i| {
            glyph.* = .{
                .id = @intCast(i % 65535),
                ._reserved0 = 0,
                .cluster = cluster,
                .advance_x = 0,
                .advance_y = 0,
                .offset_x = 0,
                .offset_y = 0,
            };
        }
        return glyphs;
    }
};

test "Hangul: one group, second glyph no text, ActualText" {
    const H = struct {
        fn glyph(id: u16, cluster: u32) zpdf.Glyph {
            return .{ .id = id, ._reserved0 = 0, .cluster = cluster, .advance_x = 0, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
        }
        fn run(dir: zpdf.Direction, start: u32, count: u32) zpdf.Run {
            return .{ .direction = @backingInt(dir), .script = 0, .glyph_start = start, .glyph_count = count, .paragraph_direction = @backingInt(zpdf.Direction.ltr) };
        }
    };
    const cps = [_]u21{ 0x115F, 0x11A2 };
    const glyphs = [_]zpdf.Glyph{ H.glyph(3, 0), H.glyph(4, 0) };
    const runs = [_]zpdf.Run{H.run(.ltr, 0, 2)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqualSlices(u21, &.{ 0x115F, 0x11A2 }, cids.textForCid(mapped.cids[0]));
    try std.testing.expectEqual(@as(usize, 0), cids.textForCid(mapped.cids[1]).len);
    try std.testing.expectEqual(@as(usize, 1), mapped.spans.len);
    try std.testing.expectEqual(@as(u32, 0), mapped.spans[0].start);
    try std.testing.expectEqual(@as(u32, 2), mapped.spans[0].end);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUtf16BeHex(&w, mapped.spans[0].text, true);
    try std.testing.expectEqualStrings("FEFF115F11A2", w.buffered());
    try std.testing.expectEqual(@as(u16, 1), mapped.cids[0]);
    try std.testing.expectEqual(@as(u16, 2), mapped.cids[1]);
}

test "legacy Indic: merge then split before the vowel sign" {
    const H = struct {
        fn glyph(id: u16, cluster: u32) zpdf.Glyph {
            return .{ .id = id, ._reserved0 = 0, .cluster = cluster, .advance_x = 0, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
        }
        fn run(dir: zpdf.Direction, start: u32, count: u32) zpdf.Run {
            return .{ .direction = @backingInt(dir), .script = 0, .glyph_start = start, .glyph_count = count, .paragraph_direction = @backingInt(zpdf.Direction.ltr) };
        }
    };
    const cps = [_]u21{ 0x0904, 0x0020, 0x0905, 0x0946 };
    const glyphs = [_]zpdf.Glyph{ H.glyph(2, 0), H.glyph(1, 1), H.glyph(3, 2), H.glyph(40, 0), H.glyph(23, 3) };
    const runs = [_]zpdf.Run{H.run(.ltr, 0, 5)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqualSlices(u21, &.{0x0904}, cids.textForCid(mapped.cids[0]));
    try std.testing.expectEqualSlices(u21, &.{0x0020}, cids.textForCid(mapped.cids[1]));
    try std.testing.expectEqualSlices(u21, &.{0x0905}, cids.textForCid(mapped.cids[2]));
    try std.testing.expectEqual(@as(usize, 0), cids.textForCid(mapped.cids[3]).len);
    try std.testing.expectEqualSlices(u21, &.{0x0946}, cids.textForCid(mapped.cids[4]));

    try std.testing.expectEqual(@as(usize, 1), mapped.spans.len);
    try std.testing.expectEqual(@as(u32, 0), mapped.spans[0].start);
    try std.testing.expectEqual(@as(u32, 4), mapped.spans[0].end);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUtf16BeHex(&w, mapped.spans[0].text, true);
    try std.testing.expectEqualStrings("FEFF090400200905", w.buffered());
}

test "USE: dotted circle shares the base cluster" {
    const H = struct {
        fn glyph(id: u16, cluster: u32) zpdf.Glyph {
            return .{ .id = id, ._reserved0 = 0, .cluster = cluster, .advance_x = 0, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
        }
        fn run(dir: zpdf.Direction, start: u32, count: u32) zpdf.Run {
            return .{ .direction = @backingInt(dir), .script = 0, .glyph_start = start, .glyph_count = count, .paragraph_direction = @backingInt(zpdf.Direction.ltr) };
        }
    };
    const cps = [_]u21{ 0x0905, 0x093A };
    const glyphs = [_]zpdf.Glyph{ H.glyph(1, 0), H.glyph(87, 0), H.glyph(7, 1) };
    const runs = [_]zpdf.Run{H.run(.ltr, 0, 3)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqualSlices(u21, &.{0x0905}, cids.textForCid(mapped.cids[0]));
    try std.testing.expectEqual(@as(usize, 0), cids.textForCid(mapped.cids[1]).len);
    try std.testing.expectEqualSlices(u21, &.{0x093A}, cids.textForCid(mapped.cids[2]));
    try std.testing.expectEqual(@as(usize, 1), mapped.spans.len);
    try std.testing.expectEqual(@as(u32, 0), mapped.spans[0].start);
    try std.testing.expectEqual(@as(u32, 2), mapped.spans[0].end);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUtf16BeHex(&w, mapped.spans[0].text, true);
    try std.testing.expectEqualStrings("FEFF0905", w.buffered());
}

test "RTL two groups both get ActualText in kb order" {
    // n=4, kb order 20@2 21@2 10@0 11@0. Logical groups [0,2) and [2,4)
    // each have a no-text glyph, so both need a span. Spans are appended
    // in logical order (reverse of kb), which writeDrawOp must still find.
    const cps = [_]u21{ 'a', 'b', 'c', 'd' };
    const glyphs = [_]zpdf.Glyph{
        MapH.glyph(20, 2), MapH.glyph(21, 2), MapH.glyph(10, 0), MapH.glyph(11, 0),
    };
    const runs = [_]zpdf.Run{MapH.run(.rtl, 0, 4)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqual(@as(usize, 2), mapped.spans.len);
    try std.testing.expectEqual(@as(u32, 2), mapped.spans[0].start);
    try std.testing.expectEqual(@as(u32, 4), mapped.spans[0].end);
    try std.testing.expectEqual(@as(u32, 0), mapped.spans[1].start);
    try std.testing.expectEqual(@as(u32, 2), mapped.spans[1].end);
}

test "ZWNJ RTL: no span, two CIDs for one GID" {
    const H = struct {
        fn glyph(id: u16, cluster: u32) zpdf.Glyph {
            return .{ .id = id, ._reserved0 = 0, .cluster = cluster, .advance_x = 0, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
        }
        fn run(dir: zpdf.Direction, start: u32, count: u32) zpdf.Run {
            return .{ .direction = @backingInt(dir), .script = 0, .glyph_start = start, .glyph_count = count, .paragraph_direction = @backingInt(zpdf.Direction.ltr) };
        }
    };
    const cps = [_]u21{ 0x0628, 0x200C, 0x0628 };
    const glyphs = [_]zpdf.Glyph{ H.glyph(1, 2), H.glyph(1, 0) };
    const runs = [_]zpdf.Run{H.run(.rtl, 0, 2)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqualSlices(u21, &.{0x0628}, cids.textForCid(mapped.cids[0]));
    try std.testing.expectEqualSlices(u21, &.{ 0x0628, 0x200C }, cids.textForCid(mapped.cids[1]));
    try std.testing.expectEqual(@as(usize, 0), mapped.spans.len);
    try std.testing.expect(mapped.cids[0] != mapped.cids[1]);
    try std.testing.expectEqual(cids.gidForCid(mapped.cids[0]), @as(u16, 1));
    try std.testing.expectEqual(cids.gidForCid(mapped.cids[1]), @as(u16, 1));
}

test "intern of 65536 distinct pairs is TooManyCids" {
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var gid: u32 = 0;
    while (gid < 65535) : (gid += 1) {
        const cid = try cids.intern(@intCast(gid), &.{});
        try std.testing.expectEqual(gid + 1, cid);
    }
    try std.testing.expectError(error.TooManyCids, cids.intern(65535, &.{}));
    try std.testing.expectEqual(@as(usize, 65535), cids.count());
}

const MapH = if (!@import("builtin").is_test) struct {} else struct {
    fn glyph(id: u16, cluster: u32) zpdf.Glyph {
        return .{ .id = id, ._reserved0 = 0, .cluster = cluster, .advance_x = 0, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
    }
    fn run(dir: zpdf.Direction, start: u32, count: u32) zpdf.Run {
        return .{ .direction = @backingInt(dir), .script = 0, .glyph_start = start, .glyph_count = count, .paragraph_direction = @backingInt(zpdf.Direction.ltr) };
    }
};

test "writeToUnicode splits bfchar at 100 and skips empty text" {
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var i: u16 = 0;
    while (i < 101) : (i += 1) {
        const text = [_]u21{'A'};
        _ = try cids.intern(i, &text);
    }
    _ = try cids.intern(200, &.{});
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeToUnicode(&aw.writer, &cids);
    const cmap = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, cmap, "100 beginbfchar") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "1 beginbfchar") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "101 beginbfchar") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmap, "<00C9>") == null); // CID 201 would be 0xC9; empty pair is CID 102 = 0x66
    try std.testing.expect(std.mem.indexOf(u8, cmap, "<0066>") == null);
}

test "writeToUnicode writes a surrogate pair for a codepoint above U+FFFF" {
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    _ = try cids.intern(1, &.{0x1F600});
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeToUnicode(&aw.writer, &cids);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "<0001> <D83DDE00>") != null);
}

test "merge rule (b): later interval whose first glyph is before the previous last" {
    // Each group is consecutive; rule (a) does not fire. Cluster 2's glyph sits
    // logically before cluster 1's, so (b) merges them.
    const cps = [_]u21{ 0x0904, 0x0905, 0x0906, 0x0907 };
    const glyphs = [_]zpdf.Glyph{ MapH.glyph(2, 0), MapH.glyph(1, 2), MapH.glyph(3, 1) };
    const runs = [_]zpdf.Run{MapH.run(.ltr, 0, 3)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqual(@as(usize, 1), mapped.spans.len);
    try std.testing.expectEqual(@as(u32, 1), mapped.spans[0].start);
    try std.testing.expectEqual(@as(u32, 3), mapped.spans[0].end);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUtf16BeHex(&w, mapped.spans[0].text, true);
    try std.testing.expectEqualStrings("FEFF090509060907", w.buffered());
}

test "merge rule (a): interval that lies between a non-consecutive group" {
    // Cluster 0's glyphs are not consecutive. Cluster 1's glyph is outside
    // that logical hole, but its interval sits inside the merged range.
    const cps = [_]u21{ 0x0904, 0x0905, 0x0906, 0x0907 };
    const glyphs = [_]zpdf.Glyph{ MapH.glyph(1, 0), MapH.glyph(2, 2), MapH.glyph(3, 0), MapH.glyph(4, 1) };
    const runs = [_]zpdf.Run{MapH.run(.ltr, 0, 4)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqual(@as(usize, 1), mapped.spans.len);
    try std.testing.expectEqual(@as(u32, 0), mapped.spans[0].start);
    try std.testing.expectEqual(@as(u32, 4), mapped.spans[0].end);
}

test "several runs get disjoint intervals" {
    const cps = [_]u21{ 0x0041, 0x0042, 0x05D0, 0x05D1 };
    const glyphs = [_]zpdf.Glyph{ MapH.glyph(10, 0), MapH.glyph(20, 2) };
    const runs = [_]zpdf.Run{ MapH.run(.ltr, 0, 1), MapH.run(.rtl, 1, 1) };
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqualSlices(u21, &.{ 0x0041, 0x0042 }, cids.textForCid(mapped.cids[0]));
    try std.testing.expectEqualSlices(u21, &.{ 0x05D0, 0x05D1 }, cids.textForCid(mapped.cids[1]));
    try std.testing.expectEqual(@as(usize, 0), mapped.spans.len);
}

test "interleaved run clusters are UnsupportedShaping" {
    const cps = [_]u21{ 0x0041, 0x0042, 0x0043 };
    const glyphs = [_]zpdf.Glyph{ MapH.glyph(1, 0), MapH.glyph(2, 2), MapH.glyph(3, 1) };
    const runs = [_]zpdf.Run{ MapH.run(.ltr, 0, 2), MapH.run(.ltr, 2, 1) };
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    try std.testing.expectError(error.UnsupportedShaping, map(map_arena.allocator(), &cps, &glyphs, &runs, &cids));
}

test "text longer than 256 UTF-16 units becomes no text and ActualText" {
    var cps: [257]u21 = undefined;
    @memset(&cps, 'A');
    const glyphs = [_]zpdf.Glyph{MapH.glyph(1, 0)};
    const runs = [_]zpdf.Run{MapH.run(.ltr, 0, 1)};
    var cids = CidRegistry.init(std.testing.allocator);
    defer cids.deinit();
    var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer map_arena.deinit();
    const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);

    try std.testing.expectEqual(@as(usize, 0), cids.textForCid(mapped.cids[0]).len);
    try std.testing.expectEqual(@as(usize, 1), mapped.spans.len);
    try std.testing.expectEqual(@as(usize, 257), mapped.spans[0].text.len);
}

test "the 256-unit limit counts a codepoint above U+FFFF as two units" {
    // 128 astral codepoints are exactly 256 UTF-16 units; 129 are 258.
    inline for (.{ 128, 129 }) |n| {
        var cps: [n]u21 = undefined;
        @memset(&cps, 0x1F600);
        const glyphs = [_]zpdf.Glyph{MapH.glyph(1, 0)};
        const runs = [_]zpdf.Run{MapH.run(.ltr, 0, 1)};
        var cids = CidRegistry.init(std.testing.allocator);
        defer cids.deinit();
        var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer map_arena.deinit();
        const mapped = try map(map_arena.allocator(), &cps, &glyphs, &runs, &cids);
        const want: usize = if (n == 128) n else 0;
        try std.testing.expectEqual(want, cids.textForCid(mapped.cids[0]).len);
    }
}

test "utf8ToCodepoints decodes UTF-8 and rejects what is not UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(u21, &.{ 'a', 0xE9, 0x0915, 0x1F600 }, try utf8ToCodepoints(a, "a\u{E9}\u{0915}\u{1F600}"));
    try std.testing.expectError(error.InvalidUtf8, utf8ToCodepoints(a, "\xff"));
    // A truncated sequence, an overlong encoding, and an encoded surrogate.
    try std.testing.expectError(error.InvalidUtf8, utf8ToCodepoints(a, "a\xe0\xa4"));
    try std.testing.expectError(error.InvalidUtf8, utf8ToCodepoints(a, "\xc0\xaf"));
    try std.testing.expectError(error.InvalidUtf8, utf8ToCodepoints(a, "\xed\xa0\x80"));
}

const Diff = if (!@import("builtin").is_test) struct {} else struct {
    fn origRanges(
        clusters: []const u32,
        rtl: bool,
        unique: []u32,
        min_l: []u32,
        max_l: []u32,
    ) usize {
        const n: u32 = @intCast(clusters.len);
        @memcpy(unique[0..clusters.len], clusters);
        const u32less = struct {
            fn f(_: void, a: u32, b: u32) bool {
                return a < b;
            }
        }.f;
        std.sort.pdq(u32, unique[0..clusters.len], {}, u32less);
        var g: usize = 0;
        for (unique[0..clusters.len]) |c| {
            if (g == 0 or unique[g - 1] != c) {
                unique[g] = c;
                min_l[g] = std.math.maxInt(u32);
                max_l[g] = 0;
                g += 1;
            }
        }
        var idx: [512]u32 = undefined;
        for (unique[0..g], 0..) |c, i| idx[c] = @intCast(i);
        for (clusters, 0..) |c, kb| {
            const logical: u32 = if (rtl) n - 1 - @as(u32, @intCast(kb)) else @intCast(kb);
            const gi = idx[c];
            min_l[gi] = @min(min_l[gi], logical);
            max_l[gi] = @max(max_l[gi], logical);
        }
        return g;
    }

    fn stackOutcome(min_l: []const u32, max_l: []const u32) struct { remain: usize, merged: bool, cascaded: bool } {
        var smin: [512]u32 = undefined;
        var smax: [512]u32 = undefined;
        var sp: usize = 0;
        var n_merges: usize = 0;
        var cascaded = false;
        for (min_l, max_l) |mn, mx| {
            var cmin = mn;
            var cmax = mx;
            while (sp > 0 and cmin < smax[sp - 1]) {
                n_merges += 1;
                sp -= 1;
                cmin = @min(smin[sp], cmin);
                cmax = @max(smax[sp], cmax);
                if (sp > 0 and cmin < smax[sp - 1]) cascaded = true;
            }
            smin[sp] = cmin;
            smax[sp] = cmax;
            sp += 1;
        }
        return .{ .remain = sp, .merged = n_merges > 0, .cascaded = cascaded };
    }

    fn fillMostlySorted(rng: std.Random, buf: []u32) []u32 {
        const n = rng.intRangeAtMost(u32, 100, 400);
        const out = buf[0..n];
        for (out, 0..) |*c, i| c.* = @intCast(i);
        const n_swaps = rng.intRangeAtMost(u32, 4, 16);
        var s: u32 = 0;
        while (s < n_swaps) : (s += 1) {
            const i = rng.uintLessThan(u32, n - 1);
            const tmp = out[i];
            out[i] = out[i + 1];
            out[i + 1] = tmp;
        }
        const n_dups = rng.uintAtMost(u32, 8);
        var d: u32 = 0;
        while (d < n_dups) : (d += 1) {
            const i = rng.uintLessThan(u32, n - 1);
            out[i + 1] = out[i];
        }
        return out;
    }

    fn fillScatteredReverse(rng: std.Random, buf: []u32) []u32 {
        const n = rng.intRangeAtMost(u32, 120, 360);
        const out = buf[0..n];
        for (out, 0..) |*c, i| c.* = @intCast(i);
        var p: u32 = rng.uintLessThan(u32, 12);
        while (p + 2 < n) {
            // Logical [p+2, p, p+1]: merge of the last two then cascades into the class below.
            const a = out[p];
            const b = out[p + 1];
            const c = out[p + 2];
            out[p] = c;
            out[p + 1] = a;
            out[p + 2] = b;
            p += 18 + rng.uintAtMost(u32, 12);
        }
        return out;
    }
};

test "buildGroups matches a219011 merge on generated LTR and RTL runs" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(3184);
    const rng = prng.random();

    var n_long: u32 = 0;
    var n_b_remain: u32 = 0;
    var n_cascade: u32 = 0;
    var leak_left: u32 = 32;

    var cluster_buf: [400]u32 = undefined;
    var unique_buf: [400]u32 = undefined;
    var min_l_buf: [400]u32 = undefined;
    var max_l_buf: [400]u32 = undefined;

    const Case = struct {
        stats: RefMerge.Stats,
        n_groups: usize,

        fn run(
            gpa: std.mem.Allocator,
            clusters: []const u32,
            cp_start: u32,
            cp_end: u32,
            rtl: bool,
            leak: bool,
        ) !@This() {
            const glyphs = try RefMerge.toGlyphs(gpa, clusters);
            defer if (leak) gpa.free(glyphs);
            const gc: u32 = @intCast(glyphs.len);
            var stats = RefMerge.Stats{};
            var want = try RefMerge.buildGroups(gpa, glyphs, gc, rtl, cp_start, cp_end, &stats);
            defer if (leak) {
                for (want.items) |*group| group.glyphs.deinit();
                want.deinit();
            };
            // Production buildGroups is one operation on an arena; only the
            // frozen oracle frees, so only it is leak-checked.
            var got_arena: std.heap.ArenaAllocator = .init(gpa);
            defer got_arena.deinit();
            const got = try buildGroups(true, got_arena.allocator(), glyphs, gc, rtl, cp_start, cp_end);
            try RefMerge.expectEqual(got.items, want.items);
            const general = try buildGroups(false, got_arena.allocator(), glyphs, gc, rtl, cp_start, cp_end);
            try RefMerge.expectEqual(general.items, want.items);
            return .{ .stats = stats, .n_groups = want.items.len };
        }
    };

    var n_g: u32 = 1;
    while (n_g <= 6) : (n_g += 1) {
        var n_cp: u32 = 1;
        while (n_cp <= 6) : (n_cp += 1) {
            const total = std.math.pow(u32, n_cp, n_g);
            var enc: u32 = 0;
            while (enc < total) : (enc += 1) {
                var x = enc;
                var i: u32 = 0;
                while (i < n_g) : (i += 1) {
                    cluster_buf[i] = x % n_cp;
                    x /= n_cp;
                }
                const clusters = cluster_buf[0..n_g];
                for ([2]bool{ false, true }) |rtl| {
                    const leak = leak_left > 0;
                    if (leak) leak_left -= 1;
                    const gpa = if (leak) std.testing.allocator else arena.allocator();
                    _ = try Case.run(gpa, clusters, 0, n_cp, rtl, leak);
                    if (!leak) _ = arena.reset(.retain_capacity);
                }
            }
        }
    }

    var long_i: u32 = 0;
    while (long_i < 2500) : (long_i += 1) {
        const clusters = if (long_i % 2 == 0)
            Diff.fillMostlySorted(rng, &cluster_buf)
        else
            Diff.fillScatteredReverse(rng, &cluster_buf);
        const rtl = rng.boolean();
        if (rtl) std.mem.reverse(u32, clusters);
        var max_c: u32 = 0;
        for (clusters) |c| max_c = @max(max_c, c);
        const gpa = arena.allocator();
        const outcome = try Case.run(gpa, clusters, 0, max_c + 1, rtl, false);
        n_long += 1;
        const g = Diff.origRanges(clusters, rtl, &unique_buf, &min_l_buf, &max_l_buf);
        const st = Diff.stackOutcome(min_l_buf[0..g], max_l_buf[0..g]);
        try std.testing.expectEqual(st.remain, outcome.n_groups);
        if (st.merged and st.remain >= 3) n_b_remain += 1;
        if (st.cascaded) n_cascade += 1;
        _ = arena.reset(.retain_capacity);
    }

    try std.testing.expect(n_b_remain * 2 > n_long);
    try std.testing.expect(n_cascade * 4 > n_long);
}

test "map fails cleanly at every allocation, in its arena and in the CID registry" {
    // map is one operation on an arena, so checkAllAllocationFailures (which
    // counts unfreed bytes as leaks) does not fit. Inject above the arena,
    // where each of map's allocations is visible, and separately in the CID
    // registry, which owns its memory.
    const cps = [_]u21{ 'a', 'b', 'c' };
    const glyphs = [_]zpdf.Glyph{
        MapH.glyph(1, 2), MapH.glyph(2, 0), MapH.glyph(3, 1),
    };
    const runs = [_]zpdf.Run{MapH.run(.ltr, 0, 3)};
    for ([_]bool{ false, true }) |fail_registry| {
        var n_failed: usize = 0;
        var i: usize = 0;
        while (true) : (i += 1) {
            var map_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer map_arena.deinit();
            var failing = std.testing.FailingAllocator.init(
                if (fail_registry) std.testing.allocator else map_arena.allocator(),
                .{},
            );
            var cids = CidRegistry.init(if (fail_registry) failing.allocator() else std.testing.allocator);
            defer cids.deinit();
            _ = try cids.intern(9, &.{'z'});
            const before = cids.count();
            failing.fail_index = failing.alloc_index + i;
            const arena = if (fail_registry) map_arena.allocator() else failing.allocator();
            if (map(arena, &cps, &glyphs, &runs, &cids)) |mapped| {
                try std.testing.expect(!failing.has_induced_failure);
                try std.testing.expectEqual(glyphs.len, mapped.cids.len);
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
                // drawText truncates the registry on failure; check it still can.
                cids.truncate(before);
                try std.testing.expectEqual(before, cids.count());
                n_failed += 1;
            }
        }
        try std.testing.expect(n_failed > 0);
    }
}

test "map: fast and general paths agree on real shaped text" {
    const options = @import("build_options");
    const gpa = std.testing.allocator;
    const Source = struct { font: []const u8, file: []const u8, tsv: bool };
    // Latin, Devanagari (conjuncts, reph), Arabic, Hebrew with niqqud, and the
    // 1,422 mixed-direction bidi lines in three paragraph directions.
    const sources = [_]Source{
        .{ .font = options.test_font_roboto, .file = "latin-small.txt", .tsv = false },
        .{ .font = options.test_font_noto_devanagari, .file = "devanagari-small.txt", .tsv = false },
        .{ .font = options.test_font_amiri, .file = "arabic-small.txt", .tsv = false },
        .{ .font = options.test_font_noto_hebrew, .file = "hebrew-small.txt", .tsv = false },
        .{ .font = options.test_font_noto_hebrew, .file = options.bidi_cases, .tsv = true },
    };
    var lines: usize = 0;
    var spans_seen: usize = 0;
    // Lines that start with codepoints kb may give no glyph: the first run's
    // text then starts before its first cluster, a case the files lack.
    const leading = "\u{200D}office AVA\n\u{200B}office\n\u{FEFF}office\n\u{00AD}office\n\u{200D}\u{200C}AVA\n";
    for (sources ++ [_]Source{.{ .font = options.test_font_roboto, .file = leading, .tsv = false }}) |src| {
        const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src.font, gpa, .unlimited);
        defer gpa.free(font_bytes);
        var font = try zpdf.Font.init(gpa, font_bytes, 0, &.{});
        defer font.deinit();
        const inline_text = std.mem.indexOfScalar(u8, src.file, '\n') != null;
        const path = if (src.tsv or inline_text) src.file else try std.fs.path.join(gpa, &.{ options.golden_dir, src.file });
        defer if (!src.tsv and !inline_text) gpa.free(path);
        const data = if (inline_text) try gpa.dupe(u8, src.file) else try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(data);

        var fast_cids = CidRegistry.init(gpa);
        defer fast_cids.deinit();
        var general_cids = CidRegistry.init(gpa);
        defer general_cids.deinit();
        var rows = std.mem.splitScalar(u8, data, '\n');
        while (rows.next()) |row| {
            if (row.len == 0) continue;
            var text = row;
            var direction: zpdf.Direction = .dont_know;
            if (src.tsv) {
                var cols = std.mem.splitScalar(u8, row, '\t');
                const dir = cols.next().?;
                _ = cols.next();
                text = cols.rest();
                direction = if (std.mem.eql(u8, dir, "ltr")) .ltr else if (std.mem.eql(u8, dir, "rtl")) .rtl else .dont_know;
            }
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const shaped = try zpdf.shape(arena, &font, text, .{ .paragraph_direction = direction });
            const cps = try utf8ToCodepoints(arena, text);
            const fast = try mapWith(true, arena, cps, shaped.glyphs, shaped.runs, &fast_cids);
            const general = try mapWith(false, arena, cps, shaped.glyphs, shaped.runs, &general_cids);
            try std.testing.expectEqualSlices(u16, general.cids, fast.cids);
            try std.testing.expectEqual(general.spans.len, fast.spans.len);
            for (general.spans, fast.spans) |g, f| {
                try std.testing.expectEqual(g.start, f.start);
                try std.testing.expectEqual(g.end, f.end);
                try std.testing.expectEqualSlices(u21, g.text, f.text);
            }
            lines += 1;
            spans_seen += fast.spans.len;
        }
        // The registries hold each CID's glyph and text (its ToUnicode entry).
        try expectSameRegistry(&general_cids, &fast_cids);
    }
    // 4 x 200 bench lines + 1,422 bidi lines + 5 leading-ignorable lines;
    // and some lines need ActualText.
    try std.testing.expectEqual(@as(usize, 2227), lines);
    try std.testing.expect(spans_seen > 0);

    // kb gives every codepoint a glyph, so its first cluster is always the run's
    // start. A glyph sequence whose first cluster starts later (codepoint 0 has
    // no glyph) must map the same way on both paths too.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cps = [_]u21{ 0x200B, 'a', 'b' };
    const glyph = struct {
        fn g(id: u16, cluster: u32) zpdf.Glyph {
            return .{ .id = id, ._reserved0 = 0, .cluster = cluster, .advance_x = 500, .advance_y = 0, .offset_x = 0, .offset_y = 0 };
        }
    }.g;
    const glyphs = [_]zpdf.Glyph{ glyph(7, 1), glyph(8, 2) };
    const runs = [_]zpdf.Run{.{ .direction = @backingInt(zpdf.Direction.ltr), .script = 0, .glyph_start = 0, .glyph_count = 2, .paragraph_direction = @backingInt(zpdf.Direction.ltr) }};
    var fast_cids = CidRegistry.init(gpa);
    defer fast_cids.deinit();
    var general_cids = CidRegistry.init(gpa);
    defer general_cids.deinit();
    const fast = try mapWith(true, arena, &cps, &glyphs, &runs, &fast_cids);
    const general = try mapWith(false, arena, &cps, &glyphs, &runs, &general_cids);
    try std.testing.expectEqualSlices(u16, general.cids, fast.cids);
    try expectSameRegistry(&general_cids, &fast_cids);
    // The first glyph's own text is its cluster, "a"; the dropped U+200B is
    // carried by the ActualText span over the group.
    try std.testing.expectEqualSlices(u21, &.{'a'}, fast_cids.textForCid(fast.cids[0]));
}

fn expectSameRegistry(want: *const CidRegistry, got: *const CidRegistry) !void {
    try std.testing.expectEqual(want.count(), got.count());
    var cid: u16 = 1;
    while (cid <= want.count()) : (cid += 1) {
        try std.testing.expectEqual(want.gidForCid(cid), got.gidForCid(cid));
        try std.testing.expectEqualSlices(u21, want.textForCid(cid), got.textForCid(cid));
    }
}
