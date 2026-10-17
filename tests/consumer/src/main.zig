const std = @import("std");
const zpdf = @import("zpdf");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // readme: zig-main
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var doc = try zpdf.Document.begin(gpa, &out.writer, .{ .compress = true });
    defer doc.deinit();
    const helvetica = try doc.addStandardFont(.helvetica);
    const page = try doc.beginPage(612, 792);
    try doc.drawText(page, helvetica, 24, 72, 720, .black, "Hello from zpdf", .{});
    try doc.endPage(page);
    try doc.finish();
    // readme: end

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "hello.pdf", .data = out.written() });
}
