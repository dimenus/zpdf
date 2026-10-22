//! Compiles src/cmap's predefined CMaps into the blob src/cmap.zig reads (the format is there),
//! for build.zig to embed.
//!
//!     gen-cmaps <out> <src/cmap/name>...
//!
//! Each CMap is parsed with zpdf.read's own parser (cmap.parse), with what its usecmap names
//! under it. It is stored as its differences from a parent: its usecmap, or for a UCS2 map the
//! UTF16 map of its collection (UniJIS-UCS2-H from UniJIS-UTF16-H), which hold nearly the same
//! codes. Then the blob is read back and checked: every code that either the CMap or its parent
//! maps, and every code of its notdef ranges, must select through the blob what it selects in the
//! parsed CMap, and the codespace and /WMode must be the same. A difference stops the build.
//! Built against src/cmap.zig with no tables of its own (read_options.cid_tables false).

const std = @import("std");
const cmap = @import("cmap");

const Entry = struct { name: []const u8, raw: cmap.Builder, full: ?cmap.Builder = null };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: gen-cmaps <out> <cmap>...\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var entries: std.ArrayList(Entry) = .empty;
    for (args[2..]) |path| {
        const text = try cwd.readFileAlloc(io, path, arena, .limited(1 << 24));
        try entries.append(arena, .{ .name = std.fs.path.basename(path), .raw = try cmap.parse(arena, gpa, text) });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    const names = try arena.alloc([]const u8, entries.items.len);
    for (entries.items, names) |e, *n| n.* = e.name;

    // What each CMap selects, its usecmap's definitions under its own.
    for (entries.items) |*e| _ = try full(arena, entries.items, names, e);

    var maps: std.ArrayList([]const u8) = .empty;
    var parents: std.ArrayList(?usize) = .empty;
    for (entries.items) |*e| {
        const p = parentOf(names, e);
        const stored = if (p) |i| try cmap.diff(arena, &e.full.?, &entries.items[i].full.?) else e.full.?;
        try maps.append(arena, try cmap.encode(arena, &stored, if (p) |i| @intCast(i) else cmap.no_parent));
        try parents.append(arena, p);
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeInt(u32, @intCast(entries.items.len), .little);
    var at: u32 = @intCast(4 + entries.items.len * 16);
    for (names) |n| at += @intCast(n.len);
    var name_at: u32 = @intCast(4 + entries.items.len * 16);
    for (names, maps.items) |n, m| {
        try w.writeInt(u32, name_at, .little);
        try w.writeInt(u32, @intCast(n.len), .little);
        try w.writeInt(u32, at, .little);
        try w.writeInt(u32, @intCast(m.len), .little);
        name_at += @intCast(n.len);
        at += @intCast(m.len);
    }
    for (names) |n| try w.writeAll(n);
    for (maps.items) |m| try w.writeAll(m);
    const blob = out.written();

    var checked: u64 = 0;
    for (entries.items, parents.items) |e, p| {
        const m = cmap.find(blob, e.name) orelse fail("{s}: not found in the blob", .{e.name});
        const want = e.full.?;
        const before = checked;
        if (m.vertical() != ((want.wmode orelse 0) == 1)) fail("{s}: /WMode differs", .{e.name});
        checked += try checkRuns(e.name, m, &want, &want);
        if (p) |i| checked += try checkRuns(e.name, m, &want, &entries.items[i].full.?);
        for (want.notdefs.items) |nd| {
            var c = nd.lo;
            while (true) : (c += 1) {
                const code: cmap.Code = .{ .value = c, .len = @intCast(nd.len), .valid = true };
                const expect = notdefOf(&want, nd.len, c);
                if (m.notdef(code) != expect) fail("{s}: notdef <{x}> differs", .{ e.name, c });
                checked += 1;
                if (c == nd.hi) break;
            }
        }
        // A check that read no code proves nothing.
        if (checked == before) fail("{s}: no code was checked", .{e.name});
        // Each codespace range's bounds split as one code of the range's length.
        for (want.codespace.items) |cs| {
            for ([_][4]u8{ cs.lo, cs.hi }) |bytes| {
                const s = bytes[0..cs.len];
                const got = m.split(s);
                if (!got.valid or got.len != cs.len) fail("{s}: a codespace bound does not split as one code", .{e.name});
            }
        }
    }
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = blob });
}

fn full(a: std.mem.Allocator, entries: []Entry, names: []const []const u8, e: *Entry) !*const cmap.Builder {
    if (e.full == null) {
        if (e.raw.usecmap) |u| {
            const i = indexOf(names, u) orelse fail("{s}: usecmap {s} is not in src/cmap", .{ e.name, u });
            const base = try full(a, entries, names, &entries[i]);
            e.full = try e.raw.over(a, base);
        } else e.full = e.raw;
    }
    return &e.full.?;
}

/// Its usecmap, or for a UCS2 map with none the UTF16 map of the same collection and direction.
fn parentOf(names: []const []const u8, e: *const Entry) ?usize {
    if (e.raw.usecmap) |u| return indexOf(names, u);
    const at = std.mem.indexOf(u8, e.name, "-UCS2-") orelse return null;
    var buf: [64]u8 = undefined;
    const twin = std.fmt.bufPrint(&buf, "{s}-UTF16-{s}", .{ e.name[0..at], e.name[at + "-UCS2-".len ..] }) catch return null;
    return indexOf(names, twin);
}

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// Checks that every code `source` maps selects in `m` what it selects in `want`.
fn checkRuns(name: []const u8, m: cmap.Map, want: *const cmap.Builder, source: *const cmap.Builder) !u64 {
    var n: u64 = 0;
    for (source.runs, 1..) |list, len| {
        for (list.items) |r| {
            var c = r.lo;
            while (true) : (c += 1) {
                const expect = want.lookup(len, c);
                const got = m.cid(.{ .value = c, .len = @intCast(len), .valid = true });
                const e: ?u16 = if (expect) |x| (if (x == 0) null else @intCast(x)) else null;
                if (got != e) fail("{s}: <{x}> ({d} bytes) selects {?d}, not {?d}", .{ name, c, len, got, e });
                n += 1;
                if (c == r.hi) break;
            }
        }
    }
    return n;
}

fn notdefOf(b: *const cmap.Builder, len: usize, code: u32) ?u16 {
    var i = b.notdefs.items.len;
    while (i > 0) {
        i -= 1;
        const nd = b.notdefs.items[i];
        if (nd.len == len and code >= nd.lo and code <= nd.hi) return @intCast(nd.cid);
    }
    return null;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gen-cmaps: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
