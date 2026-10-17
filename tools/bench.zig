//! One timed workload for tools/bench-ab.py, written with zpdf's Document API.
//!
//!   zpdf-bench <scenario> <font.ttf> <count> <out.pdf>
//!
//! tools/bench-mupdf.c draws the same pages with MuPDF's C API, so the two
//! can be compared; keep the scenarios' text, sizes and positions identical
//! in both files. Scenarios:
//!   grid  `count` rows of 7 cells at 9 pt on Letter landscape, 45 rows a
//!         page (a grid export).
//!   text  the 200 lines of tests/golden/latin-small.txt at 12 pt, `count`
//!         times over, 50 lines a page (running text). Each line starts with
//!         its number, "n ", so no two lines are the same text: the file
//!         repeats one line 194 times, and a shape cache would otherwise turn
//!         the scenario into a cache benchmark. The file is found beside this
//!         program's working directory: run from the repo root.
//!   grid-std, text-std  the same pages in the standard font Helvetica (named,
//!         not embedded, no shaping); the font argument is ignored.
//! The output is compressed. Nothing is timed here: bench-ab times the
//! process, so start-up, font loading and the write are all counted.
const std = @import("std");
const zpdf = @import("zpdf");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: zpdf-bench grid|text <font.ttf> <count> <out.pdf>\n", .{});
        return 2;
    }
    const scenario = args[1];
    const count = try std.fmt.parseInt(u32, args[3], 10);
    const gpa = std.heap.smp_allocator;

    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(64 << 20));
    var font = try zpdf.Font.init(gpa, font_bytes, 0, &.{});
    defer font.deinit();
    const standard = std.mem.endsWith(u8, scenario, "-std");
    const kind = if (standard) scenario[0 .. scenario.len - 4] else scenario;
    const is_grid = std.mem.eql(u8, kind, "grid");
    if (!is_grid and !std.mem.eql(u8, kind, "text")) {
        std.debug.print("unknown scenario {s}\n", .{scenario});
        return 2;
    }

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, args[4], .{ .replace = true });
    defer atomic.deinit(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = atomic.file.writer(io, &buf);
    var doc = try zpdf.Document.begin(gpa, &fw.interface, .{ .compress = true });
    defer doc.deinit();
    const font_id = if (standard) try doc.addStandardFont(.helvetica) else try doc.addFont(&font);
    if (is_grid) {
        try grid(&doc, font_id, count);
    } else {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, "tests/golden/latin-small.txt", arena, .limited(1 << 20));
        try running(&doc, font_id, text, count);
    }
    try doc.finish();
    try fw.interface.flush();
    try atomic.replace(io);
    return 0;
}

/// Same cells as bench-mupdf.c's grid(): column i at x = 36 + 104 i, row r at
/// y = 576 - 12 (r mod 45).
fn grid(doc: *zpdf.Document, font: zpdf.FontId, rows: u32) !void {
    var page: zpdf.PageId = undefined;
    var cell: [7][24]u8 = undefined;
    for (0..rows) |r| {
        const row: u32 = @intCast(r);
        if (row % 45 == 0) {
            if (row != 0) try doc.endPage(page);
            page = try doc.beginPage(792, 612);
        }
        const y: f64 = 576 - 12 * @as(f64, @floatFromInt(row % 45));
        const cells = [7][]const u8{
            try std.fmt.bufPrint(&cell[0], "Item {d:0>6}", .{row}),
            try std.fmt.bufPrint(&cell[1], "Vendor {d}", .{row % 97}),
            try std.fmt.bufPrint(&cell[2], "Category {d}", .{row % 13}),
            try std.fmt.bufPrint(&cell[3], "{d}", .{row * 7 % 1000}),
            try std.fmt.bufPrint(&cell[4], "{d}.{d:0>2}", .{ row % 500, row % 100 }),
            try std.fmt.bufPrint(&cell[5], "{d}", .{row % 9973}),
            try std.fmt.bufPrint(&cell[6], "Room {d}", .{row % 41}),
        };
        for (cells, 0..) |c, i| {
            try doc.drawText(page, font, 9, 36 + 104 * @as(f64, @floatFromInt(i)), y, .black, c, .{});
        }
    }
    if (rows > 0) try doc.endPage(page);
}

/// Same lines as bench-mupdf.c's running(): line k of a page at y = 756 - 14 k.
fn running(doc: *zpdf.Document, font: zpdf.FontId, text: []const u8, times: u32) !void {
    var page: zpdf.PageId = undefined;
    var n: u32 = 0;
    var numbered: [1024]u8 = undefined;
    for (0..times) |_| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (n % 50 == 0) {
                if (n != 0) try doc.endPage(page);
                page = try doc.beginPage(612, 792);
            }
            const text_line = try std.fmt.bufPrint(&numbered, "{d} {s}", .{ n, line });
            try doc.drawText(page, font, 12, 72, 756 - 14 * @as(f64, @floatFromInt(n % 50)), .black, text_line, .{});
            n += 1;
        }
    }
    if (n > 0) try doc.endPage(page);
}
