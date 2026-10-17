//! zpdf-read: what zpdf.read reads from a PDF, as JSON on stdout.
//!
//!   zpdf-read <file.pdf>
//!
//! Output: {"pages": [{"media_box": [x0, y0, x1, y1], "crop_box": [...], "rotate": 0, "runs": [...], "error": null}]}
//! with each run as zpdf.read.TextRun has it (text, x, y, size, width, font, unmapped). A page
//! whose text cannot be read has "runs": [] and its error name in "error"; the other pages are
//! still read. A file zpdf.read refuses prints {"error": "<name>"} and exits 1. A file that
//! cannot be read from disk, or bad usage: 2.
//! tools/read-oracle.py compares this output with other readers'.
const std = @import("std");
const zpdf = @import("zpdf");

const PageOut = struct {
    media_box: [4]f64,
    crop_box: [4]f64,
    rotate: u16,
    runs: []const zpdf.read.TextRun,
    unplaced_actual_text: u32,
    @"error": ?[]const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: zpdf-read <file.pdf>\n", .{});
        return 2;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 30)) catch |err| {
        std.debug.print("zpdf-read: {s}: {t}\n", .{ args[1], err });
        return 2;
    };
    var out_buf: [64 * 1024]u8 = undefined;
    var out_w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;

    var reader = zpdf.read.Reader.open(std.heap.smp_allocator, bytes, .{}) catch |err| {
        try std.json.Stringify.value(.{ .@"error" = @errorName(err) }, .{}, out);
        try out.writeAll("\n");
        try out.flush();
        return 1;
    };
    defer reader.deinit();
    // Each page is written as it is read, and its text freed: memory follows one page, not the
    // file. The bytes are what std.json.Stringify writes for .{ .pages = all pages }.
    try out.writeAll("{\"pages\":[");
    for (0..reader.pageCount()) |i| {
        const page = reader.page(i);
        var item: PageOut = .{ .media_box = page.media_box, .crop_box = page.crop_box, .rotate = page.rotate, .runs = &.{}, .unplaced_actual_text = 0, .@"error" = null };
        var text: ?zpdf.read.PageText = reader.pageText(std.heap.smp_allocator, i) catch |err| blk: {
            item.@"error" = @errorName(err);
            break :blk null;
        };
        defer if (text) |*t| t.deinit();
        if (text) |t| {
            item.runs = t.runs;
            item.unplaced_actual_text = t.unplaced_actual_text;
        }
        if (i != 0) try out.writeAll(",");
        try std.json.Stringify.value(item, .{}, out);
    }
    try out.writeAll("]}");
    try out.writeAll("\n");
    try out.flush();
    return 0;
}
