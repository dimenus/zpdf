//! zpdf-image: one image on one page, as zpdf.Document.addImage and drawImage write it.
//!
//!   zpdf-image [--no-compress] <image.png|image.jpg> <out.pdf>
//!
//! The page is the image's size as shown (imageSize), one point per pixel, and the image fills
//! it, so a renderer at 72 dpi gives back one pixel per image pixel (tools/image-oracle.py).
//! An image zpdf refuses prints its error name on stderr and exits 1; bad usage or a file that
//! cannot be read or written: 2.
const std = @import("std");
const zpdf = @import("zpdf");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var compress = true;
    var paths: [2][]const u8 = undefined;
    var n: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-compress")) {
            compress = false;
        } else if (n < 2) {
            paths[n] = arg;
            n += 1;
        } else n = 3;
    }
    if (n != 2) {
        std.debug.print("usage: zpdf-image [--no-compress] <image.png|image.jpg> <out.pdf>\n", .{});
        return 2;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, paths[0], arena, .limited(1 << 30)) catch |err| {
        std.debug.print("zpdf-image: {s}: {t}\n", .{ paths[0], err });
        return 2;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    var doc = try zpdf.Document.begin(arena, &out.writer, .{ .compress = compress });
    defer doc.deinit();
    const image = doc.addImage(bytes) catch |err| {
        std.debug.print("{t}\n", .{err});
        return 1;
    };
    const size = try doc.imageSize(image);
    const w: f64 = @floatFromInt(size.width);
    const h: f64 = @floatFromInt(size.height);
    const page = try doc.beginPage(w, h);
    try doc.drawImage(page, image, 0, 0, w, h);
    try doc.endPage(page);
    try doc.finish();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = paths[1], .data = out.written() }) catch |err| {
        std.debug.print("zpdf-image: {s}: {t}\n", .{ paths[1], err });
        return 2;
    };
    return 0;
}
